package com.example.mactv_androidapp

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.mactv_androidapp.command.RemoteCommand
import com.example.mactv_androidapp.command.RemoteKey
import com.example.mactv_androidapp.ui.RemoteViewModel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Tests the real ViewModel queue with its local recorder; never sends desktop input. */
@RunWith(AndroidJUnit4::class)
class TouchpadOrderingTest {
    @Test fun movementAndScrollArriveBeforeFollowingTap() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as Application
        val store = ViewModelStore()
        lateinit var vm: RemoteViewModel
        instrumentation.runOnMainSync {
            val factory = object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = RemoteViewModel(app) as T
            }
            vm = ViewModelProvider(store, factory)[RemoteViewModel::class.java]
            vm.setTestMode(true)
        }
        try {
            // Allow the initial disconnected state collector to clear its queue first.
            Thread.sleep(100)
            instrumentation.runOnMainSync {
                vm.send(RemoteCommand.MovePointer(12f, -8f))
                vm.send(RemoteCommand.Press(RemoteKey.CLICK))
            }
            await { vm.state.value.commandCount == 2 }
            Thread.sleep(100)
            assertEquals(2, vm.state.value.commandCount)
            assertEquals("Local test · click", vm.state.value.feedback)
            instrumentation.runOnMainSync {
                vm.send(RemoteCommand.Scroll(20f))
                vm.send(RemoteCommand.Press(RemoteKey.CLICK))
            }
            await { vm.state.value.commandCount == 4 }
            Thread.sleep(100)
            assertEquals("Local test · click", vm.state.value.feedback)
            instrumentation.runOnMainSync { vm.send(RemoteCommand.Press(RemoteKey.APP_SEARCH)) }
            assertEquals(com.example.mactv_androidapp.ui.InputMode.KEYBOARD, vm.state.value.mode)
            await { vm.state.value.commandCount == 5 }
            instrumentation.runOnMainSync { vm.updateText("Test song"); vm.sendText() }
            await { vm.state.value.commandCount == 6 }
            assertEquals(com.example.mactv_androidapp.ui.InputMode.BUTTONS, vm.state.value.mode)
            assertEquals("", vm.state.value.keyboardText)
        } finally { instrumentation.runOnMainSync { store.clear() } }
    }
    private fun await(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 3000
        while (!condition() && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertTrue("Remote input queue did not finish", condition())
    }
}
