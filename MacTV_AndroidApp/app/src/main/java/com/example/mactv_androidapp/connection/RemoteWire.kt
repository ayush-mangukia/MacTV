package com.example.mactv_androidapp.connection

import com.example.mactv_androidapp.command.*
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject

object RemoteWire {
    const val VERSION = 1
    fun random(): ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) }
    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    fun decode(value: String): ByteArray = Base64.getDecoder().decode(value)
    private fun hmac(key: ByteArray, bytes: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(bytes)
    }
    fun proof(secret: ByteArray, text: String): String = b64(hmac(secret, text.toByteArray(Charsets.UTF_8)))
    fun verify(proof: String, secret: ByteArray, text: String): Boolean =
        MessageDigest.isEqual(decode(proof), hmac(secret, text.toByteArray(Charsets.UTF_8)))
    fun key(secret: ByteArray, client: String, server: String): ByteArray {
        val c = decode(client); val s = decode(server)
        require(c.size == 32 && s.size == 32 && secret.size == 32)
        val prk = hmac(c + s, secret)
        return hmac(prk, "MacTV/v1".toByteArray() + byteArrayOf(1))
    }
    private fun nonce(direction: String, sequence: Long): ByteArray = ByteBuffer.allocate(12)
        .put(direction.toByteArray(Charsets.US_ASCII)).putLong(sequence).array()
    fun seal(payload: JSONObject, key: ByteArray, direction: String, sequence: Long): JSONObject {
        require(sequence > 0)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(direction, sequence)))
        cipher.updateAAD("MacTV/1/$direction/$sequence".toByteArray())
        return JSONObject().put("v", 1).put("type", "secure").put("seq", sequence)
            .put("body", b64(cipher.doFinal(payload.toString().toByteArray(Charsets.UTF_8))))
    }
    fun open(frame: JSONObject, key: ByteArray, direction: String, expected: Long): JSONObject {
        require(frame.getInt("v") == 1 && frame.getString("type") == "secure" && frame.getLong("seq") == expected)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(direction, expected)))
        cipher.updateAAD("MacTV/1/$direction/$expected".toByteArray())
        return JSONObject(String(cipher.doFinal(decode(frame.getString("body"))), Charsets.UTF_8))
    }
    fun command(command: RemoteCommand): JSONObject = JSONObject().apply {
        when (command) {
            is RemoteCommand.Press -> put("kind", "key").put("key", command.key.name.lowercase())
            is RemoteCommand.Launch -> put("kind", "launch").put("app", when(command.app) {
                LaunchApp.PRIME_VIDEO -> "prime"
                else -> command.app.name.lowercase()
            })
            is RemoteCommand.MovePointer -> {
                require(command.dx.isFinite() && command.dy.isFinite())
                put("kind", "pointer").put("dx", command.dx.coerceIn(-500f,500f)).put("dy", command.dy.coerceIn(-500f,500f))
            }
            is RemoteCommand.Scroll -> { require(command.delta.isFinite()); put("kind", "scroll").put("delta", command.delta.coerceIn(-500f,500f)) }
            is RemoteCommand.EnterText -> { require(command.text.length in 1..2000); put("kind", "text").put("text", command.text) }
        }
    }
}

data class PairingInvitation(val device: MacDevice, val secret: ByteArray) {
    companion object {
        fun parse(value: String): PairingInvitation {
            require(value.length < 4096 && value.trim().startsWith("mactv1:")) { "Paste a MacTV invitation from Mac Settings" }
            val json = JSONObject(String(RemoteWire.decode(value.trim().removePrefix("mactv1:")), Charsets.UTF_8))
            require(json.getInt("v") == 1) { "Unsupported invitation version" }
            val host = json.getString("host"); val port = json.getInt("port")
            require(host.isNotBlank() && host.length < 254 && host.none { it.isWhitespace() || it in "/?#@" } && port in 1..65535)
            val id = json.getString("id"); java.util.UUID.fromString(id)
            val secret = RemoteWire.decode(json.getString("secret")); require(secret.size == 32)
            val endpoint = okhttp3.HttpUrl.Builder().scheme("http").host(host).port(port).build().toString().replaceFirst("http:", "ws:")
            return PairingInvitation(MacDevice(id, "MacTV", endpoint), secret)
        }
    }
}
