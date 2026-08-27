/**
 * Aity Drive for Android - Factory overlay (gitlab.com/aity-cloud/drive/android).
 *
 * Tier 2b: the account journey smoke. Replaces the `smoke:emulator`
 * placeholder that deliberately failed so it could not fake a green smoke.
 *
 * What it proves, on an emulator, against the Environment the build points at:
 *
 *   1. the app signs in with the real `drive-android` OIDC client - its own
 *      authorization request, its own PKCE verifier, its own token exchange
 *      and its own AccountManager account,
 *   2. the personal space file list shows a file that was put there over
 *      WebDAV BEFORE the app was launched (a list that stops spinning is not
 *      a list of files),
 *   3. a folder created from the app shows up, and reaches the server,
 *   4. removing it from the app removes it from the server,
 *   5. staging is left exactly as it was found.
 *
 * The only thing not exercised is Chrome. See KeycloakBrowser for why, and
 * MAINTAINING.md for what that costs in coverage.
 *
 * Configuration comes from instrumentation arguments, never from source:
 *
 *   -Pandroid.testInstrumentationRunnerArguments.aityUser=... \
 *   -Pandroid.testInstrumentationRunnerArguments.aityPassword=...
 *
 * Everything else (server URL, OIDC client id, redirect scheme and host) is
 * read from the app's own resources, so this test can never be pointed at a
 * different server than the build is.
 *
 * Licensed under the GNU General Public License version 2, like the tree it
 * overlays.
 */
package tech.aity.drive.smoke

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.intent.Intents
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.owncloud.android.R
import org.hamcrest.BaseMatcher
import org.hamcrest.Description
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

private const val TAG = "AityDriveSmoke"

@RunWith(AndroidJUnit4::class)
class AccountJourneySmokeTest {

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var device: UiDevice

    private val packageName: String get() = context.packageName
    private val serverUrl: String get() = context.getString(R.string.server_url).trimEnd('/')

    /**
     * The Environment's realm. Derived from the server URL the BUILD carries
     * (drive.<env> -> auth.<env>, meta/specs/aity-drive-v1.md "Environments and
     * channels") so a production build can never be smoked against the staging
     * realm; overridable for an Environment that ever breaks that symmetry.
     */
    private val issuer: String
        get() = argument("aityIssuer").ifEmpty {
            serverUrl.replace("//drive.", "//auth.") + "/realms/aity"
        }

    private val user: String get() = argument("aityUser")
    private val password: String get() = argument("aityPassword")

    private fun argument(name: String): String =
        InstrumentationRegistry.getArguments().getString(name).orEmpty()

    private val runId = UUID.randomUUID().toString().take(8)
    private val seededFile = "aity-smoke-$runId.txt"
    private val createdFolder = "aity-smoke-folder-$runId"

    private lateinit var server: StagingServer
    private var token: String? = null
    private var space: String? = null

    @Before
    fun setUp() {
        assumeTrue(
            "aityUser / aityPassword instrumentation arguments are not set - the account " +
                "journey needs the staging contract account (protected CI variables " +
                "AITY_CONTRACT_USER / AITY_CONTRACT_PASSWORD on aity-cloud/drive)",
            user.isNotEmpty() && password.isNotEmpty(),
        )
        device = UiDevice.getInstance(instrumentation)
        device.wakeUp()

        // The realm is the Environment's auth host. It is derived from the
        // server URL the BUILD carries (drive.<env> -> auth.<env>) rather than
        // hardcoded, so a build pointed at production can never be smoked
        // against the staging realm.
        // Android 13+ asks for POST_NOTIFICATIONS the first time the file
        // list opens. Pre-granting it keeps a system dialog out of the middle
        // of the journey; how the app behaves with it denied is not what this
        // smoke is about.
        runCatching {
            instrumentation.uiAutomation.grantRuntimePermission(
                packageName, "android.permission.POST_NOTIFICATIONS"
            )
        }

        server = StagingServer(serverUrl, issuer, user, password)
    }

    @After
    fun tearDown() {
        // Never leave anything on the server, whatever happened above.
        val token = this.token ?: return
        val space = this.space ?: return
        server.delete(seededFile, space, token)
        server.delete(createdFolder, space, token)
    }

    @Test
    fun signInThenListCreateAndDeleteInThePersonalSpace() {
        Log.i(TAG, "run $runId against $serverUrl (realm $issuer)")

        // --- Seed, before the app has ever run.
        val token = server.token().also { this.token = it }
        val space = server.personalSpaceWebDavUrl(token).also { this.space = it }
        server.putFile(seededFile, "aity drive android smoke $runId\n", space, token)
        Log.i(TAG, "seeded $seededFile into $space")

        // --- Sign in. The app builds its own authorization request and opens
        // it in a Custom Tab; that launch is captured and answered here.
        val authorizationUrl = captureAuthorizationUrl()
        Log.i(TAG, "app asked the browser for ${authorizationUrl.take(120)}")

        val redirect = KeycloakBrowser(user, password).authorize(authorizationUrl)
        assertTrue(
            "Keycloak redirected to $redirect, which is not the app's registered redirect " +
                "(${redirectPrefix()}). The drive-android client registration and the build's " +
                "oauth2_redirect_uri_* resources disagree.",
            redirect.startsWith(redirectPrefix()),
        )
        assertTrue("the redirect carries no authorization code: $redirect", redirect.contains("code="))

        // Deliver the callback exactly as the browser would: LoginActivity is
        // singleTask with an intent-filter on the redirect scheme, so this
        // reaches its onNewIntent and the app does its own token exchange.
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(redirect)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )

        // --- The Tier 2 assertion: content from the server, on screen.
        assertTrue(
            "'$seededFile' was in the personal space before the app launched but never appeared " +
                "in the file list. Either the login did not complete or the list is not the " +
                "personal space.\n${dump()}",
            waitForFileNamed(seededFile, timeoutMillis = 240_000),
        )

        // --- Create a folder from the app.
        createFolderFromTheApp(createdFolder)
        assertTrue(
            "the folder created from the app never appeared in the list\n${dump()}",
            waitForFileNamed(createdFolder, timeoutMillis = 120_000),
        )
        assertTrue(
            "the app showed $createdFolder but the server has no such folder - the create " +
                "never reached ${serverUrl}",
            eventually(60_000) { server.exists(createdFolder, space, token) },
        )

        // --- Remove something from the app, and check the removal reached the
        // server. The target is the SEEDED FILE and not the folder just
        // created, because a freshly created folder cannot be removed from
        // this app at all: it carries no `permissions` string yet and
        // FilterFileMenuOptionsUseCase gates Remove, Rename and Move on it, so
        // neither the three-dot menu nor long-press offers Remove. Measured,
        // not assumed - see MAINTAINING.md. The folder is cleaned up over
        // WebDAV in teardown; if a Bump fixes it, remove the folder here
        // instead and delete that note.
        removeFromTheApp(seededFile)
        assertTrue(
            "the file removed in the app is still on the server",
            eventually(120_000) { !server.exists(seededFile, space, token) },
        )
    }

    // MARK: - The browser hand-off

    private fun redirectPrefix(): String =
        context.getString(R.string.oauth2_redirect_uri_scheme) + "://" +
            context.getString(R.string.oauth2_redirect_uri_host)

    /**
     * Starts the login and returns the authorization URL the app wanted to
     * open. Espresso-Intents stubs the outgoing ACTION_VIEW so no browser is
     * ever launched: MonitoringInstrumentation.execStartActivity consults the
     * stub for plain startActivity too, not only startActivityForResult.
     */
    private fun captureAuthorizationUrl(): String {
        val capture = CapturingHttpViewMatcher()
        Intents.init()
        try {
            Intents.intending(capture).respondWith(
                Instrumentation.ActivityResult(Activity.RESULT_OK, null)
            )

            // Start the app the way a person does - the launcher icon. With no
            // account yet, SplashActivity -> FileDisplayActivity -> LoginActivity.
            val launch = context.packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(Intent.ACTION_MAIN).setClassName(packageName, LOGIN_ACTIVITY)
            context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

            // With the server URL locked (`show_server_url_input=false`) the app
            // does NOT check the server by itself: `initBrandableOptionsUI`
            // shows a centred "Check server" button instead and waits to be
            // tapped. That one tap is the whole first screen of the branded
            // app, and it is what starts server discovery and, right after it,
            // the authorization request.
            val checkServer = device.wait(
                Until.findObject(By.res(packageName, "centeredRefreshButton")), 60_000
            ) ?: error("the login screen never appeared\n${dump()}")
            Log.i(TAG, "tapping 'Check server' to start discovery")
            checkServer.click()

            val captured = eventuallyGet(120_000) { capture.captured }
                ?: error(
                    "the app never asked a browser for an authorization URL within 120s of " +
                        "tapping 'Check server'. Discovery against $serverUrl probably " +
                        "failed.\n${dump()}"
                )
            return captured
        } finally {
            Intents.release()
        }
    }

    private class CapturingHttpViewMatcher : BaseMatcher<Intent>() {
        @Volatile
        var captured: String? = null

        override fun matches(item: Any?): Boolean {
            val intent = item as? Intent ?: return false
            val data = intent.data ?: return false
            val isBrowserLaunch =
                intent.action == Intent.ACTION_VIEW && data.scheme?.startsWith("http") == true
            if (isBrowserLaunch && captured == null && data.getQueryParameter("code_challenge") != null) {
                captured = data.toString()
            }
            // Swallow every browser launch, including the ones we do not
            // recognise: a real Chrome window in the middle of the run would
            // steal focus and break every assertion after it.
            return isBrowserLaunch
        }

        override fun describeTo(description: Description) {
            description.appendText("an ACTION_VIEW intent to an http(s) URL (the OIDC Custom Tab)")
        }
    }

    // MARK: - The app's own UI

    private fun createFolderFromTheApp(name: String) {
        val fab = waitForAny(
            listOf(By.res(packageName, "fab_expand_menu_button"), By.res(packageName, "fab_main")),
            30_000,
        ) ?: error("the add-content FAB never appeared in the file list\n${dump()}")
        fab.click()

        val mkdir = device.wait(Until.findObject(By.res(packageName, "fab_mkdir")), 15_000)
            ?: error("the 'New folder' FAB did not expand\n${dump()}")
        mkdir.click()

        val input = device.wait(Until.findObject(By.res(packageName, "user_input")), 15_000)
            ?: error("the create-folder dialog did not appear\n${dump()}")
        input.text = name

        // The dialog is an AlertDialog: OK is android:id/button1.
        val ok = device.wait(Until.findObject(By.res("android", "button1")), 10_000)
            ?: error("no OK button on the create-folder dialog\n${dump()}")
        ok.click()
    }

    private fun removeFromTheApp(name: String) {
        check(openRemoveAction(name)) {
            "no '$REMOVE_LABEL' action after long-pressing $name\n${dump()}"
        }
    }

    /**
     * Opens the row's own three-dot menu and taps Remove. Returns false if
     * Remove is not offered.
     *
     * The three-dot menu, not a long press. A long press puts the list into
     * MULTI-SELECTION, and in that mode this app offers only Select all /
     * Select inverse / Copy / Set as available offline for the contract user's
     * own files - no Remove, Rename, Move, Share or Details - even though the
     * server reports `permissions=RDNVCKZP` for the space. That is recorded in
     * MAINTAINING.md as an open question about upstream; the single-item menu
     * is both the normal way a person deletes one file and the one that works.
     */
    private fun openRemoveAction(name: String): Boolean {
        val item = device.wait(Until.findObject(By.text(name)), 30_000)
            ?: error("$name is not on screen any more\n${dump()}")

        // Pick the three-dot button that belongs to THIS row: the one whose
        // vertical centre is closest to the row's.
        val rowCentre = item.visibleBounds.centerY()
        val menuButton = device.findObjects(By.res(packageName, "three_dot_menu"))
            .minByOrNull { kotlin.math.abs(it.visibleBounds.centerY() - rowCentre) }
            ?: error("no three-dot menu on the row for $name\n${dump()}")
        menuButton.click()

        val remove = findInScrollableMenu(REMOVE_LABEL) ?: return false
        remove.click()

        val confirm = device.wait(Until.findObject(By.res(packageName, "dialog_remove_yes")), 15_000)
            ?: error("the remove confirmation dialog did not appear\n${dump()}")
        confirm.click()
        return true
    }

    /**
     * The list may open on the spaces overview rather than inside the personal
     * space, so a "Personal" entry is followed when the file is not on screen -
     * exactly what a person would do.
     */
    private fun waitForFileNamed(name: String, timeoutMillis: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        var enteredPersonal = false
        while (System.currentTimeMillis() < deadline) {
            if (device.wait(Until.hasObject(By.text(name)), 5_000)) return true
            dismissSystemPermissionDialog()
            if (!enteredPersonal) {
                device.findObject(By.text(PERSONAL_LABEL))?.let {
                    Log.i(TAG, "opening the personal space from the spaces list")
                    it.click()
                    enteredPersonal = true
                }
            }
        }
        return device.hasObject(By.text(name))
    }

    /**
     * A runtime-permission dialog that slips through (a new one in a future
     * Android, or a pre-grant that did not take) would otherwise swallow every
     * later tap. Answering it is not the test, so it is answered quietly.
     */
    private fun dismissSystemPermissionDialog() {
        if (device.currentPackageName?.contains("permissioncontroller") != true) return
        listOf("Allow", "While using the app", "OK", "Continue").forEach { label ->
            device.findObject(By.text(label))?.let {
                Log.i(TAG, "dismissing a system permission dialog with '$label'")
                it.click()
                return
            }
        }
    }

    /**
     * Finds a menu entry by label, scrolling the popup when it does not fit.
     * `UiObject2.scroll` returns false once it cannot scroll further, which is
     * the only reliable "we have seen everything" signal a popup gives.
     */
    private fun findInScrollableMenu(label: String): UiObject2? {
        fun visible(): UiObject2? =
            device.wait(Until.findObject(By.text(label)), 2_000)
                ?: device.findObject(By.descContains(label))

        visible()?.let { return it }
        val list = device.wait(Until.findObject(By.scrollable(true)), 5_000) ?: return null
        repeat(6) {
            if (!list.scroll(Direction.DOWN, 0.6f)) return visible()
            visible()?.let { return it }
        }
        return visible()
    }

    private fun waitForAny(selectors: List<BySelector>, timeoutMillis: Long): UiObject2? {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            selectors.forEach { selector ->
                device.findObject(selector)?.let { return it }
            }
            Thread.sleep(500)
        }
        return null
    }

    private fun eventually(timeoutMillis: Long, condition: () -> Boolean): Boolean =
        eventuallyGet(timeoutMillis) { if (condition()) true else null } ?: false

    private fun <T> eventuallyGet(timeoutMillis: Long, probe: () -> T?): T? {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            probe()?.let { return it }
            Thread.sleep(1_000)
        }
        return probe()
    }

    /**
     * A failing UI test that only says "not found" costs a whole CI round trip
     * on shared hardware, so every failure carries the window dump.
     */
    private fun dump(): String = runCatching {
        // Text alone is not enough: half of this app's actions are icons whose
        // only label is a contentDescription, and finding that out cost a
        // cycle. Dump text, description and resource id for everything.
        val nodes = device.findObjects(By.pkg(device.currentPackageName)).mapNotNull { node ->
            val text = node.text?.takeIf { it.isNotBlank() }
            val desc = node.contentDescription?.takeIf { it.isNotBlank() }
            val id = node.resourceName?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
            if (text == null && desc == null && id == null) null
            else listOfNotNull(text?.let { "text=$it" }, desc?.let { "desc=$it" }, id?.let { "id=$it" })
                .joinToString(" ")
        }.distinct()
        "current package: ${device.currentPackageName}\nvisible nodes:\n  " +
            nodes.joinToString("\n  ")
    }.getOrElse { "could not dump the screen: $it" }

    private companion object {
        const val LOGIN_ACTIVITY = "com.owncloud.android.presentation.authentication.LoginActivity"
        const val REMOVE_LABEL = "Remove"
        const val PERSONAL_LABEL = "Personal"
    }
}
