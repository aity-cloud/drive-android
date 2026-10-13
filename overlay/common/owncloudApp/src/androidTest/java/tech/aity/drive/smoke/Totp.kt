/**
 * Aity Drive for Android - Factory overlay (gitlab.com/aity-cloud/drive/android).
 *
 * The contract account's Authenticator App code: RFC 6238 (HMAC-SHA1, 6
 * digits, 30 s step) from the base32 seed an authenticator app shows, the same
 * as meta/contract/totp.py.
 *
 * Licensed under the GNU General Public License version 2, like the tree it
 * overlays.
 */
package tech.aity.drive.smoke

import java.nio.ByteBuffer
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object Totp {
    private const val STEP_MILLIS = 30_000L
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    private var lastStep = -1L

    /**
     * A code from a step this run has not used yet: Keycloak accepts each code
     * once per user, and the harness grant and the app's sign-in are two uses.
     */
    @Synchronized
    fun freshCode(secret: String): String {
        if (System.currentTimeMillis() / STEP_MILLIS <= lastStep) {
            Thread.sleep(STEP_MILLIS - System.currentTimeMillis() % STEP_MILLIS + 1_000)
        }
        val now = System.currentTimeMillis()
        lastStep = now / STEP_MILLIS
        return code(secret, now)
    }

    fun code(secret: String, atMillis: Long): String {
        val mac = Mac.getInstance("HmacSHA1")
        mac.init(SecretKeySpec(base32Decode(secret), "HmacSHA1"))
        val hash = mac.doFinal(ByteBuffer.allocate(8).putLong(atMillis / STEP_MILLIS).array())
        val offset = hash[19].toInt() and 0x0f
        val value = (ByteBuffer.wrap(hash, offset, 4).int and 0x7fffffff) % 1_000_000
        return value.toString().padStart(6, '0')
    }

    private fun base32Decode(text: String): ByteArray {
        var buffer = 0
        var bits = 0
        val bytes = mutableListOf<Byte>()
        for (character in text.uppercase().filter { it != ' ' && it != '=' }) {
            val index = ALPHABET.indexOf(character)
            require(index >= 0) { "aityTotpSecret is not a base32 seed" }
            buffer = (buffer shl 5 or index) and 0xffff
            bits += 5
            if (bits >= 8) {
                bits -= 8
                bytes += (buffer shr bits).toByte()
            }
        }
        return bytes.toByteArray()
    }
}
