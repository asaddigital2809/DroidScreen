package com.droidscreen.receiver.protocol

import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.InputStream
import java.net.ProtocolException
import java.nio.ByteBuffer

/**
 * DroidScreen wire protocol v1. Mirror of macos/Sources/StreamKit/Wire.swift.
 *
 * Every message: [type: u8][length: u32 big-endian][payload].
 */
object Wire {
    const val VERSION = 1
    const val DEFAULT_PORT = 47800
    const val HEADER_SIZE = 5
    /** flags (1) + ptsMicros (8) at the start of a VIDEO_FRAME payload. */
    const val VIDEO_FRAME_HEADER_SIZE = 9
    const val MAX_PAYLOAD = 16 * 1024 * 1024

    // Host → client
    const val HOST_HELLO = 0x01
    const val VIDEO_CONFIG = 0x02
    const val VIDEO_FRAME = 0x03
    const val PING = 0x04
    const val HOST_BUSY = 0x05

    // Client → host
    const val CLIENT_HELLO = 0x81
    const val PONG = 0x82
    const val FRAME_RENDERED = 0x83
    const val KEYFRAME_REQUEST = 0x84
    const val POINTER = 0x85
    const val SCROLL = 0x86
    const val KEY = 0x87

    fun message(type: Int, payload: ByteArray = ByteArray(0), length: Int = payload.size): ByteArray {
        val out = ByteBuffer.allocate(HEADER_SIZE + length)
        out.put(type.toByte())
        out.putInt(length)
        out.put(payload, 0, length)
        return out.array()
    }

    fun u64Message(type: Int, value: Long): ByteArray =
        message(type, ByteBuffer.allocate(8).putLong(value).array())

    fun readU64(buffer: ByteArray, offset: Int = 0): Long = ByteBuffer.wrap(buffer, offset, 8).long

    fun clientHello(hello: ClientHello): ByteArray =
        message(CLIENT_HELLO, hello.toJson().toString().toByteArray(Charsets.UTF_8))
}

data class VideoConfig(val codec: String, val width: Int, val height: Int, val fps: Int) {
    companion object {
        fun fromJson(o: JSONObject) = VideoConfig(o.getString("codec"), o.getInt("width"), o.getInt("height"), o.getInt("fps"))
        fun parse(message: Message) = fromJson(JSONObject(message.text()))
    }
}

data class HostHello(val protocolVersion: Int, val displayName: String, val video: VideoConfig, val inputEnabled: Boolean) {
    companion object {
        fun parse(message: Message): HostHello {
            val o = JSONObject(message.text())
            return HostHello(
                o.getInt("protocolVersion"), o.getString("displayName"),
                VideoConfig.fromJson(o.getJSONObject("video")), o.optBoolean("inputEnabled", false),
            )
        }
    }
}

data class ClientHello(
    val protocolVersion: Int,
    val deviceName: String,
    val screenWidth: Int,
    val screenHeight: Int,
    val densityDpi: Int,
    val codecs: List<String>,
    /** Session input token from the Mac (adb or typed). Null → view-only. */
    val inputToken: String? = null,
    /** Random ID persisted on this device so the host recognises reconnects. */
    val clientId: String? = null,
    /** Per codec: largest landscape size (width, height) a hardware/any decoder handles at 60 fps. */
    val decoderMaxSize: Map<String, Pair<Int, Int>> = emptyMap(),
    /** The user started this connection: the host switches to this device even if another one is streaming. */
    val takeOver: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("protocolVersion", protocolVersion)
        .put("deviceName", deviceName)
        .put("screenWidth", screenWidth)
        .put("screenHeight", screenHeight)
        .put("densityDpi", densityDpi)
        .put("codecs", JSONArray(codecs))
        .apply { if (!inputToken.isNullOrBlank()) put("inputToken", inputToken) }
        .apply { if (clientId != null) put("clientId", clientId) }
        .apply { if (takeOver) put("takeOver", true) }
        .apply {
            if (decoderMaxSize.isNotEmpty()) {
                val limits = JSONObject()
                decoderMaxSize.forEach { (codec, size) -> limits.put(codec, JSONObject().put("width", size.first).put("height", size.second)) }
                put("decoderMaxSize", limits)
            }
        }
}

/** Builders for input messages (0x85–0x87). Coordinates are normalised to the video image. */
object InputWire {
    const val LEFT = 0
    const val RIGHT = 1
    private const val MOVE = 0
    private const val DOWN = 1
    private const val UP = 2
    private const val FLAG_RELATIVE = 1
    private const val FLAG_AT_CURSOR = 2

    private fun pointer(action: Int, button: Int, clickCount: Int, flags: Int, x: Float, y: Float): ByteArray =
        Wire.message(
            Wire.POINTER,
            ByteBuffer.allocate(12).put(action.toByte()).put(button.toByte()).put(clickCount.toByte()).put(flags.toByte())
                .putFloat(x).putFloat(y).array(),
        )

    fun move(x: Float, y: Float) = pointer(MOVE, LEFT, 0, 0, x, y)
    fun moveBy(dx: Float, dy: Float) = pointer(MOVE, LEFT, 0, FLAG_RELATIVE, dx, dy)
    fun down(button: Int, x: Float, y: Float, clickCount: Int) = pointer(DOWN, button, clickCount, 0, x, y)
    fun up(button: Int, x: Float, y: Float, clickCount: Int) = pointer(UP, button, clickCount, 0, x, y)
    fun downAtCursor(button: Int, clickCount: Int) = pointer(DOWN, button, clickCount, FLAG_AT_CURSOR, 0f, 0f)
    fun upAtCursor(button: Int, clickCount: Int) = pointer(UP, button, clickCount, FLAG_AT_CURSOR, 0f, 0f)

    /** Positive dy = content moves down (finger moved down). */
    fun scroll(dx: Float, dy: Float) = Wire.message(Wire.SCROLL, ByteBuffer.allocate(8).putFloat(dx).putFloat(dy).array())

    fun key(down: Boolean, keyCode: Int, metaState: Int, unicode: Int) = Wire.message(
        Wire.KEY,
        ByteBuffer.allocate(11).put((if (down) 1 else 0).toByte()).putShort(keyCode.toShort()).putInt(metaState).putInt(unicode).array(),
    )
}

/** A received message. `buffer` may be larger than `length` (it comes from [BufferPool]). */
class Message(val type: Int, val buffer: ByteArray, val length: Int) {
    fun text(): String = String(buffer, 0, length, Charsets.UTF_8)
}

/**
 * Reuses large byte arrays for video frames so the receive path does not allocate a new
 * array per frame. Arrays are returned with [recycle] after the decoder copied the data.
 */
class BufferPool(private val maxPooled: Int = 8) {
    private val pool = java.util.ArrayDeque<ByteArray>()

    @Synchronized
    fun obtain(size: Int): ByteArray {
        val iterator = pool.iterator()
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if (candidate.size >= size) {
                iterator.remove()
                return candidate
            }
        }
        // Round up so slightly larger frames later can reuse this array.
        return ByteArray(maxOf(size + size / 4, 64 * 1024))
    }

    @Synchronized
    fun recycle(buffer: ByteArray) {
        if (pool.size < maxPooled) pool.addLast(buffer)
    }

    @Synchronized
    fun size(): Int = pool.size
}

/** Blocking reader. Throws [java.io.EOFException] when the host closes the connection. */
class MessageReader(input: InputStream, private val pool: BufferPool) {
    private val input = DataInputStream(input)
    private val header = ByteArray(Wire.HEADER_SIZE)

    fun read(): Message {
        input.readFully(header)
        val type = header[0].toInt() and 0xFF
        val length = ByteBuffer.wrap(header, 1, 4).int
        if (length < 0 || length > Wire.MAX_PAYLOAD) throw ProtocolException("invalid payload length $length")
        val buffer = pool.obtain(length)
        input.readFully(buffer, 0, length)
        return Message(type, buffer, length)
    }
}
