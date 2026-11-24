package com.droidscreen.receiver.ui

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.droidscreen.receiver.input.TouchInputHandler
import com.droidscreen.receiver.input.TouchMode
import com.droidscreen.receiver.protocol.Wire
import com.droidscreen.receiver.session.StreamController
import com.droidscreen.receiver.session.StreamViewModel

@Composable
fun DroidScreenApp(vm: StreamViewModel) {
    if (vm.active) StreamScreen(vm) else ConnectScreen(vm)
}

@Composable
fun ConnectScreen(vm: StreamViewModel) {
    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.safeDrawingPadding().padding(24.dp).verticalScroll(rememberScrollState()).widthIn(max = 560.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("DroidScreen", style = MaterialTheme.typography.headlineMedium)
            Text("Use this device as an extended display for your Mac.", style = MaterialTheme.typography.bodyMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = vm.autoConnect, onCheckedChange = { vm.autoConnect = it })
                Text("  Connect automatically (find the Mac on Wi-Fi or USB)")
            }
            val found by vm.discovery.hosts.collectAsState()
            if (found.isNotEmpty()) {
                Text("Macs on this network", style = MaterialTheme.typography.titleSmall)
                found.forEach { mac ->
                    OutlinedButton(onClick = { vm.port = mac.port.toString(); vm.connectTo(mac.host) }, modifier = Modifier.fillMaxWidth()) {
                        Text("${mac.name}  (${mac.host}:${mac.port})")
                    }
                }
            }
            OutlinedTextField(
                value = vm.host, onValueChange = { vm.host = it }, enabled = !vm.autoConnect,
                label = { Text("Mac address") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
            OutlinedTextField(
                value = vm.port, onValueChange = { vm.port = it.filter(Char::isDigit).take(5) },
                label = { Text("Port") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
            OutlinedTextField(
                value = vm.inputToken, onValueChange = { vm.inputToken = it.trim() },
                label = { Text("Touch input code (optional, shown on the Mac)") }, singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Touch mode")
                FilterChip(selected = vm.touchMode == TouchMode.DIRECT, onClick = { vm.touchMode = TouchMode.DIRECT }, label = { Text("Direct") })
                FilterChip(selected = vm.touchMode == TouchMode.TRACKPAD, onClick = { vm.touchMode = TouchMode.TRACKPAD }, label = { Text("Trackpad") })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = vm.showStats, onCheckedChange = { vm.showStats = it })
                Text("  Show stream statistics while streaming")
            }
            Button(onClick = vm::connect, enabled = (vm.autoConnect || vm.host.isNotBlank()) && vm.port.isNotBlank()) { Text("Connect") }
            Text(
                "USB: enable USB debugging, connect the cable, start streaming on the Mac and click “Set up USB”. Use 127.0.0.1.\n" +
                    "Emulator: use 10.0.2.2.\n" +
                    "Touch: Direct = tap to click, drag to drag, long-press = right click, two fingers = scroll. " +
                    "Trackpad = drag moves the pointer. Over USB the Mac sends the input code automatically.\n" +
                    "Wi-Fi: enable LAN connections on the Mac. Macs on the same network are listed above; or enter the IP address. Default port ${Wire.DEFAULT_PORT}.\n" +
                    "Connect automatically: the app connects on start to a Mac found on the network, or over USB.",
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
fun StreamScreen(vm: StreamViewModel) {
    val state by vm.controller.state.collectAsState()
    val stats by vm.controller.stats.collectAsState()
    val video by vm.controller.video.collectAsState()
    ImmersiveMode()
    BackHandler(onBack = vm::disconnect)

    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        val ratio = video?.let { it.width.toFloat() / it.height } ?: (16f / 9f)
        AndroidView(
            factory = { context ->
                SurfaceView(context).apply {
                    setOnTouchListener(TouchInputHandler(context, { vm.touchMode }) { bytes -> vm.controller.sendInput(bytes) })
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) = vm.controller.attachSurface(holder.surface)
                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                        override fun surfaceDestroyed(holder: SurfaceHolder) = vm.controller.detachSurface()
                    })
                }
            },
            modifier = Modifier.aspectRatio(ratio),
        )

        val status = when (val s = state) {
            is StreamController.State.Idle -> "Disconnected"
            is StreamController.State.Connecting ->
                if (s.attempt == 0) "Connecting to ${s.host}:${s.port}…"
                else "Reconnecting to ${s.host}:${s.port} (attempt ${s.attempt})…" + (s.lastError?.let { "\n$it" } ?: "")
            is StreamController.State.Searching ->
                "Searching for your Mac on Wi-Fi and USB…" + (s.lastError?.let { "\n$it" } ?: "")
            is StreamController.State.Streaming -> null
        }
        if (status != null) {
            Text(status, color = Color.White, modifier = Modifier.padding(24.dp))
        }

        val streaming = state as? StreamController.State.Streaming
        if (vm.showStats && streaming != null) {
            Text(
                "${streaming.video.codec.uppercase()} ${streaming.video.width}×${streaming.video.height} · " +
                    "${stats.renderedFps} fps (${stats.skippedFps} skipped) · ${"%.1f".format(stats.receivedKbps / 1000f)} Mbps · " +
                    "${stats.decoderName}${if (stats.hardwareDecoder) " (HW)" else ""} · " +
                    if (streaming.inputEnabled) "touch: ${vm.touchMode.name.lowercase()}" else "view-only",
                color = Color.White, fontSize = 11.sp, fontFamily = FontFamily.Monospace,
                modifier = Modifier.align(Alignment.TopStart).background(Color(0x99000000)).padding(6.dp),
            )
        }
    }
}

/** Full-screen, screen-on, landscape while the stream screen is shown; restored afterwards. */
@Composable
private fun ImmersiveMode() {
    val view = LocalView.current
    val activity = LocalContext.current as Activity
    DisposableEffect(Unit) {
        val window = activity.window
        val insets = WindowCompat.getInsetsController(window, view)
        insets.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        insets.hide(WindowInsetsCompat.Type.systemBars())
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val previousCutout = window.attributes.layoutInDisplayCutoutMode
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        val previousOrientation = activity.requestedOrientation
        activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        onDispose {
            insets.show(WindowInsetsCompat.Type.systemBars())
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = previousCutout }
            activity.requestedOrientation = previousOrientation
        }
    }
}
