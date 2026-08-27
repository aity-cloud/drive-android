/**
 * Aity Drive for Android - Factory overlay (gitlab.com/aity-cloud/drive/android).
 *
 * Server-side helper for the account journey smoke: it puts a file into the
 * contract user's personal space before the app is ever launched, and cleans
 * up afterwards even when the UI half of the test dies.
 *
 * It authenticates with the SAME password grant Tier 1 uses
 * (meta/contract/drive_contract.py, client `drive`) and deliberately NOT with
 * `drive-android`, which is the client the APP must exercise through its own
 * Custom Tab. Keeping the harness on a different client means this test can
 * never paper over a broken `drive-android` registration.
 *
 * Licensed under the GNU General Public License version 2, like the tree it
 * overlays.
 */
package tech.aity.drive.smoke

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class StagingServer(
    private val baseUrl: String,
    private val issuer: String,
    private val username: String,
    private val password: String,
) {
    private fun open(method: String, url: String, token: String? = null): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = false
            connectTimeout = 30_000
            readTimeout = 60_000
            setRequestProperty("User-Agent", "aity-drive-android-smoke/1.0")
            token?.let { setRequestProperty("Authorization", "Bearer $it") }
        }

    private fun HttpURLConnection.bodyText(): String =
        (if (responseCode in 200..399) inputStream else errorStream)
            ?.bufferedReader()?.use { it.readText() } ?: ""

    /** Access token for the harness. Password grant on the `drive` client. */
    fun token(): String {
        val connection = open("POST", "$issuer/protocol/openid-connect/token")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        val form = mapOf(
            "client_id" to "drive",
            "grant_type" to "password",
            "scope" to "openid profile email",
            "username" to username,
            "password" to password,
        ).entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" }
        connection.outputStream.use { it.write(form.toByteArray()) }
        val body = connection.bodyText()
        check(connection.responseCode == 200) {
            "password grant failed: HTTP ${connection.responseCode} ${body.take(200)}"
        }
        return JSONObject(body).getString("access_token")
    }

    /**
     * WebDAV URL of the personal space, as the SERVER advertises it. A client
     * follows what it is given, so the harness does too.
     */
    fun personalSpaceWebDavUrl(token: String): String {
        val connection = open("GET", "$baseUrl/graph/v1.0/me/drives", token)
        val body = connection.bodyText()
        check(connection.responseCode == 200) {
            "graph /me/drives failed: HTTP ${connection.responseCode} ${body.take(200)}"
        }
        val drives = JSONObject(body).getJSONArray("value")
        for (index in 0 until drives.length()) {
            val drive = drives.getJSONObject(index)
            if (drive.optString("driveType") == "personal") {
                return drive.getJSONObject("root").getString("webDavUrl").trimEnd('/')
            }
        }
        error("no personal space among ${drives.length()} drive(s)")
    }

    fun putFile(name: String, contents: String, space: String, token: String) {
        val connection = open("PUT", "$space/$name", token)
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "text/plain")
        connection.outputStream.use { it.write(contents.toByteArray()) }
        check(connection.responseCode == 201 || connection.responseCode == 204) {
            "PUT $name failed: HTTP ${connection.responseCode} ${connection.bodyText().take(200)}"
        }
    }

    /**
     * HEAD, not PROPFIND. `HttpURLConnection` accepts a FIXED set of methods
     * (GET, POST, HEAD, OPTIONS, PUT, DELETE, TRACE) and throws
     * ProtocolException for anything else, so a PROPFIND here never leaves the
     * device - and swallowed by a runCatching it silently answers "does not
     * exist" for everything, which reads exactly like the app failing to
     * create the folder. Cost one debugging round trip on 2026-08-27.
     * oCIS answers HEAD on a collection with 200, and 404 when it is missing.
     * (The iOS twin uses PROPFIND because URLSession has no such restriction.)
     */
    fun exists(name: String, space: String, token: String): Boolean {
        val connection = open("HEAD", "$space/$name", token)
        return when (val status = connection.responseCode) {
            200, 207 -> true
            404 -> false
            else -> error("HEAD $name answered HTTP $status, which is neither present nor absent")
        }
    }

    /**
     * Best effort. Teardown must never turn a red test into a red AND littered
     * staging, and must never mask the original failure either.
     */
    fun delete(name: String, space: String, token: String) {
        runCatching { open("DELETE", "$space/$name", token).responseCode }
    }
}
