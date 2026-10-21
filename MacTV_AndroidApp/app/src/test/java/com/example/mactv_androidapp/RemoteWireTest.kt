package com.example.mactv_androidapp

import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.connection.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RemoteWireTest {
    private val secret = ByteArray(32) { it.toByte() }
    private val c = RemoteWire.b64(ByteArray(32) { (it+32).toByte() })
    private val s = RemoteWire.b64(ByteArray(32) { (it+64).toByte() })
    private val key get() = RemoteWire.key(secret,c,s)
    @Test fun swiftAndKotlinDeriveIdenticalKeyAndProof() {
        assertEquals("VLn05P+dEiAqn6A80tXE2Iz46wcJ2xufgOwdDsmzwcQ=",RemoteWire.b64(key))
        assertEquals("zp+oEBQaM9gaaIMMp1VnLHqf1vSBB7+PJK4G38gFGZI=",RemoteWire.proof(secret,"server|1|test"))
    }
    @Test fun decryptsSwiftFrameAndProducesIdenticalCiphertext() {
        val frame = JSONObject().put("v",1).put("type","secure").put("seq",1)
            .put("body","7DvyxGJ5yVRIA0eSFKcfAXr3IDMVDurs/sLlUgZXXA==")
        assertEquals("ping",RemoteWire.open(frame,key,"C2S!",1).getString("type"))
        assertEquals(frame.getString("body"),RemoteWire.seal(JSONObject().put("type","ping"),key,"C2S!",1).getString("body"))
    }
    @Test fun rejectsReplayWrongDirectionTamperingAndWrongProof() {
        val frame = RemoteWire.seal(JSONObject().put("type","ping"),key,"C2S!",1)
        assertThrows(Exception::class.java) { RemoteWire.open(frame,key,"C2S!",2) }
        assertThrows(Exception::class.java) { RemoteWire.open(frame,key,"S2C!",1) }
        frame.put("body", RemoteWire.b64(ByteArray(32)))
        assertThrows(Exception::class.java) { RemoteWire.open(frame,key,"C2S!",1) }
        assertFalse(RemoteWire.verify(RemoteWire.proof(secret,"test"),ByteArray(32),"test"))
    }
    @Test fun validatesInvitationsAndAllCommandMappings() {
        val invite = JSONObject().put("v",1).put("id","12345678-1234-1234-1234-123456789abc")
            .put("host","192.168.1.2").put("port",8765).put("secret",RemoteWire.b64(secret))
        fun encode() = "mactv1:" + RemoteWire.b64(invite.toString().toByteArray())
        assertEquals("ws://192.168.1.2:8765/",PairingInvitation.parse(encode()).device.endpoint)
        invite.put("v",2)
        assertThrows(Exception::class.java) { PairingInvitation.parse(encode()) }
        invite.put("v",1).put("host","evil/path")
        assertThrows(Exception::class.java) { PairingInvitation.parse(encode()) }
        RemoteKey.entries.forEach { assertEquals(it.name.lowercase(),RemoteWire.command(RemoteCommand.Press(it)).getString("key")) }
        assertEquals("prime",RemoteWire.command(RemoteCommand.Launch(LaunchApp.PRIME_VIDEO)).getString("app"))
        assertEquals("f1", RemoteWire.command(RemoteCommand.Launch(LaunchApp.F1)).getString("app"))
        assertEquals("football", RemoteWire.command(RemoteCommand.Launch(LaunchApp.FOOTBALL)).getString("app"))
        assertThrows(Exception::class.java) { RemoteWire.command(RemoteCommand.EnterText("x".repeat(2001))) }
        assertThrows(Exception::class.java) { RemoteWire.command(RemoteCommand.MovePointer(Float.NaN,0f)) }
    }
}
