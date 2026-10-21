package com.example.mactv_androidapp.connection

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.HttpUrl
import java.net.Inet4Address
import java.util.UUID

/** DNS-SD gives locators only; authentication still requires the invitation or saved secret. */
class MacDiscovery(context: Context, private val scope: CoroutineScope, private val found: (MacDevice) -> Unit) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val mutableDevices = MutableStateFlow<List<MacDevice>>(emptyList())
    val devices: StateFlow<List<MacDevice>> = mutableDevices.asStateFlow()
    private var listener: NsdManager.DiscoveryListener? = null
    private val resolved = mutableMapOf<String,MacDevice>()
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var generation = 0
    private var timer: Job? = null
    fun start(error: (String) -> Unit) {
        stop(); mutableDevices.value = emptyList(); resolved.clear()
        val epoch = generation
        val current = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) { scope.launch { if(epoch == generation) { stop(); error("Discovery unavailable ($code). Paste an invitation to connect directly.") } } }
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
            override fun onServiceFound(info: NsdServiceInfo) { scope.launch { if(epoch == generation) { queue.add(info); resolveNext(epoch) } } }
            override fun onServiceLost(info: NsdServiceInfo) { scope.launch { if(epoch == generation) { resolved.remove(info.serviceName); mutableDevices.value = resolved.values.toList() } } }
        }
        listener = current
        try { manager.discoverServices("_mactv._tcp.", NsdManager.PROTOCOL_DNS_SD, current) }
        catch (_: Exception) { stop(); error("Allow local network access to discover your Mac") }
        timer = scope.launch { delay(20000); stop() }
    }
    @Suppress("DEPRECATION") private fun resolveNext(epoch: Int) {
        if (resolving || queue.isEmpty() || epoch != generation) return
        resolving = true
        val info = queue.removeFirst()
        try { manager.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, code: Int) { scope.launch { if(epoch == generation) { resolving = false; resolveNext(epoch) } } }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) { scope.launch {
                if(epoch != generation) return@launch
                try {
                    val id = serviceInfo.attributes["id"]?.toString(Charsets.UTF_8) ?: error("No identity")
                    UUID.fromString(id)
                    require(serviceInfo.attributes["v"]?.toString(Charsets.UTF_8) == "1")
                    val address = (serviceInfo.hostAddresses.firstOrNull { it is Inet4Address } ?: serviceInfo.hostAddresses.first()).hostAddress!!
                    val endpoint = HttpUrl.Builder().scheme("http").host(address).port(serviceInfo.port).build().toString().replaceFirst("http:","ws:")
                    val device = MacDevice(id,serviceInfo.serviceName,endpoint)
                    resolved[serviceInfo.serviceName] = device; mutableDevices.value = resolved.values.toList(); found(device)
                } catch (_: Exception) { /* Ignore malformed or incompatible advertisements. */ }
                resolving = false; resolveNext(epoch)
            } }
        }) } catch (_: Exception) { resolving = false; resolveNext(epoch) }
    }
    fun stop() {
        generation++; timer?.cancel(); timer = null
        listener?.let { try { manager.stopServiceDiscovery(it) } catch (_: Exception) {} }
        listener = null; queue.clear(); resolving = false
    }
}
