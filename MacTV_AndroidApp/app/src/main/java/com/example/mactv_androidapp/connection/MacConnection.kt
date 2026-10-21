package com.example.mactv_androidapp.connection

import android.content.Context
import android.os.Build
import com.example.mactv_androidapp.command.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.*
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

sealed interface ConnectionState {
    data object Disconnected : ConnectionState
    data object Connecting : ConnectionState
    data object AwaitingApproval : ConnectionState
    data class Reconnecting(val attempt: Int) : ConnectionState
    data class Connected(val device: MacDevice) : ConnectionState
    data class Error(val message: String) : ConnectionState
}
data class AppContext(val app: String = "home", val title: String = "MacTV", val keys: Set<String> = emptySet(), val foreground: Boolean = true, val subtitle: String = "", val volumeAvailable: Boolean = true, val volumeNotice: String = "", val audioOutput: String = "Mac output") {
    companion object {
        fun parse(json: JSONObject): AppContext {
            val app = json.getString("app")
            require(app in setOf("home", "settings", "library", "player", "spotify", "youtube", "netflix", "prime", "f1", "football"))
            val items = json.optJSONArray("keys")
            require(items == null || items.length() <= 32)
            return AppContext(app, json.optString("title", "MacTV").take(200),
                (0 until (items?.length() ?: 0)).map { items!!.getString(it).take(40) }.toSet(),
                json.optBoolean("foreground", true), json.optString("subtitle").take(200), json.optBoolean("volumeAvailable", true), json.optString("volumeNotice").take(300), json.optString("audioOutput", "Mac output").take(100))
        }
    }
}
data class MacDevice(val id: String, val name: String, val endpoint: String)

/** WebSocket carries only public handshake fields or authenticated AES-GCM envelopes. */
class MacConnection(context: Context, private val store: CredentialStore = CredentialStore(context)) : CommandDispatcher {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val client = OkHttpClient.Builder().connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS).build()
    private val mutableState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val state: StateFlow<ConnectionState> = mutableState.asStateFlow()
    private val mutableContext = MutableStateFlow<AppContext?>(null)
    val context: StateFlow<AppContext?> = mutableContext.asStateFlow()
    private var saved = store.load()
    private var socket: WebSocket? = null
    val sessionGeneration: Int @Synchronized get() = generation
    private var generation = 0
    private var desired = false
    private var attempt = 0
    private var reconnect: Job? = null
    private var watch: Job? = null
    private var device: MacDevice? = null
    private var secret: ByteArray? = null
    private var mode = "auth"
    private var clientId = ""
    private var clientNonce = ""
    private var sessionKey: ByteArray? = null
    private var tx = 0L; private var rx = 0L; private var commandId = 0L
    private var lastSeen = 0L
    private val pending = mutableMapOf<Long, CompletableDeferred<DispatchResult>>()
    private fun now() = android.os.SystemClock.elapsedRealtime()

    @Synchronized fun pair(invitation: PairingInvitation) {
        disconnect()
        device = invitation.device; secret = invitation.secret.copyOf(); clientId = UUID.randomUUID().toString()
        mode = "pair"; desired = true; attempt = 0; open()
    }
    @Synchronized fun resume() {
        if (desired) return
        saved = store.load()
        saved?.let {
            device = it.device; secret = it.token; clientId = it.clientId; mode = "auth"
            desired = true; attempt = 0; open()
        }
    }
    @Synchronized fun updateEndpoint(found: MacDevice) {
        val old = saved ?: return
        if (found.id != old.device.id) return
        // Discovery is a locator only. The saved secret must still authenticate this endpoint.
        saved = old.copy(device = found)
        store.save(saved!!)
        if (mutableState.value !is ConnectionState.Connected) { disconnect(); resume() }
    }
    @Synchronized fun disconnect() {
        mutableContext.value = null
        desired = false; generation++; reconnect?.cancel(); watch?.cancel()
        socket?.cancel(); socket = null; sessionKey = null; secret = null
        failPending("Disconnected; commands are never replayed")
        mutableState.value = ConnectionState.Disconnected
    }
    @Synchronized fun forget() { disconnect(); saved = null; store.clear() }
    @Synchronized fun close() { disconnect(); scope.cancel(); client.dispatcher.executorService.shutdown(); client.connectionPool.evictAll() }

    @Synchronized private fun open() {
        val destination = device ?: return
        mutableContext.value = null
        sessionKey = null; tx = 0; rx = 0; lastSeen = now(); clientNonce = RemoteWire.b64(RemoteWire.random())
        val epoch = ++generation
        mutableState.value = if (attempt == 0) ConnectionState.Connecting else ConnectionState.Reconnecting(attempt)
        socket = client.newWebSocket(Request.Builder().url(destination.endpoint).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = synchronized(this@MacConnection) {
                if (epoch != generation) { webSocket.cancel(); return@synchronized }
                webSocket.send(JSONObject().put("v",1).put("type","hello").put("mode",mode)
                    .put("serverId",destination.id).put("clientId",clientId).put("nonce",clientNonce)
                    .put("capabilities", org.json.JSONArray().put("context.v1"))
                    .put("name", "${Build.MANUFACTURER} ${Build.MODEL}".take(64)).toString())
            }
            override fun onMessage(webSocket: WebSocket, text: String) = synchronized(this@MacConnection) {
                if (epoch != generation) return@synchronized
                try {
                    require(text.toByteArray().size <= 16384)
                    message(JSONObject(text), webSocket)
                } catch (_: Exception) { failed(epoch, "Authentication or protocol check failed. Pair again if this Mac was reset.", retry = false) }
            }
            override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) {
                synchronized(this@MacConnection) { failed(epoch,"Unexpected binary frame", retry = false) }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                synchronized(this@MacConnection) { failed(epoch,"Mac unavailable. Check Wi-Fi, permissions, and MacTV.") }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
                synchronized(this@MacConnection) { failed(epoch,"Mac disconnected") }
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                synchronized(this@MacConnection) { failed(epoch,"Mac disconnected") }
            }
        })
        watch?.cancel()
        watch = scope.launch {
            while (isActive) {
                delay(5000)
                synchronized(this@MacConnection) {
                    if (epoch != generation) return@launch
                    val timeout = if (mutableState.value == ConnectionState.AwaitingApproval) 65000 else 16000
                    if (now() - lastSeen > timeout) failed(epoch,"Connection timed out")
                    else if (mutableState.value is ConnectionState.Connected) secure(JSONObject().put("type","ping"))
                }
            }
        }
    }
    private fun message(json: JSONObject, webSocket: WebSocket) {
        require(json.getInt("v") == 1)
        val key = sessionKey
        if (key == null) {
            require(json.getString("type") == "challenge")
            val serverNonce = json.getString("nonce")
            val shared = secret ?: error("No credential")
            val transcript = "1|${device!!.id}|$mode|$clientId|$clientNonce|$serverNonce"
            require(RemoteWire.verify(json.getString("proof"), shared, "server|$transcript"))
            sessionKey = RemoteWire.key(shared,clientNonce,serverNonce)
            webSocket.send(JSONObject().put("v",1).put("type","proof").put("proof",RemoteWire.proof(shared,"client|$transcript")).toString())
            secret = null; lastSeen = now()
            return
        }
        val payload = RemoteWire.open(json,key,"S2C!",rx+1); rx++; lastSeen = now()
        when(payload.getString("type")) {
            "pending" -> { require(mode == "pair"); mutableState.value = ConnectionState.AwaitingApproval }
            "paired" -> {
                require(mode == "pair" && payload.getString("serverId") == device!!.id)
                val token = RemoteWire.decode(payload.getString("token")); require(token.size == 32)
                val credential = CredentialStore.Saved(device!!,clientId,token)
                store.save(credential); saved = credential
            }
            "ready" -> {
                require(payload.getString("serverId") == device!!.id && (mode == "auth" || saved?.clientId == clientId))
                mutableState.value = ConnectionState.Connected(device!!); mode = "auth"; attempt = 0
            }
            "context" -> {
                require(mutableState.value is ConnectionState.Connected)
                mutableContext.value = AppContext.parse(payload)
            }
            "ping" -> secure(JSONObject().put("type","pong"))
            "pong" -> Unit
            "ack" -> {
                val id = payload.getLong("id")
                val status = payload.getString("status")
                pending.remove(id)?.complete(if (status == "dispatched") DispatchResult.Delivered
                    else DispatchResult.Failed(payload.optString("message", "Mac could not handle command")))
            }
            else -> error("Unsupported message")
        }
    }
    private fun secure(payload: JSONObject): Boolean {
        val key = sessionKey ?: return false
        return socket?.send(RemoteWire.seal(payload,key,"C2S!",++tx).toString()) == true
    }
    override suspend fun dispatch(command: RemoteCommand): DispatchResult {
        val response: CompletableDeferred<DispatchResult>
        val id: Long
        synchronized(this) {
            if (mutableState.value !is ConnectionState.Connected) return DispatchResult.Disconnected
            id = ++commandId; response = CompletableDeferred(); pending[id] = response
            try {
                if (!secure(JSONObject().put("type","command").put("id",id).put("command",RemoteWire.command(command)))) {
                    pending.remove(id); failed(generation,"Command could not be sent"); return DispatchResult.Failed("Command could not be sent")
                }
            } catch (_: Exception) { pending.remove(id); return DispatchResult.Failed("Invalid command") }
        }
        return try { withTimeout(4000) { response.await() } }
        catch (_: TimeoutCancellationException) {
            synchronized(this) { failed(generation,"Command acknowledgement timed out") }
            DispatchResult.Failed("No acknowledgement; command was not retried")
        } finally { synchronized(this) { pending.remove(id) } }
    }
    private fun failPending(reason: String) { pending.values.forEach { it.complete(DispatchResult.Failed(reason)) }; pending.clear() }
    private fun failed(epoch: Int, reason: String, retry: Boolean = true) {
        if (epoch != generation) return
        mutableContext.value = null
        generation++; socket?.cancel(); socket = null; sessionKey = null; watch?.cancel()
        failPending(reason)
        if (desired && retry && mode == "auth" && saved != null) {
            attempt++; mutableState.value = ConnectionState.Reconnecting(attempt)
            reconnect?.cancel()
            reconnect = scope.launch {
                delay((1000L shl attempt.coerceAtMost(5)).coerceAtMost(30000) + kotlin.random.Random.nextLong(500))
                synchronized(this@MacConnection) {
                    if (desired) { secret = saved!!.token; device = saved!!.device; open() }
                }
            }
        } else {
            desired = false; mutableState.value = ConnectionState.Error(reason)
        }
    }
}
