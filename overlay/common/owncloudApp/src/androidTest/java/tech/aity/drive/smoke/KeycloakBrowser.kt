/**
 * Aity Drive for Android - Factory overlay (gitlab.com/aity-cloud/drive/android).
 *
 * Stands in for the system browser during the account journey smoke.
 *
 * The app hands its authorization URL to a Custom Tab. That Custom Tab is
 * Chrome, not our software, and automating it is the single flakiest thing in
 * Android UI testing. So the test intercepts the launch, hands the URL here,
 * and this class walks the Keycloak login exactly as a browser would - which
 * keeps the app's OWN OIDC code path (authorization request construction,
 * PKCE verifier, state, token exchange, account creation) fully under test.
 * The only thing replaced is the browser.
 *
 * The realm's browser flow is IDENTITY-FIRST: page 1 (`login-username`) takes
 * the email and submits with "Continue", page 2 (`login`) takes the password.
 * Posting both at once silently redisplays page 1 with no error. The page is a
 * React app (the Keycloakify `aity` theme), so there is no server-rendered
 * <form> to scrape - the POST target is `kcContext.url.loginAction`, embedded
 * in the bootstrap script.
 *
 * Licensed under the GNU General Public License version 2, like the tree it
 * overlays.
 */
package tech.aity.drive.smoke

import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class KeycloakBrowser(private val username: String, private val password: String) {

    private val cookies = CookieManager().apply { setCookiePolicy(CookiePolicy.ACCEPT_ALL) }

    /**
     * Follows [authorizationUrl] through the login pages and returns the
     * redirect URI the browser would have been sent to - the one carrying the
     * authorization code that only this app can spend, because only this app
     * holds the PKCE verifier.
     */
    fun authorize(authorizationUrl: String): String {
        var page = get(authorizationUrl)
        var action = loginAction(page)
            ?: error("no kcContext.url.loginAction on ${pageId(page)}: ${page.take(300)}")

        if (pageId(page) == "login-username") {
            val step = post(action, mapOf("username" to username))
            step.redirect?.let { return it }
            page = step.body
            action = loginAction(page)
                ?: error("no loginAction on the password page (${pageId(page)})")
        }

        val step = post(action, mapOf("password" to password, "credentialId" to ""))
        return step.redirect
            ?: error(
                "the login did not redirect. Page is '${pageId(step.body)}'" +
                    (fieldError(step.body)?.let { ", error: $it" } ?: ", no error message shown")
            )
    }

    // MARK: - Plumbing

    private data class Step(val body: String, val redirect: String?)

    private fun connection(url: String, method: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = false
            connectTimeout = 30_000
            readTimeout = 60_000
            // A plain Java UA is enough - Keycloak does not sniff it - but a
            // recognisable one makes the realm's log readable when this breaks.
            setRequestProperty("User-Agent", "aity-drive-android-smoke/1.0")
            setRequestProperty("Accept-Language", "en-US,en;q=0.9")
            cookieHeader()?.let { setRequestProperty("Cookie", it) }
        }

    private fun HttpURLConnection.cookieHeader(): String? {
        val jar = cookies.cookieStore.cookies
        return if (jar.isEmpty()) null else jar.joinToString("; ") { "${it.name}=${it.value}" }
    }

    private fun HttpURLConnection.harvestCookies() {
        headerFields["Set-Cookie"]?.forEach { raw ->
            runCatching {
                java.net.HttpCookie.parse(raw).forEach { cookies.cookieStore.add(URL(url.protocol + "://" + url.host).toURI(), it) }
            }
        }
    }

    private fun get(url: String): String {
        val connection = connection(url, "GET")
        val body = connection.read()
        connection.harvestCookies()
        check(connection.responseCode == 200) {
            "authorize endpoint answered HTTP ${connection.responseCode} - " +
                "if this is 403 the edge is blocking the request, not Keycloak"
        }
        return body
    }

    private fun post(url: String, fields: Map<String, String>): Step {
        val connection = connection(url, "POST")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        val form = fields.entries.joinToString("&") {
            "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}"
        }
        connection.outputStream.use { it.write(form.toByteArray()) }
        val body = connection.read()
        connection.harvestCookies()
        val location = connection.getHeaderField("Location")
        return if (connection.responseCode in 300..399 && location != null) {
            Step(body, location)
        } else {
            Step(body, null)
        }
    }

    private fun HttpURLConnection.read(): String =
        (if (responseCode in 200..399) inputStream else errorStream)
            ?.bufferedReader()?.use { it.readText() } ?: ""

    private fun loginAction(page: String): String? =
        Regex("\"loginAction\"\\s*:\\s*\"([^\"]+)\"").find(page)
            ?.groupValues?.get(1)
            ?.replace("\\/", "/")
            ?.replace("&amp;", "&")

    private fun pageId(page: String): String =
        Regex("\"pageId\"\\s*:\\s*\"([^\"]*)\"").find(page)?.groupValues?.get(1) ?: "unknown"

    private fun fieldError(page: String): String? =
        Regex("class=\"[^\"]*st-field-error[^\"]*\"[^>]*>([^<]+)").find(page)?.groupValues?.get(1)
}
