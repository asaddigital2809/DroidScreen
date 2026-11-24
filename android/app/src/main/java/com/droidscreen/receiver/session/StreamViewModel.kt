package com.droidscreen.receiver.session

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.view.KeyEvent
import android.view.WindowManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import com.droidscreen.receiver.decoder.VideoDecoder
import com.droidscreen.receiver.discovery.MacDiscovery
import com.droidscreen.receiver.input.TouchMode
import com.droidscreen.receiver.protocol.InputWire
import com.droidscreen.receiver.protocol.ClientHello
import com.droidscreen.receiver.protocol.Wire

/**
 * UI state for the receiver. Survives configuration changes. The connection runs only while
 * the activity is started (see [onForeground] / [onBackground]).
 */
class StreamViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("droidscreen", Context.MODE_PRIVATE)

    var host by mutableStateOf(prefs.getString(KEY_HOST, "127.0.0.1") ?: "127.0.0.1")
    var port by mutableStateOf(prefs.getInt(KEY_PORT, Wire.DEFAULT_PORT).toString())
    var showStats by mutableStateOf(prefs.getBoolean(KEY_STATS, true))
    var touchMode by mutableStateOf(runCatching { TouchMode.valueOf(prefs.getString(KEY_TOUCH, null) ?: "") }.getOrDefault(TouchMode.DIRECT))
    /**
     * Input code from the Mac. Delivered over adb for USB; typed for Wi-Fi. Saved when connecting
     * (the Mac keeps the same code across launches), so later Wi-Fi connections keep touch input.
     */
    var inputToken by mutableStateOf(prefs.getString(KEY_TOKEN, "") ?: "")
    /**
     * "Connect automatically": on app start, connect without pressing Connect, trying every Mac
     * found on the network (DNS-SD) and then 127.0.0.1 (USB via adb reverse).
     */
    var autoConnect by mutableStateOf(prefs.getBoolean(KEY_AUTO, false))
    /** True while the current connection uses the automatic candidate list. */
    var autoMode by mutableStateOf(false)
        private set
    val discovery = MacDiscovery(app)
    /** True while the user wants to be connected (streaming screen visible). */
    var active by mutableStateOf(false)
        private set
    private var foreground = false

    private val clientId: String = prefs.getString(KEY_CLIENT_ID, null)
        ?: java.util.UUID.randomUUID().toString().also { prefs.edit().putString(KEY_CLIENT_ID, it).apply() }

    val controller = StreamController { takeOver -> clientHello(app, inputToken.trim().ifEmpty { null }, clientId, takeOver) }
    /** The next connection start asks the Mac to switch to this device (see [ClientHello.takeOver]). */
    private var userInitiated = false
    private var startedOnce = false

    /** Connect button: automatic mode when [autoConnect] is on, otherwise the typed address. */
    fun connect() = if (autoConnect) connectAuto() else connectTo(host)

    /**
     * Connects to one fixed address (typed, picked from the discovered list, or sent over adb).
     * `takeOver` = true when the user asked for it: the Mac then switches from another device to this one.
     */
    fun connectTo(address: String, takeOver: Boolean = true) {
        host = address.trim()
        port.toIntOrNull()?.takeIf { it in 1..65535 } ?: return
        save()
        autoMode = false
        active = true
        userInitiated = takeOver
        startConnection()
    }

    fun connectAuto(takeOver: Boolean = true) {
        port.toIntOrNull()?.takeIf { it in 1..65535 } ?: return
        save()
        autoMode = true
        active = true
        userInitiated = takeOver
        startConnection()
    }

    fun disconnect() {
        active = false
        controller.stop()
    }

    /**
     * Returning to the app counts as a user request: it may take the stream from another device.
     * The first start after launch keeps the choice made by [onLaunch] / [applyIntent].
     */
    fun onForeground() {
        foreground = true
        discovery.start()
        if (startedOnce) userInitiated = true
        startedOnce = true
        startConnection()
    }

    fun onBackground() {
        foreground = false
        discovery.stop()
        if (active) controller.stop()
    }

    private fun startConnection() {
        if (!active || !foreground) return
        val p = port.toIntOrNull() ?: return
        val takeOver = userInitiated
        userInitiated = false
        if (autoMode) controller.startAuto(takeOver) { autoCandidates(p) } else controller.start(host.trim(), p, takeOver)
    }

    /** Macs found on the network first, then USB (127.0.0.1 through adb reverse). */
    private fun autoCandidates(usbPort: Int): List<Pair<String, Int>> =
        (discovery.hosts.value.map { it.host to it.port } + (USB_HOST to usbPort)).distinct()

    private fun save() {
        prefs.edit().putString(KEY_HOST, host.trim()).putInt(KEY_PORT, port.toIntOrNull() ?: Wire.DEFAULT_PORT)
            .putBoolean(KEY_STATS, showStats).putString(KEY_TOUCH, touchMode.name)
            .putString(KEY_TOKEN, inputToken.trim()).putBoolean(KEY_AUTO, autoConnect).apply()
    }

    /** Called once when the activity is first created. Starts auto mode if enabled and the intent did not connect. */
    fun onLaunch(intent: Intent?) {
        applyIntent(intent)
        if (!active && autoConnect) connectAuto()
    }

    /**
     * `adb shell am start -n com.droidscreen.receiver/.MainActivity --es host 10.0.2.2 --ei port 47800 --ez autoConnect true`
     */
    fun applyIntent(intent: Intent?) {
        intent ?: return
        intent.getStringExtra("host")?.let { host = it }
        if (intent.hasExtra("port")) port = intent.getIntExtra("port", Wire.DEFAULT_PORT).toString()
        if (intent.hasExtra("showStats")) showStats = intent.getBooleanExtra("showStats", true)
        intent.getStringExtra("inputToken")?.let { inputToken = it }
        intent.getStringExtra("touchMode")?.let { m -> runCatching { touchMode = TouchMode.valueOf(m.uppercase()) } }
        if (intent.getBooleanExtra("autoConnect", false)) connectTo(host, takeOver = intent.getBooleanExtra("takeOver", false))
    }

    /**
     * Forwards hardware-keyboard events to the Mac. System keys (back, home, volume, power)
     * stay with Android. Returns true when the event was consumed.
     */
    fun onKeyEvent(event: KeyEvent): Boolean {
        if (!active || event.isSystem) return false
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false
        // Character without Ctrl/Meta, so Cmd+C still carries 'c'.
        val unicode = event.getUnicodeChar(event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_META_MASK).inv())
        return controller.sendInput(InputWire.key(event.action == KeyEvent.ACTION_DOWN, event.keyCode, event.metaState, unicode))
    }

    override fun onCleared() {
        discovery.stop()
        controller.close()
    }

    companion object {
        private const val KEY_HOST = "host"
        private const val KEY_PORT = "port"
        private const val KEY_STATS = "showStats"
        private const val KEY_TOUCH = "touchMode"
        private const val KEY_CLIENT_ID = "clientId"
        private const val KEY_TOKEN = "inputToken"
        private const val KEY_AUTO = "autoConnect"
        const val USB_HOST = "127.0.0.1"

        fun clientHello(context: Context, inputToken: String?, clientId: String?, takeOver: Boolean = false): ClientHello {
            val wm = context.getSystemService(WindowManager::class.java)
            val (w, h) = if (Build.VERSION.SDK_INT >= 30) {
                val b = wm.maximumWindowMetrics.bounds
                b.width() to b.height()
            } else {
                val m = context.resources.displayMetrics
                m.widthPixels to m.heightPixels
            }
            return ClientHello(
                protocolVersion = Wire.VERSION,
                deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
                screenWidth = w,
                screenHeight = h,
                densityDpi = context.resources.displayMetrics.densityDpi,
                codecs = VideoDecoder.supportedCodecs(),
                inputToken = inputToken,
                clientId = clientId,
                decoderMaxSize = VideoDecoder.supportedCodecs().mapNotNull { codec ->
                    VideoDecoder.maxDecodeSize(codec, maxOf(w, h), minOf(w, h))?.let { codec to it }
                }.toMap(),
                takeOver = takeOver,
            )
        }
    }
}
