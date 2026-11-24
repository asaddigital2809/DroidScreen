package com.droidscreen.receiver.decoder

/** Annex-B helpers: split an access unit into NAL units and extract parameter sets. */
object NalParser {
    private val START_CODE = byteArrayOf(0, 0, 0, 1)

    const val AVC_SPS = 7
    const val AVC_PPS = 8
    const val HEVC_VPS = 32
    const val HEVC_SPS = 33
    const val HEVC_PPS = 34

    /** NAL units as [start, end) offsets of the payload (start code excluded). */
    fun units(buffer: ByteArray, offset: Int, length: Int): List<IntArray> {
        val end = offset + length
        val result = ArrayList<IntArray>()
        var i = offset
        var nalStart = -1
        while (i + 3 <= end) {
            if (buffer[i].toInt() == 0 && buffer[i + 1].toInt() == 0) {
                val startCodeLength = when {
                    buffer[i + 2].toInt() == 1 -> 3
                    i + 4 <= end && buffer[i + 2].toInt() == 0 && buffer[i + 3].toInt() == 1 -> 4
                    else -> 0
                }
                if (startCodeLength > 0) {
                    if (nalStart >= 0) result.add(intArrayOf(nalStart, i))
                    nalStart = i + startCodeLength
                    i = nalStart
                    continue
                }
            }
            i++
        }
        if (nalStart in 0 until end) result.add(intArrayOf(nalStart, end))
        return result
    }

    fun avcType(b: Byte) = b.toInt() and 0x1F
    fun hevcType(b: Byte) = (b.toInt() shr 1) and 0x3F

    /**
     * MediaFormat codec-specific data, each buffer prefixed with a start code.
     * H.264 → [csd-0 = SPS, csd-1 = PPS]; HEVC → [csd-0 = VPS + SPS + PPS].
     * Returns null when a required parameter set is missing.
     */
    fun codecSpecificData(codec: String, buffer: ByteArray, offset: Int, length: Int): List<ByteArray>? {
        val units = units(buffer, offset, length)
        fun bytes(unit: IntArray) = START_CODE + buffer.copyOfRange(unit[0], unit[1])
        return if (codec == "hevc") {
            val vps = units.firstOrNull { hevcType(buffer[it[0]]) == HEVC_VPS } ?: return null
            val sps = units.firstOrNull { hevcType(buffer[it[0]]) == HEVC_SPS } ?: return null
            val pps = units.firstOrNull { hevcType(buffer[it[0]]) == HEVC_PPS } ?: return null
            listOf(bytes(vps) + bytes(sps) + bytes(pps))
        } else {
            val sps = units.firstOrNull { avcType(buffer[it[0]]) == AVC_SPS } ?: return null
            val pps = units.firstOrNull { avcType(buffer[it[0]]) == AVC_PPS } ?: return null
            listOf(bytes(sps), bytes(pps))
        }
    }
}
