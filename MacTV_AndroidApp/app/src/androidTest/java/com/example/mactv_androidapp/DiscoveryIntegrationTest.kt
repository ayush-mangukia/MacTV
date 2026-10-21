package com.example.mactv_androidapp

import androidx.test.platform.app.InstrumentationRegistry
import com.example.mactv_androidapp.connection.MacDiscovery
import com.example.mactv_androidapp.connection.PairingInvitation
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in multicast discovery check against the isolated Swift receiver on the same LAN. */
class DiscoveryIntegrationTest {
    @Test fun discoversAdvertisedMacIdentityAndEndpoint() = runBlocking {
        val invitation = InstrumentationRegistry.getArguments().getString("invitation")
        assumeTrue("Requires isolated ServerHarness invitation", invitation != null)
        val expected = PairingInvitation.parse(invitation!!).device
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val discovery = MacDiscovery(InstrumentationRegistry.getInstrumentation().targetContext, scope) { }
        var error: String? = null
        try {
            withContext(Dispatchers.Main) { discovery.start { error = it } }
            val found = withTimeoutOrNull(22000) {
                discovery.devices.first { devices -> devices.any { it.id == expected.id } }.first { it.id == expected.id }
            }
            assertNotNull(error ?: "MacTV was not discovered; check multicast reachability on this network", found)
            assertTrue(found!!.endpoint.startsWith("ws://"))
            assertEquals(expected.id, found.id)
        } finally {
            withContext(Dispatchers.Main) { discovery.stop() }
            scope.cancel()
        }
    }
}
