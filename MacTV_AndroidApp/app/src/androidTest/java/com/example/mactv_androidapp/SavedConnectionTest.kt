package com.example.mactv_androidapp

import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.example.mactv_androidapp.connection.ConnectionState
import com.example.mactv_androidapp.connection.CredentialStore
import java.net.Socket
import java.net.InetSocketAddress
import java.net.URI
import com.example.mactv_androidapp.ui.RemoteViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in recovery check against the already paired Mac. No credentials are exported
 * and no desktop input, pairing, or permission changes are performed. */
class SavedConnectionTest {
    @Test fun foregroundRemoteRecoversSavedConnection() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("savedConnection") == "true")
        val saved = CredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).load()
        assertTrue("Existing pairing is missing", saved != null)
        val endpoint = URI(saved!!.device.endpoint)
        val tcp = runCatching { Socket().use { it.connect(InetSocketAddress(endpoint.host, endpoint.port), 3000) }; "reachable" }.getOrElse { it.javaClass.simpleName }
        val directHost = InstrumentationRegistry.getArguments().getString("macHost")
        val direct = directHost?.let { host -> runCatching { Socket().use { it.connect(InetSocketAddress(host, 8765), 3000) }; "reachable" }.getOrElse { it.javaClass.simpleName } }
        println("Saved endpoint=${endpoint.host}:${endpoint.port}; TCP=$tcp; current Mac=$direct")
        if (InstrumentationRegistry.getArguments().getString("reachabilityOnly") == "true") {
            assertTrue("Saved ${endpoint.host}:${endpoint.port}=$tcp; current Mac $directHost=$direct", direct == "reachable")
            return@runBlocking
        }
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var remote: RemoteViewModel
        scenario.onActivity {
            it.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            remote = ViewModelProvider(it)[RemoteViewModel::class.java]; remote.reconnect()
        }
        try {
            withTimeout(25000) { remote.state.first { it.connection is ConnectionState.Connected } }
            scenario.recreate()
            scenario.onActivity {
                it.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                remote = ViewModelProvider(it)[RemoteViewModel::class.java]
            }
            withTimeout(25000) { remote.state.first { it.connection is ConnectionState.Connected } }
            delay(18000) // Context parsing and multiple authenticated heartbeats must survive.
            val state = remote.state.value
            assertTrue("Connection after heartbeats: ${state.connection}; activity=${scenario.state}", state.connection is ConnectionState.Connected)
            assertTrue("Authenticated context missing", state.appContext != null)
            println("Saved pairing recovered; authenticated context and heartbeats passed")
        } catch (error: Exception) {
            throw AssertionError("Saved connection failed: ${remote.state.value.connection}; ${remote.state.value.feedback}; saved=${endpoint.host}:${endpoint.port} TCP=$tcp currentMac=$direct", error)
        } finally { scenario.close() }
    }
}
