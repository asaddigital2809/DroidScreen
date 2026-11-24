package com.droidscreen.receiver.decoder

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.droidscreen.receiver.protocol.BufferPool
import com.droidscreen.receiver.protocol.VideoConfig
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Low-latency MediaCodec decoder that renders straight to a [Surface].
 *
 * - Runs on its own thread with a 4-frame input queue. When the queue is full, [submit] blocks,
 *   which stops socket reads and lets TCP back-pressure reach the host's flow control.
 * - The decoder is (re)created from the parameter sets in the next keyframe after a
 *   configuration change or error. Non-keyframes before that are dropped and a keyframe is requested.
 * - If several decoded frames are ready at once, only the newest is rendered; the older ones
 *   are released without rendering so latency does not build up.
 */
class VideoDecoder(
    private val surface: Surface,
    private val listener: Listener,
    private val pool: BufferPool,
) {
    interface Listener {
        /** Called for every decoded frame, rendered or skipped. */
        fun onFrameDone(ptsUs: Long, rendered: Boolean)
        fun onKeyframeNeeded(reason: String)
        fun onDecoderInfo(name: String, hardware: Boolean)
    }

    class Frame(val buffer: ByteArray, val offset: Int, val length: Int, val ptsUs: Long, val keyframe: Boolean)

    private val queue = ArrayBlockingQueue<Frame>(4)
    private val info = MediaCodec.BufferInfo()
    @Volatile private var running = true
    @Volatile private var config: VideoConfig? = null
    @Volatile private var configChanged = false
    private var codec: MediaCodec? = null
    private var lastKeyframeRequest = 0L
    private val thread = Thread(::loop, "DroidScreen-decoder").apply {
        priority = Thread.MAX_PRIORITY
        start()
    }

    fun configure(config: VideoConfig) {
        if (config == this.config) return
        this.config = config
        configChanged = true
    }

    /** Blocks while the queue is full. Returns false (and recycles the buffer) after [release]. */
    fun submit(frame: Frame): Boolean {
        while (running) {
            if (queue.offer(frame, 50, TimeUnit.MILLISECONDS)) return true
        }
        pool.recycle(frame.buffer)
        return false
    }

    fun release() {
        running = false
        thread.join(1000)
    }

    private fun loop() {
        try {
            while (running) {
                val frame = queue.poll(4, TimeUnit.MILLISECONDS)
                if (frame != null) {
                    try {
                        // Frames that never reach the decoder are acknowledged as skipped so the
                        // host's in-flight accounting stays correct.
                        if (!decode(frame)) listener.onFrameDone(frame.ptsUs, rendered = false)
                    } finally {
                        pool.recycle(frame.buffer)
                    }
                }
                drainOutput()
            }
        } catch (_: InterruptedException) {
        } finally {
            releaseCodec()
            while (true) pool.recycle((queue.poll() ?: break).buffer)
        }
    }

    /** Returns true when the frame was queued into the decoder. */
    private fun decode(frame: Frame): Boolean {
        val cfg = config ?: return false
        if (configChanged) {
            configChanged = false
            releaseCodec()
        }
        if (codec == null) {
            if (!frame.keyframe) {
                requestKeyframe("waiting for keyframe")
                return false
            }
            val csd = NalParser.codecSpecificData(cfg.codec, frame.buffer, frame.offset, frame.length)
            if (csd == null) {
                requestKeyframe("keyframe without parameter sets")
                return false
            }
            try {
                codec = createCodec(cfg, csd)
            } catch (e: Exception) {
                Log.e(TAG, "decoder creation failed", e)
                requestKeyframe("decoder creation failed: ${e.message}")
                return false
            }
        }
        val c = codec ?: return false
        try {
            var index: Int
            while (true) {
                index = c.dequeueInputBuffer(5_000)
                if (index >= 0) break
                drainOutput()
                if (!running || configChanged || codec !== c) return false
            }
            val input: ByteBuffer = c.getInputBuffer(index) ?: return false
            input.clear()
            if (frame.length > input.capacity()) {
                c.queueInputBuffer(index, 0, 0, frame.ptsUs, 0)
                throw IllegalStateException("frame ${frame.length} B exceeds input buffer ${input.capacity()} B")
            }
            input.put(frame.buffer, frame.offset, frame.length)
            c.queueInputBuffer(index, 0, frame.length, frame.ptsUs, 0)
            return true
        } catch (e: Exception) {
            codecFailed(e)
            return false
        }
    }

    private fun drainOutput() {
        val c = codec ?: return
        try {
            var pending = -1
            var pendingPts = 0L
            while (true) {
                val index = c.dequeueOutputBuffer(info, 0)
                when {
                    index >= 0 -> {
                        if (pending >= 0) {
                            c.releaseOutputBuffer(pending, false)
                            listener.onFrameDone(pendingPts, rendered = false)
                        }
                        pending = index
                        pendingPts = info.presentationTimeUs
                    }
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Log.i(TAG, "output format ${c.outputFormat}")
                    else -> break
                }
            }
            if (pending >= 0) {
                c.releaseOutputBuffer(pending, true)
                listener.onFrameDone(pendingPts, rendered = true)
            }
        } catch (e: Exception) {
            codecFailed(e)
        }
    }

    /**
     * Creates and starts a decoder. Some vendor decoders (seen on a Qualcomm c2.qti.avc.decoder)
     * reject optional keys with BAD_VALUE, so configurations are tried from fullest to plainest,
     * then on every other decoder that supports the size (hardware first, software last).
     * The working combination is remembered for the rest of the app run.
     */
    private fun createCodec(cfg: VideoConfig, csd: List<ByteArray>): MediaCodec {
        val mime = mimeType(cfg.codec)
        val candidates = (listOfNotNull(workingDecoder) + decoderCandidates(mime, cfg.width, cfg.height)).distinct()
        val variants = if (workingVariant != null) listOf(workingVariant!!) + Variant.entries.filter { it != workingVariant } else Variant.entries.toList()
        var last: Exception? = null
        for (name in candidates.ifEmpty { listOf<String?>(null) }) {
            for (variant in variants) {
                val codec = try {
                    if (name != null) MediaCodec.createByCodecName(name) else MediaCodec.createDecoderByType(mime)
                } catch (e: Exception) { last = e; break }
                try {
                    codec.configure(buildFormat(mime, cfg, csd, codec, variant), surface, null, 0)
                    codec.start()
                    workingDecoder = codec.name
                    workingVariant = variant
                    Log.i(TAG, "decoder ${codec.name} ${cfg.codec} ${cfg.width}x${cfg.height} variant=$variant hw=${codec.codecInfo.isHardwareAccelerated}")
                    listener.onDecoderInfo(codec.name, codec.codecInfo.isHardwareAccelerated)
                    return codec
                } catch (e: Exception) {
                    Log.w(TAG, "decoder ${codec.name} rejected variant $variant: $e")
                    last = e
                    codec.release()
                }
            }
        }
        throw last ?: IllegalStateException("no decoder for $mime ${cfg.width}x${cfg.height}")
    }

    /** Optional MediaFormat keys, from most to least. */
    private enum class Variant { FULL, NO_VENDOR_KEYS, PLAIN }

    private fun buildFormat(mime: String, cfg: VideoConfig, csd: List<ByteArray>, codec: MediaCodec, variant: Variant): MediaFormat {
        val format = MediaFormat.createVideoFormat(mime, cfg.width, cfg.height)
        csd.forEachIndexed { i, bytes -> format.setByteBuffer("csd-$i", ByteBuffer.wrap(bytes)) }
        if (variant == Variant.PLAIN) return format
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(cfg.width * cfg.height, 1 shl 20))
        val caps = codec.codecInfo.getCapabilitiesForType(mime)
        if (Build.VERSION.SDK_INT >= 30 && caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        if (variant == Variant.FULL && (codec.name.startsWith("c2.qti") || codec.name.startsWith("OMX.qcom"))) {
            format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
        }
        return format
    }

    @Volatile private var workingDecoder: String? = null
    @Volatile private var workingVariant: Variant? = null

    private fun codecFailed(e: Exception) {
        Log.w(TAG, "decoder error; will restart on next keyframe", e)
        releaseCodec()
        requestKeyframe("decoder error: ${e.message}")
    }

    private fun requestKeyframe(reason: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastKeyframeRequest < 300) return
        lastKeyframeRequest = now
        listener.onKeyframeNeeded(reason)
    }

    private fun releaseCodec() {
        val c = codec ?: return
        codec = null
        try { c.stop() } catch (_: Exception) {}
        try { c.release() } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "DroidScreenDecoder"

        fun mimeType(codec: String): String =
            if (codec == "hevc") MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

        /** Prefers hardware decoders, then ones advertising FEATURE_LowLatency. */
        /** All decoders that report support for this size: hardware first, then low-latency capable. */
        fun decoderCandidates(mime: String, width: Int, height: Int): List<String> =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, ignoreCase = true) } }
                .filter { info ->
                    runCatching { info.getCapabilitiesForType(mime).videoCapabilities?.isSizeSupported(width, height) == true }.getOrDefault(false)
                }
                .sortedWith(compareByDescending<MediaCodecInfo> { it.isHardwareAccelerated }
                    .thenByDescending { info ->
                        Build.VERSION.SDK_INT >= 30 &&
                            info.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                    })
                .map { it.name }

        fun chooseDecoder(mime: String, width: Int, height: Int): String? =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, ignoreCase = true) } }
                .filter { info ->
                    runCatching { info.getCapabilitiesForType(mime).videoCapabilities?.isSizeSupported(width, height) == true }.getOrDefault(false)
                }
                .sortedWith(compareByDescending<MediaCodecInfo> { it.isHardwareAccelerated }
                    .thenByDescending { info ->
                        Build.VERSION.SDK_INT >= 30 &&
                            info.getCapabilitiesForType(mime).isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                    })
                .firstOrNull()?.name

        /**
         * Largest landscape size with the screen's aspect ratio (long × short) that some decoder
         * for [codec] accepts at [fps]. Prefers hardware decoders: a software decoder is only used
         * when no hardware decoder handles even a small size. Null if nothing qualifies.
         */
        fun maxDecodeSize(codec: String, screenLong: Int, screenShort: Int, fps: Double = 60.0): Pair<Int, Int>? {
            val mime = mimeType(codec)
            val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, ignoreCase = true) } }
            fun search(infos: List<MediaCodecInfo>): Pair<Int, Int>? {
                val caps = infos.mapNotNull { runCatching { it.getCapabilitiesForType(mime).videoCapabilities }.getOrNull() }
                if (caps.isEmpty()) return null
                var scale = 1.0
                while (scale >= 0.25) {
                    val w = (screenLong * scale).toInt() and 1.inv()
                    val h = (screenShort * scale).toInt() and 1.inv()
                    if (caps.any { runCatching { it.areSizeAndRateSupported(w, h, fps) }.getOrDefault(false) }) return w to h
                    scale -= 0.01
                }
                return null
            }
            return search(decoders.filter { it.isHardwareAccelerated }) ?: search(decoders)
        }

        /** Codecs to advertise in the client hello. */
        fun supportedCodecs(): List<String> {
            val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }
            fun has(mime: String) = decoders.any { d -> d.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
            return buildList {
                add("h264")
                if (has(MediaFormat.MIMETYPE_VIDEO_HEVC)) add("hevc")
            }
        }
    }
}
