package com.example.mactv_androidapp.connection

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** Only an encrypted credential blob enters private preferences; its key never leaves Android Keystore. */
class CredentialStore(context: Context, private val namespace: String = "mactv_pairing_v1") {
    private val prefs = context.getSharedPreferences(namespace, Context.MODE_PRIVATE)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(namespace, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(namespace, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            generateKey()
        }
    }
    data class Saved(val device: MacDevice, val clientId: String, val token: ByteArray)
    fun save(saved: Saved) {
        val json = JSONObject().put("id", saved.device.id).put("name", saved.device.name)
            .put("endpoint", saved.device.endpoint).put("clientId", saved.clientId).put("token", RemoteWire.b64(saved.token))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val blob = cipher.iv + cipher.doFinal(json.toString().toByteArray())
        check(prefs.edit().putString("credential", RemoteWire.b64(blob)).commit()) { "Could not save paired device" }
    }
    fun load(): Saved? = try {
        prefs.getString("credential", null)?.let {
            val blob = RemoteWire.decode(it)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0,12)))
            }
            val json = JSONObject(String(cipher.doFinal(blob.copyOfRange(12,blob.size))))
            Saved(MacDevice(json.getString("id"), json.getString("name"), json.getString("endpoint")),
                json.getString("clientId"), RemoteWire.decode(json.getString("token")))
        }
    } catch (_: Exception) { clear(); null }
    fun clear() { prefs.edit().clear().commit() }
}
