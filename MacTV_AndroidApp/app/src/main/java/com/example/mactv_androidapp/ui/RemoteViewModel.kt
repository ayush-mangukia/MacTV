package com.example.mactv_androidapp.ui

import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import kotlinx.coroutines.Job
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.connection.ConnectionState
import com.example.mactv_androidapp.connection.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

enum class Destination { REMOTE, DEVICES, SETTINGS }
enum class InputMode { BUTTONS, TOUCHPAD, KEYBOARD }

data class RemoteUiState(
    val destination: Destination = Destination.REMOTE,
    val mode: InputMode = InputMode.BUTTONS,
    val connection: ConnectionState = ConnectionState.Disconnected,
    val appContext: AppContext? = null,
    val haptics: Boolean = true,
    val testMode: Boolean = false,
    val keyboardText: String = "",
    val feedback: String = "Commands stay on this phone until a Mac is paired.",
    val controlIssue: String? = null,
    val commandCount: Int = 0,
    val pairingInfo: Boolean = false,
    val devices: List<MacDevice> = emptyList(),
    val invitationText: String = ""
)

class RemoteViewModel(application: Application) : AndroidViewModel(application) {
    private val transport = MacConnection(application)
    private val recorder = MockCommandDispatcher()
    private val discovery = MacDiscovery(application, viewModelScope, transport::updateEndpoint)
    private data class Queued(val command: RemoteCommand, val local: Boolean, val epoch: Int)
    private val connectivity = application.getSystemService(ConnectivityManager::class.java)
    private var monitoringNetwork = false
    private var networkRefresh: Job? = null
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = networkChanged()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = networkChanged()
    }
    private fun networkChanged() {
        viewModelScope.launch {
            if (!monitoringNetwork) return@launch
            networkRefresh?.cancel()
            networkRefresh = viewModelScope.launch {
                delay(500)
                if (monitoringNetwork && networkAllowed()) {
                    transport.resume()
                    discovery.start { error -> mutableState.update { it.copy(feedback = error) } }
                }
            }
        }
    }
    private fun stopNetworkMonitoring() {
        networkRefresh?.cancel(); networkRefresh = null
        if (monitoringNetwork) runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        monitoringNetwork = false
    }
    private var pointerX = 0f; private var pointerY = 0f; private var scroll = 0f
    private fun networkAllowed() = Build.VERSION.SDK_INT < 37 ||
        getApplication<Application>().checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") == PackageManager.PERMISSION_GRANTED
    fun resume() {
        if(networkAllowed()) {
            if (!monitoringNetwork) {
                monitoringNetwork = true
                runCatching { connectivity.registerDefaultNetworkCallback(networkCallback) }
                    .onFailure { monitoringNetwork = false }
            }
            transport.resume()
            discovery.start { error -> mutableState.update { it.copy(feedback = error) } }
        }
    }
    fun suspendConnection() { stopNetworkMonitoring(); discovery.stop(); transport.disconnect() }
    fun reconnect() { transport.disconnect(); resume() }
    fun disconnect() { transport.disconnect() }
    fun forget() { transport.forget() }
    fun updateInvitation(value: String) { mutableState.update { it.copy(invitationText = value.take(4096)) } }
    fun pair() {
        if(!networkAllowed()) { permissionDenied(); return }
        try {
            val invite = PairingInvitation.parse(state.value.invitationText)
            transport.pair(invite)
            mutableState.update { it.copy(invitationText = "", pairingInfo = false, testMode = false) }
        } catch (_: Exception) { mutableState.update { it.copy(feedback = "Invalid invitation. Create a fresh invitation in MacTV Settings.") } }
    }
    fun permissionDenied() { mutableState.update { it.copy(feedback = "Local network permission is needed. Allow it in Android Settings to connect.") } }

    private val mutableState = MutableStateFlow(RemoteUiState())
    val state: StateFlow<RemoteUiState> = mutableState.asStateFlow()
    // Bounded queue keeps gesture bursts ordered without accumulating unbounded jobs.
    private val commands = Channel<Queued>(16)

    init {
        viewModelScope.launch { transport.context.collect { context -> mutableState.update { it.copy(appContext = context) } } }
        viewModelScope.launch {
            transport.state.collect { connection ->
                if (connection !is ConnectionState.Connected) {
                    while(commands.tryReceive().isSuccess) { }
                    pointerX = 0f; pointerY = 0f; scroll = 0f
                }
                if (connection is ConnectionState.Reconnecting && (connection.attempt == 1 || connection.attempt % 3 == 0) && networkAllowed()) {
                    discovery.start { error -> mutableState.update { it.copy(feedback = error) } }
                }
                mutableState.update { it.copy(connection = connection, controlIssue = if (connection is ConnectionState.Connected) it.controlIssue else null,
                    feedback = when (connection) {
                        is ConnectionState.Connected -> "Connected securely to your Mac."
                        is ConnectionState.Reconnecting -> "Can't reach your Mac. Check both devices' Wi-Fi and use Find Macs in Devices if the address changed."
                        is ConnectionState.Error -> connection.message
                        else -> it.feedback
                    }) }
            }
        }
        viewModelScope.launch { discovery.devices.collect { devices -> mutableState.update { it.copy(devices = devices) } } }
        viewModelScope.launch {
            while(true) {
                delay(33)
                if (pointerX != 0f || pointerY != 0f) {
                    enqueue(RemoteCommand.MovePointer(pointerX.coerceIn(-500f,500f),pointerY.coerceIn(-500f,500f)))
                    pointerX = 0f; pointerY = 0f
                }
                if(scroll != 0f) { enqueue(RemoteCommand.Scroll(scroll.coerceIn(-500f,500f))); scroll = 0f }
            }
        }
        viewModelScope.launch {
            for (queued in commands) {
                val command = queued.command
                val result = try {
                    if (queued.local && state.value.testMode) recorder.dispatch(command)
                    else if (!queued.local && !state.value.testMode && queued.epoch == transport.sessionGeneration) transport.dispatch(command)
                    else DispatchResult.Disconnected
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    DispatchResult.Failed("Command could not be processed")
                }
                mutableState.update { current ->
                    val it = current.afterTextDispatch(command, result)
                    it.copy(
                        commandCount = it.commandCount + 1,
                        controlIssue = when {
                            result is DispatchResult.Failed -> result.reason
                            result is DispatchResult.Delivered -> null
                            command is RemoteCommand.Launch || command == RemoteCommand.Press(RemoteKey.HOME) -> null
                            else -> it.controlIssue
                        },
                        feedback = when (result) {
                            DispatchResult.RecordedLocally -> "Local test · " + command.label()
                            DispatchResult.Disconnected -> "Disconnected · command not sent"
                            DispatchResult.Delivered -> "Mac acknowledged · " + command.label()
                            is DispatchResult.Failed -> result.reason
                        }
                    )
                }
            }
        }
    }

    fun navigate(destination: Destination) { mutableState.update { it.copy(destination = destination) } }
    fun setMode(mode: InputMode) {
        while(commands.tryReceive().isSuccess) { }
        pointerX = 0f; pointerY = 0f; scroll = 0f
        mutableState.update { it.copy(mode = mode) }
    }
    fun setHaptics(enabled: Boolean) { mutableState.update { it.copy(haptics = enabled) } }
    fun setTestMode(enabled: Boolean) {
        while(commands.tryReceive().isSuccess) { }
        pointerX = 0f; pointerY = 0f; scroll = 0f
        mutableState.update { it.copy(testMode = enabled, feedback = if (enabled)
            "Local test enabled · nothing is sent to a Mac."
        else "Commands stay on this phone until a Mac is paired.") }
    }
    fun updateText(text: String) { mutableState.update { it.copy(keyboardText = text.take(2000)) } }
    fun showPairing(show: Boolean) { mutableState.update { it.copy(pairingInfo = show) } }
    fun discover() {
        if(!networkAllowed()) { permissionDenied(); return }
        mutableState.update { it.copy(feedback = "Looking for MacTV for 20 seconds…") }
        discovery.start { error -> mutableState.update { it.copy(feedback = error) } }
        transport.resume()
    }
    fun send(command: RemoteCommand) {
        if (!state.value.testMode && state.value.connection !is ConnectionState.Connected) {
            mutableState.update { it.copy(feedback = "Disconnected · pair or reconnect in Devices.", controlIssue = "Open Devices to reconnect before sending controls.") }; return
        }
        if (command == RemoteCommand.Press(RemoteKey.APP_SEARCH)) mutableState.update { it.copy(mode = InputMode.KEYBOARD) }
        when(command) {
            is RemoteCommand.MovePointer -> { pointerX += command.dx; pointerY += command.dy }
            is RemoteCommand.Scroll -> { scroll += command.delta }
            else -> { flushPointer(); enqueue(command) }
        }
    }
    private fun flushPointer() {
        if (pointerX != 0f || pointerY != 0f) {
            enqueue(RemoteCommand.MovePointer(pointerX.coerceIn(-500f, 500f), pointerY.coerceIn(-500f, 500f)))
            pointerX = 0f; pointerY = 0f
        }
        if (scroll != 0f) { enqueue(RemoteCommand.Scroll(scroll.coerceIn(-500f, 500f))); scroll = 0f }
    }
    private fun enqueue(command: RemoteCommand) {
        if (!commands.trySend(Queued(command,state.value.testMode,transport.sessionGeneration)).isSuccess) {
            mutableState.update { it.copy(feedback = "Remote busy · input dropped; try again") }
        }
    }
    fun sendText() {
        val text = state.value.keyboardText
        if (text.isNotBlank()) send(RemoteCommand.EnterText(text))
    }
    override fun onCleared() { stopNetworkMonitoring(); discovery.stop(); transport.close(); commands.close(); super.onCleared() }
}

private fun RemoteCommand.label(): String = when (this) {
    is RemoteCommand.Press -> key.name.lowercase().replace('_', ' ')
    is RemoteCommand.Launch -> "Open " + app.title
    is RemoteCommand.EnterText -> "Text (contents hidden)"
    is RemoteCommand.MovePointer -> "Pointer moved"
    is RemoteCommand.Scroll -> "Scroll"
}

private fun RemoteCommand.isPointerInput(): Boolean = this is RemoteCommand.MovePointer || this is RemoteCommand.Scroll || this == RemoteCommand.Press(RemoteKey.CLICK)

/** Acknowledgement ends typing only if this is still the draft the user sent. */
internal fun RemoteUiState.afterTextDispatch(command: RemoteCommand, result: DispatchResult): RemoteUiState {
    val accepted = result == DispatchResult.Delivered || result == DispatchResult.RecordedLocally
    return if (accepted && command is RemoteCommand.EnterText && mode == InputMode.KEYBOARD && keyboardText == command.text)
        copy(mode = InputMode.BUTTONS, keyboardText = "") else this
}
