package com.example.mactv_androidapp

import androidx.test.platform.app.InstrumentationRegistry
import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.connection.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in only: prepare Football context and a disposable foreground Chrome tab.
 * Closes exactly that current tab; never changes pairing or exports credentials. */
class FootballTabTest {
    @Test fun closePreparedCurrentTab() = runBlocking {
        val prepare = InstrumentationRegistry.getArguments().getString("prepareFootball") == "true"
        assumeTrue(prepare || InstrumentationRegistry.getArguments().getString("closePreparedTab") == "true")
        val connection = MacConnection(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            connection.resume()
            withTimeout(12000) { connection.state.first { it is ConnectionState.Connected } }
            if (prepare) {
                assertEquals(DispatchResult.Delivered, connection.dispatch(RemoteCommand.Launch(LaunchApp.FOOTBALL)))
                withTimeout(10000) { connection.context.first { it?.app == "football" } }
                return@runBlocking
            }
            val context = withTimeout(5000) { connection.context.first { it != null } }!!
            assertEquals("Prepare Football context first", "football", context.app)
            assertTrue("Close tab is not advertised", "close_tab" in context.keys)
            assertEquals(DispatchResult.Delivered, connection.dispatch(RemoteCommand.Press(RemoteKey.CLOSE_TAB)))
        } finally { connection.close() }
    }
}
