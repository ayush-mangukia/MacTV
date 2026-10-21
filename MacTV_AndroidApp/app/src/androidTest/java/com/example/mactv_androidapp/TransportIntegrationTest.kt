package com.example.mactv_androidapp

import androidx.test.platform.app.InstrumentationRegistry
import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.connection.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test

/** Requires the memory-only Swift ServerHarness; never sends input to the user's desktop. */
class TransportIntegrationTest {
    @Test fun pairCommandsHeartbeatReconnectAndForget() = runBlocking {
        val invitationText = InstrumentationRegistry.getArguments().getString("invitation")
        org.junit.Assume.assumeTrue("Requires isolated ServerHarness invitation", invitationText != null)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = CredentialStore(context,"mactv_transport_test")
        store.clear()
        val connection = MacConnection(context,store)
        try {
            val invite = PairingInvitation.parse(invitationText!!)
            connection.pair(invite)
            val connected = withTimeout(15000) { connection.state.first { it is ConnectionState.Connected || it is ConnectionState.Error } }
            assertTrue("Connection did not authenticate: $connected", connected is ConnectionState.Connected)
            assertNotNull(store.load())
            val appContext = withTimeout(5000) { connection.context.first { it != null } }!!
            assertEquals("spotify", appContext.app)
            assertTrue("app_search" in appContext.keys)
            val commands = RemoteKey.entries.map { RemoteCommand.Press(it) } + LaunchApp.entries.map { RemoteCommand.Launch(it) } + listOf(
                RemoteCommand.MovePointer(12f,-9f), RemoteCommand.Scroll(14f), RemoteCommand.EnterText("Unicode 🎬 café 日本語"))
            commands.forEach { assertEquals(DispatchResult.Delivered,connection.dispatch(it)) }
            delay(18000) // Beyond the idle timeout: authenticated ping/pong must keep it alive.
            assertTrue(connection.state.value is ConnectionState.Connected)
            assertEquals(DispatchResult.Delivered,connection.dispatch(RemoteCommand.EnterText("__mactv_test_drop__")))
            withTimeout(10000) { connection.state.first { it is ConnectionState.Reconnecting } }
            val recovered = withTimeoutOrNull(15000) { connection.state.first { it is ConnectionState.Connected } }
            assertNotNull("Automatic reconnect failed: ${connection.state.value}", recovered)
            assertEquals(DispatchResult.Delivered,connection.dispatch(RemoteCommand.Press(RemoteKey.HOME)))
            connection.disconnect()
            assertEquals(DispatchResult.Disconnected,connection.dispatch(RemoteCommand.Press(RemoteKey.HOME)))
            connection.resume()
            withTimeout(15000) { connection.state.first { it is ConnectionState.Connected } }
            assertEquals(DispatchResult.Delivered,connection.dispatch(RemoteCommand.Press(RemoteKey.HOME)))
            connection.forget()
            assertNull(connection.context.value)
            assertNull(store.load())
            assertEquals(ConnectionState.Disconnected,connection.state.value)
        } finally { connection.close(); store.clear() }
    }
}
