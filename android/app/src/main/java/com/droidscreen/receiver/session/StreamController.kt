package com.droidscreen.receiver.session

import android.util.Log
import android.view.Surface
import com.droidscreen.receiver.decoder.VideoDecoder
import com.droidscreen.receiver.protocol.BufferPool
import com.droidscreen.receiver.protocol.ClientHello
import com.droidscreen.receiver.protocol.HostHello
import com.droidscreen.receiver.protocol.MessageReader
import com.droidscreen.receiver.protocol.VideoConfig
import com.droidscreen.receiver.protocol.Wire
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.BufferedOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the TCP connection to the Mac host and the decoder.
 *
 * - Connects, sends the client hello, then reads messages until the socket fails.
 * - Reconnects automatically with back-off (300 ms … 3 s) until [stop] is called.
 * - [startAuto] takes a list of candidate hosts that is re-read before every attempt
 *   (discovered Macs on the LAN, then 127.0.0.1 for USB). A failed attempt moves to the next
 *   candidate; a candidate that streamed for 5 s or more is tried first again.
 * - A 5 s read timeout detects dead links (the host pings every second), e.g. a pulled USB cable.
 * - The decoder exists only while a Surface is attached; frames arriving without one are dropped
 *   and a keyframe is requested when the Surface appears.
 */
class StreamController(private val helloProvider: (takeOver: Boolean) -> ClientHello) {

    sealed interface State {
        data object Idle : State
        data class Connecting(val host: String, val port: Int, val attempt: Int, val lastError: String?) : State
        /** Auto mode with no candidate host yet (no Mac found on the network). */
        data class Searching(val attempt: Int, val lastError: String?) : State
        data class Streaming(val displayName: String, val video: VideoConfig, val inputEnabled: Boolean) : State
    }

    data class Stats(
        val renderedFps: Int = 0,
        val skippedFps: Int = 0,
        val receivedKbps: Int = 0,
        val decoderName: String = "",
        val hardwareDecoder: Boolean = false,
        val keyframeRequests: Int = 0,
        val sessions: Int = 0,
    )

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()
    private val _stats = MutableStateFlow(Stats())
    val stats: StateFlow<Stats> = _stats.asStateFlow()
    private val _video = MutableStateFlow<VideoConfig?>(null)
    val video: StateFlow<VideoConfig?> = _video.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    /** Identifies the running loop: "host:port" for a fixed target, "auto" for [startAuto]. */
    private var target: String? = null
    private val pool = BufferPool()
    private val lock = Any()
    private var decoder: VideoDecoder? = null
    @Volatile private var connection: Connection? = null
    /**
     * Set by a user-started connection ([start]/[startAuto] with takeOver = true). Hellos carry
     * `takeOver` until a session reaches streaming, then it is cleared, so automatic retries
     * never take the stream from another device.
     */
    @Volatile private var takeOverPending = false
    /** elapsedRealtime when the current session received the host hello; 0 = not streaming. */
    @Volatile private var streamingSince = 0L

    private val rendered = AtomicInteger()
    private val skipped = AtomicInteger()
    private val receivedBytes = AtomicLong()

    init {
        scope.launch {
            while (isActive) {
                delay(1000)
                _stats.value = _stats.value.copy(
                    renderedFps = rendered.getAndSet(0),
                    skippedFps = skipped.getAndSet(0),
                    receivedKbps = (receivedBytes.getAndSet(0) * 8 / 1000).toInt(),
                )
            }
        }
    }

    /** Starts (or keeps) a connection loop to host:port. Idempotent for the same target. */
    @Synchronized
    fun start(host: String, port: Int, takeOver: Boolean = false) = launchLoop("$host:$port", takeOver) { listOf(host to port) }

    /** Auto mode: tries each candidate from [candidates] in turn. Idempotent while running. */
    @Synchronized
    fun startAuto(takeOver: Boolean = false, candidates: () -> List<Pair<String, Int>>) = launchLoop(AUTO, takeOver, candidates)

    private fun launchLoop(key: String, takeOver: Boolean, candidates: () -> List<Pair<String, Int>>) {
        if (job?.isActive == true && target == key) {
            // Already looping (e.g. rejected as busy): a user request retries now with takeOver.
            if (takeOver) {
                takeOverPending = true
                if (_state.value !is State.Streaming) connection?.close()
            }
            return
        }
        stopInternal()
        takeOverPending = takeOver
        target = key
        job = scope.launch { connectLoop(candidates) }
    }

    @Synchronized
    fun stop() {
        stopInternal()
        _state.value = State.Idle
    }

    private fun stopInternal() {
        takeOverPending = false
        job?.cancel()
        job = null
        target = null
        connection?.close()
        connection = null
    }

    fun close() {
        stop()
        detachSurface()
        scope.cancel()
    }

    fun attachSurface(surface: Surface) {
        synchronized(lock) {
            decoder?.release()
            decoder = VideoDecoder(surface, decoderListener, pool).also { d -> _video.value?.let(d::configure) }
        }
        connection?.send(Wire.message(Wire.KEYFRAME_REQUEST))
    }

    /** Sends an input message if the host accepted this client's input token. */
    fun sendInput(bytes: ByteArray): Boolean {
        val streaming = _state.value as? State.Streaming ?: return false
        if (!streaming.inputEnabled) return false
        connection?.send(bytes) ?: return false
        return true
    }

    fun detachSurface() {
        val old = synchronized(lock) { decoder.also { decoder = null } }
        old?.release()
    }

    private suspend fun connectLoop(candidates: () -> List<Pair<String, Int>>) {
        var attempt = 0
        var lastError: String? = null
        var index = 0
        var preferred: Pair<String, Int>? = null
        while (scope.isActive && job?.isCancelled != true) {
            val list = candidates()
            if (list.isEmpty()) {
                _state.value = State.Searching(attempt, lastError)
                delay(1000)
                continue
            }
            val (host, port) = preferred?.takeIf { it in list } ?: list[index % list.size]
            _state.value = State.Connecting(host, port, attempt, lastError)
            streamingSince = 0L
            try {
                runSession(host, port)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lastError = e.message ?: e.javaClass.simpleName
                Log.i(TAG, "session ended: $lastError")
            } finally {
                connection?.close()
                connection = null
            }
            // Only a session that streamed for a while resets the back-off; one that drops right
            // after the hello (e.g. host-side failure) keeps backing off instead of hammering the host.
            val streamedFor = if (streamingSince > 0) android.os.SystemClock.elapsedRealtime() - streamingSince else 0L
            if (streamedFor >= 5000) {
                preferred = host to port
                attempt = 1
            } else {
                if (preferred == host to port) preferred = null
                index++
                attempt++
            }
            delay(minOf(3000L, 300L * attempt))
        }
    }

    /** Blocking; returns only by exception (socket closed, timeout, protocol error). */
    private fun runSession(host: String, port: Int) {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(host, port), 3000)
        socket.soTimeout = 5000
        val conn = Connection(socket)
        connection = conn
        conn.send(Wire.clientHello(helloProvider(takeOverPending)))
        val reader = MessageReader(socket.getInputStream(), pool)

        while (true) {
            val message = reader.read()
            receivedBytes.addAndGet((message.length + Wire.HEADER_SIZE).toLong())
            when (message.type) {
                Wire.VIDEO_FRAME -> {
                    val d = synchronized(lock) { decoder }
                    if (d == null || message.length < Wire.VIDEO_FRAME_HEADER_SIZE) {
                        pool.recycle(message.buffer)
                        continue
                    }
                    val keyframe = (message.buffer[0].toInt() and 1) != 0
                    val pts = Wire.readU64(message.buffer, 1)
                    d.submit(VideoDecoder.Frame(message.buffer, Wire.VIDEO_FRAME_HEADER_SIZE, message.length - Wire.VIDEO_FRAME_HEADER_SIZE, pts, keyframe))
                }
                Wire.PING -> {
                    conn.send(Wire.message(Wire.PONG, message.buffer, 8))
                    pool.recycle(message.buffer)
                }
                Wire.HOST_HELLO -> {
                    val hello = HostHello.parse(message)
                    pool.recycle(message.buffer)
                    if (hello.protocolVersion != Wire.VERSION) throw IOException("host protocol ${hello.protocolVersion}, app protocol ${Wire.VERSION}")
                    applyConfig(hello.video)
                    streamingSince = android.os.SystemClock.elapsedRealtime()
                    takeOverPending = false
                    _stats.value = _stats.value.copy(sessions = _stats.value.sessions + 1)
                    _state.value = State.Streaming(hello.displayName, hello.video, hello.inputEnabled)
                }
                Wire.HOST_BUSY -> {
                    val reason = message.text()
                    pool.recycle(message.buffer)
                    throw IOException("Mac is busy: $reason")
                }
                Wire.VIDEO_CONFIG -> {
                    val config = VideoConfig.parse(message)
                    pool.recycle(message.buffer)
                    applyConfig(config)
                    (_state.value as? State.Streaming)?.let { _state.value = it.copy(video = config) }
                }
                else -> pool.recycle(message.buffer)
            }
        }
    }

    private fun applyConfig(config: VideoConfig) {
        _video.value = config
        synchronized(lock) { decoder?.configure(config) }
    }

    private val decoderListener = object : VideoDecoder.Listener {
        override fun onFrameDone(ptsUs: Long, rendered: Boolean) {
            if (rendered) this@StreamController.rendered.incrementAndGet() else skipped.incrementAndGet()
            connection?.send(Wire.u64Message(Wire.FRAME_RENDERED, ptsUs))
        }

        override fun onKeyframeNeeded(reason: String) {
            Log.i(TAG, "requesting keyframe: $reason")
            _stats.value = _stats.value.copy(keyframeRequests = _stats.value.keyframeRequests + 1)
            connection?.send(Wire.message(Wire.KEYFRAME_REQUEST))
        }

        override fun onDecoderInfo(name: String, hardware: Boolean) {
            _stats.value = _stats.value.copy(decoderName = name, hardwareDecoder = hardware)
        }
    }

    /** Socket plus a single writer thread, so senders (decoder, reader) never block on the network. */
    private class Connection(private val socket: Socket) {
        private val out = BufferedOutputStream(socket.getOutputStream())
        private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "DroidScreen-writer") }
        @Volatile private var closed = false

        fun send(bytes: ByteArray) {
            if (closed) return
            try {
                writer.execute {
                    try {
                        out.write(bytes)
                        out.flush()
                    } catch (_: IOException) {
                        close()
                    }
                }
            } catch (_: RejectedExecutionException) {
            }
        }

        fun close() {
            if (closed) return
            closed = true
            writer.shutdownNow()
            try { socket.close() } catch (_: IOException) {}
        }
    }

    companion object {
        private const val TAG = "DroidScreenSession"
        private const val AUTO = "auto"
    }
}
