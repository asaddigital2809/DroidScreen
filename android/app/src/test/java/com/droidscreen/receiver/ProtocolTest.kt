package com.droidscreen.receiver

import com.droidscreen.receiver.decoder.NalParser
import com.droidscreen.receiver.protocol.BufferPool
import com.droidscreen.receiver.protocol.ClientHello
import com.droidscreen.receiver.protocol.HostHello
import com.droidscreen.receiver.protocol.MessageReader
import com.droidscreen.receiver.protocol.Wire
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.ProtocolException

class WireTest {
    @Test
    fun headerIsBigEndianAndMatchesSwift() {
        // Same bytes as WireTests.testHeaderIsBigEndian in the Swift package.
        assertArrayEquals(byteArrayOf(0x84.toByte(), 0, 0, 0, 3, 1, 2, 3), Wire.message(Wire.KEYFRAME_REQUEST, byteArrayOf(1, 2, 3)))
    }

    @Test
    fun readerParsesConsecutiveMessages() {
        val hostHello = """{"protocolVersion":1,"displayName":"DroidScreen","video":{"codec":"h264","width":2400,"height":1080,"fps":60}}"""
        val bytes = Wire.message(Wire.HOST_HELLO, hostHello.toByteArray()) + Wire.u64Message(Wire.PING, 0x0102030405060708)
        val reader = MessageReader(ByteArrayInputStream(bytes), BufferPool())
        val first = reader.read()
        assertEquals(Wire.HOST_HELLO, first.type)
        val hello = HostHello.parse(first)
        assertEquals(2400, hello.video.width)
        assertEquals("h264", hello.video.codec)
        val second = reader.read()
        assertEquals(Wire.PING, second.type)
        assertEquals(0x0102030405060708, Wire.readU64(second.buffer))
    }

    @Test(expected = ProtocolException::class)
    fun readerRejectsOversizedPayload() {
        MessageReader(ByteArrayInputStream(byteArrayOf(3, 0x7F, -1, -1, -1)), BufferPool()).read()
    }

    @Test
    fun clientHelloJsonHasExpectedKeys() {
        val json = ClientHello(1, "Pixel", 1080, 2400, 420, listOf("h264", "hevc")).toJson()
        assertEquals(1080, json.getInt("screenWidth"))
        assertEquals("hevc", json.getJSONArray("codecs").getString(1))
    }

    @Test
    fun bufferPoolReusesLargeEnoughBuffers() {
        val pool = BufferPool(maxPooled = 2)
        val a = pool.obtain(100_000)
        pool.recycle(a)
        assertTrue(pool.obtain(90_000) === a)
    }
}

class NalParserTest {
    private val avcKeyframe = byteArrayOf(
        0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F,   // SPS (type 7)
        0, 0, 0, 1, 0x68, 0xEE.toByte(), 0x3C, // PPS (type 8)
        0, 0, 1, 0x65, 0x11, 0x22,             // IDR slice (type 5), 3-byte start code
    )

    @Test
    fun splitsThreeAndFourByteStartCodes() {
        val units = NalParser.units(avcKeyframe, 0, avcKeyframe.size)
        assertEquals(3, units.size)
        assertEquals(listOf(7, 8, 5), units.map { NalParser.avcType(avcKeyframe[it[0]]) })
        assertEquals(avcKeyframe.size, units.last()[1])
    }

    @Test
    fun avcCodecSpecificData() {
        val csd = NalParser.codecSpecificData("h264", avcKeyframe, 0, avcKeyframe.size)!!
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F), csd[0])
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x68, 0xEE.toByte(), 0x3C), csd[1])
    }

    @Test
    fun hevcCodecSpecificDataConcatenatesVpsSpsPps() {
        val hevc = byteArrayOf(
            0, 0, 0, 1, 0x40, 0x01, 0x0C,   // VPS (32 << 1)
            0, 0, 0, 1, 0x42, 0x01, 0x01,   // SPS (33 << 1)
            0, 0, 0, 1, 0x44, 0x01, 0xC1.toByte(), // PPS (34 << 1)
            0, 0, 0, 1, 0x26, 0x01, 0xAF.toByte(), // IDR_W_RADL (19 << 1)
        )
        val csd = NalParser.codecSpecificData("hevc", hevc, 0, hevc.size)!!
        assertEquals(1, csd.size)
        assertArrayEquals(hevc.copyOfRange(0, 21), csd[0])
    }

    @Test
    fun missingParameterSetsReturnNull() {
        val slice = byteArrayOf(0, 0, 0, 1, 0x41, 0x9A.toByte())
        assertNull(NalParser.codecSpecificData("h264", slice, 0, slice.size))
    }
}

class InputWireTest {
    @Test
    fun pointerLayoutMatchesSwiftDecoder() {
        // Same layout as InputMessageTests.testDecodePointer in the Swift package.
        val m = com.droidscreen.receiver.protocol.InputWire.downAtCursor(com.droidscreen.receiver.protocol.InputWire.LEFT, 2)
        assertArrayEquals(byteArrayOf(0x85.toByte(), 0, 0, 0, 12, 1, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0), m)
        val move = com.droidscreen.receiver.protocol.InputWire.move(0.25f, 0.75f)
        assertEquals(0.25f, java.nio.ByteBuffer.wrap(move, 9, 4).float)
        assertEquals(0.75f, java.nio.ByteBuffer.wrap(move, 13, 4).float)
    }

    @Test
    fun keyLayoutMatchesSwiftDecoder() {
        // down, KEYCODE_C (31), META_META_ON, 'c' — same bytes as testDecodeScrollAndKey.
        val m = com.droidscreen.receiver.protocol.InputWire.key(true, 31, 0x10000, 0x63)
        assertArrayEquals(byteArrayOf(0x87.toByte(), 0, 0, 0, 11, 1, 0, 31, 0, 1, 0, 0, 0, 0, 0, 0x63), m)
    }

    @Test
    fun clientHelloOmitsBlankToken() {
        assertTrue(!ClientHello(1, "x", 1, 1, 1, listOf("h264")).toJson().has("inputToken"))
        assertEquals("abc", ClientHello(1, "x", 1, 1, 1, listOf("h264"), "abc").toJson().getString("inputToken"))
    }
}

class DecoderLimitWireTest {
    @Test
    fun clientHelloCarriesDecoderMaxSize() {
        val json = ClientHello(1, "x", 1080, 2400, 400, listOf("h264"), decoderMaxSize = mapOf("h264" to (1920 to 864))).toJson()
        val h264 = json.getJSONObject("decoderMaxSize").getJSONObject("h264")
        assertEquals(1920, h264.getInt("width"))
        assertEquals(864, h264.getInt("height"))
        assertTrue(!ClientHello(1, "x", 1, 1, 1, listOf("h264")).toJson().has("decoderMaxSize"))
        assertTrue(!ClientHello(1, "x", 1, 1, 1, listOf("h264")).toJson().has("takeOver"))
        assertTrue(ClientHello(1, "x", 1, 1, 1, listOf("h264"), takeOver = true).toJson().getBoolean("takeOver"))
    }
}
