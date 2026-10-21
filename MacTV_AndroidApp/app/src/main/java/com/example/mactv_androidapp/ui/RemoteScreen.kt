package com.example.mactv_androidapp.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalContext
import android.os.Build
import android.content.pm.PackageManager
import com.example.mactv_androidapp.connection.ConnectionState
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.mactv_androidapp.command.*
import com.example.mactv_androidapp.ui.theme.*

@Composable
fun MacTVRemoteApp(viewModel: RemoteViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    BackHandler(state.destination != Destination.REMOTE || state.mode != InputMode.BUTTONS) {
        if (state.destination != Destination.REMOTE) viewModel.navigate(Destination.REMOTE)
        else viewModel.setMode(InputMode.BUTTONS)
    }
    val context = LocalContext.current
    var pendingAction by remember { mutableStateOf<(() -> Unit)?>(null) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        if(allowed) pendingAction?.invoke() else viewModel.permissionDenied()
        pendingAction = null
    }
    val networkAction: (() -> Unit) -> Unit = { action ->
        if(Build.VERSION.SDK_INT >= 37 && context.checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") != PackageManager.PERMISSION_GRANTED) {
            pendingAction = action; permission.launch("android.permission.ACCESS_LOCAL_NETWORK")
        } else action()
    }
    RemoteAppContent(state, viewModel::navigate, viewModel::setMode, viewModel::send,
        viewModel::updateText, viewModel::sendText, viewModel::setHaptics,
        viewModel::setTestMode, viewModel::showPairing, { networkAction(viewModel::discover) },
        viewModel::updateInvitation, { networkAction(viewModel::pair) }, viewModel::disconnect,
        { networkAction(viewModel::reconnect) }, viewModel::forget)
}

@Composable
fun RemoteAppContent(
    state: RemoteUiState,
    navigate: (Destination) -> Unit = {},
    setMode: (InputMode) -> Unit = {},
    send: (RemoteCommand) -> Unit = {},
    updateText: (String) -> Unit = {},
    sendText: () -> Unit = {},
    setHaptics: (Boolean) -> Unit = {},
    setTestMode: (Boolean) -> Unit = {},
    showPairing: (Boolean) -> Unit = {},
    discover: () -> Unit = {},
    updateInvitation: (String) -> Unit = {},
    pair: () -> Unit = {},
    disconnect: () -> Unit = {},
    reconnect: () -> Unit = {},
    forget: () -> Unit = {}
) {
    val haptics = LocalHapticFeedback.current
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val contentScroll = rememberScrollState()
    LaunchedEffect(state.destination) { contentScroll.scrollTo(0) }
    LaunchedEffect(state.mode) {
        if (state.mode != InputMode.KEYBOARD) { focusManager.clearFocus(); keyboard?.hide() }
    }
    val command: (RemoteCommand) -> Unit = {
        if (state.haptics && it !is RemoteCommand.MovePointer && it !is RemoteCommand.Scroll) {
            haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        }
        send(it)
    }
    Scaffold(
        containerColor = Ink,
        contentWindowInsets = WindowInsets.safeDrawing,
        bottomBar = {
            NavigationBar(containerColor = Ink, tonalElevation = 0.dp) {
                Destination.entries.forEach { destination ->
                    val icon = when (destination) {
                        Destination.REMOTE -> Glyph.REMOTE
                        Destination.DEVICES -> Glyph.DEVICES
                        Destination.SETTINGS -> Glyph.SETTINGS
                    }
                    NavigationBarItem(
                        selected = state.destination == destination,
                        onClick = { navigate(destination) },
                        icon = { RemoteIcon(icon, Modifier.size(22.dp)) },
                        label = { Text(destination.name.lowercase().replaceFirstChar { it.uppercase() }) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = Amber, selectedTextColor = Amber,
                            indicatorColor = Amber.copy(alpha = .10f),
                            unselectedIconColor = Muted, unselectedTextColor = Muted
                        )
                    )
                }
            }
        }
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
            if (state.destination == Destination.REMOTE) {
                Box(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 10.dp), contentAlignment = Alignment.Center) {
                    Column(Modifier.widthIn(max = 500.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        ModeSelector(state.mode, setMode)
                        if (state.mode != InputMode.KEYBOARD) PlaybackControls(command, state.appContext?.app, state.appContext?.volumeAvailable ?: true)
                    }
                }
            }
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(contentScroll)
                    .padding(horizontal = 24.dp).padding(top = 12.dp, bottom = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Column(Modifier.widthIn(max = 500.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (state.destination != Destination.REMOTE) AppHeader(state.destination)
                    if (state.destination == Destination.DEVICES) ConnectionCard(state.connection) { navigate(Destination.DEVICES) }
                    AnimatedContent(state.destination, label = "Screen") { destination ->
                        when (destination) {
                            Destination.REMOTE -> Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                state.controlIssue?.let { issue ->
                                    Surface(color = Amber.copy(alpha = .09f), shape = RoundedCornerShape(18.dp), border = BorderStroke(1.dp, Amber.copy(alpha = .3f))) {
                                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                            Text("Mac control needs attention", color = Amber, fontWeight = FontWeight.SemiBold)
                                            Text(issue, color = Muted, style = MaterialTheme.typography.bodySmall)
                                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                                if (state.appContext?.app in setOf("spotify", "youtube", "netflix", "prime", "f1", "football")) OpenActiveApp(state.appContext!!.title, command)
                                                TextButton(onClick = { command(RemoteCommand.Press(RemoteKey.INPUT_SETTINGS)) }) { Text("Mac permission") }
                                            }
                                        }
                                    }
                                }
                                if (state.mode == InputMode.KEYBOARD && state.appContext != null) {
                                    Text("Typing in ${state.appContext.title}", color = Amber, style = MaterialTheme.typography.bodySmall)
                                }
                                AnimatedContent(state.mode, label = "Input mode") { mode ->
                                    when (mode) {
                                        InputMode.BUTTONS -> DirectionPad(command)
                                        InputMode.TOUCHPAD -> Touchpad(command)
                                        InputMode.KEYBOARD -> KeyboardPanel(state.keyboardText, updateText, command, {
                                            if (state.haptics) haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                            sendText()
                                        })
                                    }
                                }
                                if (state.mode != InputMode.BUTTONS) UtilityButtons(command)
                                if (state.mode != InputMode.KEYBOARD) {
                                    state.appContext?.let { AppControls(it, command) }
                                    if (state.appContext == null) PlayerShortcuts(command)
                                    state.appContext?.let { context ->
                                        if (context.volumeNotice.isNotEmpty()) Text(context.volumeNotice, color = Amber, style = MaterialTheme.typography.bodySmall)
                                    }
                                    QuickLaunch(command)
                                }
                            }
                            Destination.DEVICES -> DevicesScreen(state, discover, updateInvitation, pair, disconnect, reconnect, forget)
                            Destination.SETTINGS -> SettingsScreen(state, setHaptics, setTestMode)
                        }
                    }
                    if (state.destination != Destination.REMOTE) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Top) {
                        Box(Modifier.padding(top = 5.dp).size(5.dp).background(if (state.testMode) Amber else Muted, CircleShape))
                        Text(state.feedback, color = Muted, style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    }
    if (state.pairingInfo) {
        AlertDialog(
            onDismissRequest = { showPairing(false) },
            icon = { RemoteIcon(Glyph.QR, Modifier.size(32.dp), Amber) },
            title = { Text("A secure connection starts here") },
            text = { Text("Create an invitation in MacTV Settings, paste it into Devices, and approve this phone on the Mac. Invitations expire after two minutes. No camera permission is needed.") },
            confirmButton = { TextButton(onClick = { showPairing(false) }) { Text("Got it") } }
        )
    }
}

@Composable
private fun AppHeader(destination: Destination) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("M A C T V", color = Amber, fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(5.dp))
            Text(when (destination) {
                Destination.REMOTE -> "MacTV Remote"
                Destination.DEVICES -> "Your devices"
                Destination.SETTINGS -> "Settings"
            }, fontSize = 25.sp, lineHeight = 30.sp, fontWeight = FontWeight.SemiBold,
                letterSpacing = (-.8).sp)
        }
        Box(Modifier.padding(start = 12.dp).size(44.dp).border(1.dp, Outline, RoundedCornerShape(14.dp)),
            contentAlignment = Alignment.Center) {
            RemoteIcon(Glyph.REMOTE, Modifier.size(23.dp), Amber)
        }
    }
}

@Composable
private fun ConnectionCard(connection: ConnectionState, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(18.dp), color = Panel,
        border = BorderStroke(1.dp, Outline), modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 13.dp),
            verticalAlignment = Alignment.CenterVertically) {
            RemoteIcon(Glyph.DEVICES, Modifier.size(25.dp), Muted)
            Column(Modifier.weight(1f).padding(horizontal = 13.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.size(6.dp).background(if(connection is ConnectionState.Connected) Color(0xFF7BCCAA) else Color(0xFFBF9680), CircleShape))
                    Text(connection.label(), fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium)
                }
                Text(if(connection is ConnectionState.Connected) connection.device.name else "Manage connection in Devices", fontSize = 11.sp, lineHeight = 16.sp, color = Muted)
            }
            Text(if (connection is ConnectionState.Connected) "Devices" else "Pair", color = Amber, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            RemoteIcon(Glyph.RIGHT, Modifier.size(17.dp), Amber)
        }
    }
}

@Composable
private fun ModeSelector(mode: InputMode, onSelect: (InputMode) -> Unit) {
    val showIcons = LocalDensity.current.fontScale <= 1.2f
    Row(Modifier.fillMaxWidth().background(Panel, RoundedCornerShape(16.dp)).padding(4.dp)) {
        InputMode.entries.forEach { item ->
            val active = item == mode
            val color by animateColorAsState(if (active) Color(0xFF363638) else Color.Transparent, label = "Mode color")
            Row(Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).background(color)
                .semantics { selected = active }
                .clickable(role = Role.Tab) { onSelect(item) }.heightIn(min = 46.dp).padding(6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                if (showIcons) {
                    RemoteIcon(when (item) {
                        InputMode.BUTTONS -> Glyph.REMOTE
                        InputMode.TOUCHPAD -> Glyph.TOUCH
                        InputMode.KEYBOARD -> Glyph.KEYBOARD
                    }, Modifier.size(16.dp), if (active) Amber else Muted)
                    Spacer(Modifier.width(5.dp))
                }
                Text(when (item) {
                    InputMode.BUTTONS -> "Buttons"
                    InputMode.TOUCHPAD -> "Touchpad"
                    InputMode.KEYBOARD -> "Keyboard"
                }, fontSize = 11.sp, maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    color = if (active) Color.White else Muted)
            }
        }
    }
}

@Composable
private fun DirectionPad(send: (RemoteCommand) -> Unit) {
    Box(Modifier.fillMaxWidth().height(264.dp), contentAlignment = Alignment.TopCenter) {
        Box(Modifier.size(248.dp).background(
            Brush.linearGradient(listOf(Color(0xFF35373B), Color(0xFF191A1D))), CircleShape)
            .border(1.dp, Color(0xFF414348), CircleShape).padding(9.dp)
            .border(1.dp, Color(0xFF151619), CircleShape), contentAlignment = Alignment.Center) {
            ControlButton("Up", Glyph.UP, { send(RemoteCommand.Press(RemoteKey.UP)) },
                Modifier.align(Alignment.TopCenter).padding(top = 3.dp).size(62.dp), transparent = true)
            ControlButton("Down", Glyph.DOWN, { send(RemoteCommand.Press(RemoteKey.DOWN)) },
                Modifier.align(Alignment.BottomCenter).padding(bottom = 3.dp).size(62.dp), transparent = true)
            ControlButton("Left", Glyph.LEFT, { send(RemoteCommand.Press(RemoteKey.LEFT)) },
                Modifier.align(Alignment.CenterStart).padding(start = 3.dp).size(62.dp), transparent = true)
            ControlButton("Right", Glyph.RIGHT, { send(RemoteCommand.Press(RemoteKey.RIGHT)) },
                Modifier.align(Alignment.CenterEnd).padding(end = 3.dp).size(62.dp), transparent = true)
            val interaction = remember { MutableInteractionSource() }
            val pressed by interaction.collectIsPressedAsState()
            val scale by animateFloatAsState(if (pressed) .94f else 1f, label = "OK press")
            Box(Modifier.size(104.dp).scale(scale)
                .background(Brush.linearGradient(listOf(Color(0xFFF5D4A5), Color(0xFFCFA270))), CircleShape)
                .border(1.dp, Color(0xFFFFDFB7), CircleShape).clip(CircleShape)
                .clickable(interactionSource = interaction, indication = null, role = Role.Button) {
                    send(RemoteCommand.Press(RemoteKey.OK))
                }, contentAlignment = Alignment.Center) {
                Text("OK", color = Color(0xFF32271B), fontWeight = FontWeight.SemiBold,
                    fontSize = 21.sp, letterSpacing = 1.sp)
            }
        }
        Column(Modifier.align(Alignment.BottomStart), horizontalAlignment = Alignment.CenterHorizontally) {
            ControlButton("Back", Glyph.BACK, { send(RemoteCommand.Press(RemoteKey.BACK)) })
            Text("Back", color = Muted, fontSize = 10.sp, lineHeight = 14.sp)
        }
        Column(Modifier.align(Alignment.BottomEnd), horizontalAlignment = Alignment.CenterHorizontally) {
            ControlButton("Home", Glyph.HOME, { send(RemoteCommand.Press(RemoteKey.HOME)) })
            Text("Home", color = Muted, fontSize = 10.sp, lineHeight = 14.sp)
        }
    }
}

@Composable
private fun ControlButton(
    label: String, glyph: Glyph, onClick: () -> Unit,
    modifier: Modifier = Modifier.size(54.dp), transparent: Boolean = false, accent: Boolean = false
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) .9f else 1f, label = label + " press")
    val background by animateColorAsState(
        if (pressed) Amber.copy(alpha = .22f) else if (transparent) Color.Transparent else Panel,
        label = label + " background")
    Box(modifier.scale(scale).clip(CircleShape).background(background)
        .semantics { contentDescription = label }
        .clickable(interactionSource = source, indication = null, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center) {
        RemoteIcon(glyph, Modifier.size(24.dp), if (accent) Amber else Color(0xFFE5E5E8))
    }
}

@Composable
private fun UtilityButtons(send: (RemoteCommand) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ControlButton("Back", Glyph.BACK, { send(RemoteCommand.Press(RemoteKey.BACK)) })
            Text("Back", fontSize = 12.sp, color = Muted, modifier = Modifier.padding(start = 8.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            ControlButton("Home", Glyph.HOME, { send(RemoteCommand.Press(RemoteKey.HOME)) })
            Text("Home", fontSize = 12.sp, color = Muted, modifier = Modifier.padding(start = 8.dp))
        }
    }
}

@Composable
private fun OpenActiveApp(title: String, send: (RemoteCommand) -> Unit) {
    Button(onClick = { send(RemoteCommand.Press(RemoteKey.ACTIVATE_APP)) },
        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
        shape = RoundedCornerShape(14.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Amber, contentColor = Ink),
        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 14.dp)) {
        RemoteIcon(Glyph.DEVICES, Modifier.size(20.dp), Ink)
        Text("Open $title", modifier = Modifier.weight(1f).padding(horizontal = 12.dp), fontWeight = FontWeight.SemiBold)
        RemoteIcon(Glyph.RIGHT, Modifier.size(18.dp), Ink)
    }
}

@Composable
private fun AppControls(context: com.example.mactv_androidapp.connection.AppContext, send: (RemoteCommand) -> Unit) {
    Surface(color = Panel, shape = RoundedCornerShape(20.dp), border = BorderStroke(1.dp, Outline)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(context.title, color = Amber, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            if (!context.foreground && context.app in setOf("spotify", "youtube", "netflix", "prime", "f1", "football")) {
                OpenActiveApp(context.title, send)
            }
            when (context.app) {
                "spotify" -> {
                    if ("app_search" in context.keys) OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.APP_SEARCH)) }) { Text("Search Spotify") }
                }
                "f1" -> {
                    Text("Choose a session with the touchpad", color = Muted, style = MaterialTheme.typography.bodySmall)
                    OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.FULLSCREEN)) }) { Text("Fullscreen") }
                }
                "football" -> {
                    if ("unmute_stream" in context.keys) OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.UNMUTE_STREAM)) }, modifier = Modifier.fillMaxWidth()) { Text("Unmute stream") }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        if ("refresh" in context.keys) OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.REFRESH)) }, modifier = Modifier.weight(1f)) { Text("Refresh page") }
                        OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.FULLSCREEN)) }, modifier = Modifier.weight(1f)) { Text("Fullscreen") }
                    }
                    if ("close_tab" in context.keys) OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.CLOSE_TAB)) }, modifier = Modifier.fillMaxWidth()) { Text("Close current tab") }
                    Text("Close current tab dismisses the active Chrome tab, including an ad tab. Volume buttons control your Mac.", color = Muted, style = MaterialTheme.typography.bodySmall)
                }
                "player", "youtube", "netflix", "prime" -> {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (context.app == "player") OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.CONTROLS)) }, modifier = Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 12.dp)) { Text("Controls", maxLines = 1, fontSize = 12.sp) }
                        OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.FULLSCREEN)) }, modifier = Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 12.dp)) { Text("Fullscreen", maxLines = 1, fontSize = 12.sp) }
                        if ("subtitles" in context.keys) OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.SUBTITLES)) }, modifier = Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 12.dp)) { Text("Subtitles", maxLines = 1, fontSize = 12.sp) }
                    }
                    if (context.app == "player") {
                        Text("Subtitles: ${context.subtitle.ifEmpty { "Off" }}", color = Muted, style = MaterialTheme.typography.bodySmall)
                        TextButton(onClick = { send(RemoteCommand.Press(RemoteKey.RESTART)) }) { Text("Start over") }
                    }
                }
                else -> Text("Choose a title or streaming app on your Mac", color = Muted, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun PlayerShortcuts(send: (RemoteCommand) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.CONTROLS)) }, modifier = Modifier.weight(1f)) { Text("Player controls") }
        OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.FULLSCREEN)) }, modifier = Modifier.weight(1f)) { Text("Fullscreen") }
    }
}

@Composable
private fun PlaybackControls(send: (RemoteCommand) -> Unit, app: String? = null, volumeAvailable: Boolean = true) {
    val sports = app in setOf("f1", "football")
    val musicControls = app == null || app in setOf("spotify", "home", "library", "settings")
    Surface(color = Panel, shape = RoundedCornerShape(24.dp),
        border = BorderStroke(1.dp, Outline)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 5.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically) {
                if (!sports) ControlButton(if (musicControls) "Previous track" else "Back 10 seconds", Glyph.PREVIOUS, { send(RemoteCommand.Press(if (musicControls) RemoteKey.PREVIOUS else RemoteKey.SEEK_BACK)) }, transparent = true)
                ControlButton("Play or pause", Glyph.PLAY, { send(RemoteCommand.Press(RemoteKey.PLAY_PAUSE)) },
                    Modifier.size(58.dp), accent = true)
                if (!sports) ControlButton(if (musicControls) "Next track" else "Forward 10 seconds", Glyph.NEXT, { send(RemoteCommand.Press(if (musicControls) RemoteKey.NEXT else RemoteKey.SEEK_FORWARD)) }, transparent = true)
            }
            HorizontalDivider(color = Outline, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                ControlButton("Mute", Glyph.MUTE, { send(RemoteCommand.Press(RemoteKey.MUTE)) }, transparent = true)
                Spacer(Modifier.weight(1f))
                ControlButton("Volume down", Glyph.MINUS, { send(RemoteCommand.Press(RemoteKey.VOLUME_DOWN)) }, transparent = true)
                Text(if (volumeAvailable) "MAC VOLUME" else "OUTPUT VOLUME", fontSize = 9.sp, letterSpacing = 1.5.sp, color = Muted,
                    modifier = Modifier.padding(horizontal = 8.dp))
                ControlButton("Volume up", Glyph.PLUS, { send(RemoteCommand.Press(RemoteKey.VOLUME_UP)) }, transparent = true)
            }
        }
    }
}

@Composable
private fun QuickLaunch(send: (RemoteCommand) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("STRAIGHT TO YOUR FAVORITES", color = Muted, fontSize = 9.sp, lineHeight = 13.sp,
            letterSpacing = 1.7.sp, fontWeight = FontWeight.Medium)
        LaunchApp.entries.filter { it != LaunchApp.MOVIES }.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { app ->
                    val color = when (app) {
                        LaunchApp.NETFLIX -> Color(0xFFFF5263)
                        LaunchApp.SPOTIFY -> Color(0xFF7DDD9D)
                        LaunchApp.YOUTUBE -> Color(0xFFFF7777)
                        LaunchApp.PRIME_VIDEO -> Color(0xFF81C7F4)
                        LaunchApp.F1 -> Color(0xFFFF6868)
                        LaunchApp.FOOTBALL -> Color(0xFF8ADBA0)
                        LaunchApp.MOVIES -> Amber
                    }
                    Surface(onClick = { send(RemoteCommand.Launch(app)) },
                        modifier = Modifier.weight(1f).heightIn(min = 54.dp).semantics { contentDescription = "Launch " + app.title },
                        shape = RoundedCornerShape(15.dp), color = color.copy(alpha = .075f), border = BorderStroke(1.dp, color.copy(alpha = .16f))) {
                        Box(Modifier.padding(horizontal = 8.dp, vertical = 14.dp), contentAlignment = Alignment.Center) {
                            Text(app.title, color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
        OutlinedButton(onClick = { send(RemoteCommand.Launch(LaunchApp.MOVIES)) }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Launch Movies" }) {
            Text("Movies & Series")
        }
    }
}

@Composable
private fun Touchpad(send: (RemoteCommand) -> Unit) {
    val latestSend by rememberUpdatedState(send)
    val density = LocalDensity.current.density
    var dragging by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth().height(260.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(28.dp))
                .background(Brush.linearGradient(listOf(Color(0xFF2C2D31), Panel)))
                .border(1.dp, if (dragging) Amber else Outline, RoundedCornerShape(28.dp))
                .semantics { contentDescription = "Touchpad. Swipe to move, tap to click." }
                .pointerInput(Unit) { detectTapGestures(onTap = { latestSend(RemoteCommand.Press(RemoteKey.CLICK)) }) }
                .pointerInput(density) {
                    detectDragGestures(
                        onDragStart = { dragging = true },
                        onDragEnd = { dragging = false }, onDragCancel = { dragging = false }
                    ) { change, amount ->
                        change.consume()
                        latestSend(RemoteCommand.MovePointer(amount.x / density, amount.y / density))
                    }
                }, contentAlignment = Alignment.Center) {
                Canvas(Modifier.fillMaxSize().padding(22.dp)) {
                    val spacing = 18.dp.toPx()
                    for (x in 0..(size.width / spacing).toInt())
                        for (y in 0..(size.height / spacing).toInt())
                            drawCircle(Color.White.copy(alpha = .09f), 1.dp.toPx(), Offset(x * spacing, y * spacing))
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    RemoteIcon(Glyph.TOUCH, Modifier.size(30.dp), Amber)
                    Spacer(Modifier.height(12.dp))
                    Text(if (dragging) "Moving" else "Room to move.", fontSize = 18.sp, fontWeight = FontWeight.Medium)
                    Text("Swipe to navigate · Tap to select", color = Muted, fontSize = 11.sp,
                        modifier = Modifier.padding(top = 6.dp))
                }
            }
            Box(Modifier.width(52.dp).fillMaxHeight().clip(RoundedCornerShape(22.dp))
                .background(Panel).border(1.dp, Outline, RoundedCornerShape(22.dp))
                .semantics { contentDescription = "Scroll strip. Swipe up or down to scroll." }
                .pointerInput(density) {
                    detectDragGestures { change, amount ->
                        change.consume()
                        latestSend(RemoteCommand.Scroll(amount.y / density))
                    }
                }, contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(35.dp)) {
                    RemoteIcon(Glyph.UP, Modifier.size(18.dp), Muted)
                    Text("SCROLL", fontSize = 8.sp, color = Muted)
                    RemoteIcon(Glyph.DOWN, Modifier.size(18.dp), Muted)
                }
            }
        }
    }
}

@Composable
private fun KeyboardPanel(text: String, onText: (String) -> Unit, send: (RemoteCommand) -> Unit, onSend: () -> Unit) {
    Surface(shape = RoundedCornerShape(24.dp), color = Panel, border = BorderStroke(1.dp, Outline)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("Keyboard", fontSize = 20.sp, fontWeight = FontWeight.Medium)
            Text("Type here, then send to the selected Mac field.", color = Muted, fontSize = 13.sp)
            OutlinedTextField(value = text, onValueChange = onText,
                modifier = Modifier.fillMaxWidth(), label = { Text("Text for your Mac") },
                placeholder = { Text("What do you want to watch?") }, singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                shape = RoundedCornerShape(14.dp), supportingText = { Text("${text.length} / 2000") })
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { onText("") }, enabled = text.isNotEmpty()) { Text("Clear draft") }
                Spacer(Modifier.width(8.dp))
                Button(onClick = onSend, enabled = text.isNotBlank()) {
                    RemoteIcon(Glyph.SEND, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Send text")
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.BACKSPACE)) }, modifier = Modifier.weight(1f)) { Text("Backspace") }
                OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.OK)) }, modifier = Modifier.weight(1f)) { Text("Enter") }
            }
            OutlinedButton(onClick = { send(RemoteCommand.Press(RemoteKey.ERASE_FIELD)); onText("") }, modifier = Modifier.fillMaxWidth()) { Text("Erase Mac field") }
            Text("Text is sent only while connected. Focus the destination field on the Mac first.", color = Muted, fontSize = 11.sp)
        }
    }
}

private fun ConnectionState.label(): String = when(this) {
    ConnectionState.Disconnected -> "Disconnected"
    ConnectionState.Connecting -> "Connecting…"
    ConnectionState.AwaitingApproval -> "Approve on your Mac"
    is ConnectionState.Reconnecting -> "Reconnecting · attempt $attempt"
    is ConnectionState.Connected -> "Connected · authenticated"
    is ConnectionState.Error -> message
}

@Composable
private fun DevicesScreen(state: RemoteUiState, discover: () -> Unit, updateInvitation: (String) -> Unit,
                          pair: () -> Unit, disconnect: () -> Unit, reconnect: () -> Unit, forget: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Surface(color = Panel, shape = RoundedCornerShape(28.dp), border = BorderStroke(1.dp, Outline)) {
            Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("Meet your Mac.", fontSize = 27.sp, fontWeight = FontWeight.SemiBold)
                Text("On MacTV, open Settings and create an invitation. Paste it here within 2 minutes, then approve this phone on your Mac. Keep invitations private.", color = Muted)
                OutlinedTextField(value = state.invitationText, onValueChange = updateInvitation,
                    label = { Text("MacTV invitation") }, modifier = Modifier.fillMaxWidth(), maxLines = 3)
                Button(onClick = pair, enabled = state.invitationText.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Pair with Mac") }
                OutlinedButton(onClick = discover, modifier = Modifier.fillMaxWidth()) { Text("Find Macs on Wi-Fi") }
                if(state.devices.isEmpty()) Text("No discovered Macs. An invitation also connects directly.", color = Muted)
                state.devices.forEach { device ->
                    Text("${device.name} · ${device.endpoint}", color = Amber, style = MaterialTheme.typography.bodySmall)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = reconnect) { Text("Reconnect") }
                    TextButton(onClick = disconnect) { Text("Disconnect") }
                    TextButton(onClick = forget) { Text("Forget") }
                }
            }
        }
        InfoRow("01", "Same Wi-Fi", "Keep both apps open on the same network. Guest networks may block discovery or connections.")
        InfoRow("02", "Approved and encrypted", "The invitation authenticates your Mac. Approve your phone on the Mac. Credentials are protected by the device key stores.")
        InfoRow("03", "Your media stays on your Mac", "This remote sends controls. It does not stream or bypass provider playback restrictions.")
    }
}

@Composable
private fun SettingsScreen(state: RemoteUiState, setHaptics: (Boolean) -> Unit, setTestMode: (Boolean) -> Unit) {
    val context = LocalContext.current
    val appVersion = remember(context) {
        runCatching { context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0)).versionName }.getOrNull() ?: "—"
    }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        SectionLabel("THE FEEL")
        SettingToggle("Haptic feedback", "A subtle response with every press.", state.haptics, setHaptics)
        SectionLabel("DEVELOPMENT")
        SettingToggle("Local test", "Record commands on this phone. No Mac required.", state.testMode, setTestMode)
        Surface(shape = RoundedCornerShape(20.dp), color = Panel) {
            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                Text("Command activity", fontWeight = FontWeight.Medium)
                Text("${state.commandCount} commands processed", color = Amber, fontSize = 14.sp)
                Text("Local test keeps at most 64 commands in memory with text redacted. Normal mode reports Mac acknowledgements.",
                    color = Muted, style = MaterialTheme.typography.bodySmall)
            }
        }
        SectionLabel("ABOUT")
        InfoRow("M", "MacTV Remote", "Version $appVersion · Protocol v1\nCrafted for your Mac. Controlled from your couch.")
        InfoRow("↗", "Local Wi-Fi remote", "Encrypted WebSocket controls, Mac approval, discovery, and reconnection. Use Devices to pair.")
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, color = Muted, fontSize = 10.sp, letterSpacing = 1.8.sp)
}

@Composable
private fun SettingToggle(title: String, subtitle: String, checked: Boolean, onChecked: (Boolean) -> Unit) {
    Surface(shape = RoundedCornerShape(20.dp), color = Panel, border = BorderStroke(1.dp, Outline)) {
        Row(Modifier.fillMaxWidth().padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).padding(end = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, fontWeight = FontWeight.Medium)
                Text(subtitle, color = Muted, style = MaterialTheme.typography.bodySmall)
            }
            Switch(checked = checked, onCheckedChange = onChecked, modifier = Modifier.semantics { contentDescription = title })
        }
    }
}

@Composable
private fun InfoRow(mark: String, title: String, detail: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(38.dp).background(Panel, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center) {
            Text(mark, color = Amber, fontSize = 12.sp)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(detail, color = Muted, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Preview(name = "Galaxy S25 Ultra • Remote", widthDp = 412, heightDp = 915, showBackground = true)
@Composable
fun RemotePreview() { MacTV_AndroidAppTheme { RemoteAppContent(RemoteUiState()) } }

@Preview(name = "Touchpad", widthDp = 412, heightDp = 915, showBackground = true)
@Composable
fun TouchpadPreview() { MacTV_AndroidAppTheme { RemoteAppContent(RemoteUiState(mode = InputMode.TOUCHPAD)) } }

@Preview(name = "Keyboard", widthDp = 412, heightDp = 915, showBackground = true)
@Composable
fun KeyboardPreview() { MacTV_AndroidAppTheme { RemoteAppContent(RemoteUiState(mode = InputMode.KEYBOARD)) } }

@Preview(name = "Devices", widthDp = 412, heightDp = 915, showBackground = true)
@Composable
fun DevicesPreview() { MacTV_AndroidAppTheme { RemoteAppContent(RemoteUiState(destination = Destination.DEVICES)) } }

@Preview(name = "Settings", widthDp = 412, heightDp = 915, showBackground = true)
@Composable
fun SettingsPreview() { MacTV_AndroidAppTheme { RemoteAppContent(RemoteUiState(destination = Destination.SETTINGS)) } }

@Preview(name = "Large text", widthDp = 360, heightDp = 800, fontScale = 1.5f, showBackground = true)
@Composable
fun LargeTextPreview() { MacTV_AndroidAppTheme { RemoteAppContent(RemoteUiState()) } }
