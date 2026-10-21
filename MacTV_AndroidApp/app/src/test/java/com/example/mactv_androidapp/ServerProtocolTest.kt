package com.example.mactv_androidapp

import com.example.mactv_androidapp.connection.*
import okhttp3.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Opt-in, against ServerHarness only. Covers the real Network.framework WebSocket receiver. */
class ServerProtocolTest {
    private class Peer(val invitation: PairingInvitation, val secret: ByteArray = invitation.secret,
                       val id: String = UUID.randomUUID().toString(), val mode: String = "pair", val name: String = "JVM transport test", val contextual: Boolean = false) : AutoCloseable {
        val client = OkHttpClient()
        val messages = LinkedBlockingQueue<String>()
        val ws = client.newWebSocket(Request.Builder().url(invitation.device.endpoint).build(),object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) { messages.put(text) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { messages.offer("CLOSED") }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { messages.offer("CLOSED"); webSocket.close(code,null) }
        })
        val nonce = RemoteWire.b64(RemoteWire.random())
        var key: ByteArray? = null
        var tx = 0L; var rx = 0L
        fun send(json: JSONObject) { assertTrue(ws.send(json.toString())) }
        fun next(): JSONObject = JSONObject(messages.poll(8,TimeUnit.SECONDS) ?: error("No response"))
        fun hello(version: Int = 1) { send(JSONObject().put("v",version).put("type","hello").put("serverId",invitation.device.id)
            .put("clientId",id).put("mode",mode).put("nonce",nonce).put("name",name).put("capabilities", org.json.JSONArray().apply { if (contextual) put("context.v1") })) }
        fun authenticate(wrongProof: Boolean = false) {
            hello()
            val challenge = next()
            val sn = challenge.getString("nonce")
            val transcript = "1|${invitation.device.id}|$mode|$id|$nonce|$sn"
            assertTrue(RemoteWire.verify(challenge.getString("proof"),secret,"server|$transcript"))
            key = RemoteWire.key(secret,nonce,sn)
            send(JSONObject().put("v",1).put("type","proof").put("proof",if(wrongProof) RemoteWire.b64(ByteArray(32)) else RemoteWire.proof(secret,"client|$transcript")))
        }
        fun secure(payload: JSONObject): JSONObject = RemoteWire.seal(payload,key!!,"C2S!",++tx).also { send(it) }
        fun payload(): JSONObject = RemoteWire.open(next(),key!!,"S2C!",++rx)
        fun closed(timeout: Long = 8) { assertEquals("CLOSED",messages.poll(timeout,TimeUnit.SECONDS)) }
        override fun close() { ws.cancel(); client.dispatcher.executorService.shutdown(); client.connectionPool.evictAll() }
    }
    @Test fun rejectsUnauthenticatedWrongVersionWrongProofRejectionReplayAndTamper() {
        val path = System.getenv("MAC_TV_TEST_INVITATION")
        assumeTrue("Run with isolated ServerHarness",path != null)
        val invite = PairingInvitation.parse(File(path!!).readText())
        Peer(invite).use { it.hello(2); it.closed() }
        Peer(invite).use { it.send(JSONObject().put("v",1).put("type","command")); it.closed() }
        Peer(invite).use { it.authenticate(wrongProof = true); it.closed() }
        Peer(invite, secret = ByteArray(32)).use {
            it.hello(); val challenge = it.next()
            val transcript = "server|1|${invite.device.id}|pair|${it.id}|${it.nonce}|${challenge.getString("nonce") }"
            assertFalse(RemoteWire.verify(challenge.getString("proof"),it.secret,transcript))
        }
        Peer(invite,name = "reject-test").use { it.authenticate(); assertEquals("pending",it.payload().getString("type")); it.closed() }
        var token = ByteArray(0); var id = ""
        Peer(invite).use {
            it.authenticate(); assertEquals("pending",it.payload().getString("type"))
            val paired = it.payload(); assertEquals("paired",paired.getString("type"))
            token = RemoteWire.decode(paired.getString("token")); id = it.id
            assertEquals("ready",it.payload().getString("type"))
        }
        Peer(invite,token,id,"auth", contextual = true).use {
            it.authenticate(); assertEquals("ready",it.payload().getString("type"))
            val context = AppContext.parse(it.payload())
            assertEquals("spotify", context.app)
            assertTrue("app_search" in context.keys)
            val frame = it.secure(JSONObject().put("type","command").put("id",1).put("command",JSONObject().put("kind","key").put("key","home")))
            assertEquals("dispatched",it.payload().getString("status"))
            it.send(frame); it.closed()
        }
        Peer(invite,token,id,"auth").use {
            it.authenticate(); assertEquals("ready",it.payload().getString("type"))
            it.send(RemoteWire.seal(JSONObject().put("type","ping"),it.key!!,"C2S!",1).put("body",RemoteWire.b64(ByteArray(32))))
            it.closed()
        }
        Peer(invite,token,id,"auth").use {
            it.authenticate(); assertEquals("ready",it.payload().getString("type"))
            it.secure(JSONObject().put("type","command").put("id",1).put("command",JSONObject().put("kind","unknown")))
            assertEquals("unsupported",it.payload().getString("status"))
            // Do not answer application heartbeats; receiver must drop a stale connection.
            var closed = false
            val messages = it.messages
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(26)
            while(!closed && System.nanoTime() < deadline) {
                closed = messages.poll(1,TimeUnit.SECONDS) == "CLOSED"
            }
            assertTrue("Stale authenticated connection stayed open",closed)
        }
    }
}
