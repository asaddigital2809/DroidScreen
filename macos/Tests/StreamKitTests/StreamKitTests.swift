import XCTest
@testable import StreamKit
import VirtualDisplayKit

final class WireTests: XCTestCase {
    func testMessageRoundTripAcrossChunks() throws {
        let a = Wire.u64(.ping, 0x0102_0304_0506_0708)
        let b = try Wire.json(.videoConfig, VideoConfig(codec: .hevc, width: 1280, height: 720, fps: 30))
        let stream = a + b
        var parser = MessageParser()
        var out: [(UInt8, Data)] = []
        for byte in stream {           // worst case: one byte at a time
            parser.append(Data([byte]))
            while let m = try parser.next() { out.append(m) }
        }
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].0, MessageType.ping.rawValue)
        XCTAssertEqual(Wire.readU64(out[0].1), 0x0102_0304_0506_0708)
        XCTAssertEqual(out[1].0, MessageType.videoConfig.rawValue)
        XCTAssertEqual(try JSONDecoder().decode(VideoConfig.self, from: out[1].1), VideoConfig(codec: .hevc, width: 1280, height: 720, fps: 30))
    }

    func testHeaderIsBigEndian() {
        let m = Wire.message(.keyframeRequest, Data([1, 2, 3]))
        XCTAssertEqual(Array(m), [0x84, 0, 0, 0, 3, 1, 2, 3])
    }

    func testOversizedPayloadRejected() {
        var parser = MessageParser()
        parser.append(Data([0x03, 0x7F, 0xFF, 0xFF, 0xFF]))
        XCTAssertThrowsError(try parser.next())
    }

    func testVideoFrameHeader() {
        var m = Wire.beginVideoFrame(keyframe: true, ptsMicros: 42, reservingPayload: 4)
        m.append(contentsOf: [0, 0, 0, 1, 0x65])
        Wire.finishMessage(&m)
        XCTAssertEqual(Array(m.prefix(14)), [0x03, 0, 0, 0, 14, 1, 0, 0, 0, 0, 0, 0, 0, 42])
        XCTAssertEqual(m.count, 5 + 9 + 5)
    }
}

final class AnnexBTests: XCTestCase {
    func testConvertsLengthPrefixedToStartCodes() throws {
        let avcc: [UInt8] = [0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x41]
        var out = Data()
        try avcc.withUnsafeBytes { try AnnexB.appendConverting(lengthPrefixed: $0, nalLengthSize: 4, to: &out) }
        XCTAssertEqual(Array(out), [0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x41])
    }

    func testRejectsTruncatedInput() {
        let avcc: [UInt8] = [0, 0, 0, 9, 0x65]
        var out = Data()
        XCTAssertThrowsError(try avcc.withUnsafeBytes { try AnnexB.appendConverting(lengthPrefixed: $0, nalLengthSize: 4, to: &out) })
    }
}

final class FlowControlTests: XCTestCase {
    func testThrottleByCountAndCumulativeAck() {
        var t = InFlightTracker(maxFrames: 3, maxAge: 10, staleTimeout: 100)
        t.sent(pts: 1, at: 0); t.sent(pts: 2, at: 0)
        XCTAssertFalse(t.shouldThrottle(now: 0))
        t.sent(pts: 3, at: 0)
        XCTAssertTrue(t.shouldThrottle(now: 0))
        XCTAssertEqual(t.acknowledge(pts: 2), 2)
        XCTAssertEqual(t.count, 1)
        XCTAssertFalse(t.shouldThrottle(now: 0))
    }

    func testThrottleByAgeAndStaleExpiry() {
        var t = InFlightTracker(maxFrames: 10, maxAge: 0.1, staleTimeout: 1)
        t.sent(pts: 1, at: 0)
        XCTAssertFalse(t.shouldThrottle(now: 0.05))
        XCTAssertTrue(t.shouldThrottle(now: 0.2))
        XCTAssertFalse(t.expireStale(now: 0.5))
        XCTAssertTrue(t.expireStale(now: 1.5))
        XCTAssertEqual(t.count, 0)
    }

    func testBitrateDecreasesOnCongestionAndRecovers() {
        var b = BitrateController(minBitrate: 1_000_000, maxBitrate: 10_000_000)
        b.recordCongestion()
        XCTAssertEqual(b.tick(now: 0), 7_500_000)
        b.recordCongestion()
        XCTAssertNil(b.tick(now: 0.5))            // at most one decrease per second
        XCTAssertNil(b.tick(now: 3))              // needs 5 s without congestion
        XCTAssertEqual(b.tick(now: 6), 8_625_000)
        XCTAssertNil(b.tick(now: 7))              // increases every 2 s
        XCTAssertEqual(b.tick(now: 8), 9_918_750)
        XCTAssertEqual(b.tick(now: 10), 10_000_000)
        XCTAssertNil(b.tick(now: 12))
    }

    func testBitrateFloor() {
        var b = BitrateController(minBitrate: 5_000_000, maxBitrate: 6_000_000)
        for i in 0..<5 { b.recordCongestion(); _ = b.tick(now: Double(i) * 2) }
        XCTAssertEqual(b.current, 5_000_000)
    }

    func testLatencyPercentiles() {
        var l = LatencyEstimator(capacity: 5)
        [50, 10, 30, 20, 40, 1000].forEach { l.add(Double($0)) }   // 50 falls out of the window
        XCTAssertEqual(l.median, 30)
        XCTAssertEqual(l.p95, 1000)
        l.add(-1); l.add(.nan)
        XCTAssertEqual(l.median, 30)
    }
}

final class StreamGeometryTests: XCTestCase {
    func testNoClientKeepsDisplaySize() {
        XCTAssertEqual(StreamGeometry.streamSize(display: PixelSize(width: 2400, height: 1080), client: nil, cap: nil), PixelSize(width: 2400, height: 1080))
    }

    func testFitsPortraitClientInLandscapeOrientation() {
        // Phone reports 1080×2400 in portrait; display is landscape 2400×1080 → unchanged.
        XCTAssertEqual(StreamGeometry.streamSize(display: PixelSize(width: 2400, height: 1080), client: PixelSize(width: 1080, height: 2400), cap: nil), PixelSize(width: 2400, height: 1080))
        // Smaller phone 720×1600 → 1600×720.
        XCTAssertEqual(StreamGeometry.streamSize(display: PixelSize(width: 2400, height: 1080), client: PixelSize(width: 720, height: 1600), cap: nil), PixelSize(width: 1600, height: 720))
    }

    func testNeverUpscalesAndKeepsEvenSizes() {
        XCTAssertEqual(StreamGeometry.streamSize(display: PixelSize(width: 1280, height: 720), client: PixelSize(width: 3000, height: 2000), cap: nil), PixelSize(width: 1280, height: 720))
        let s = StreamGeometry.streamSize(display: PixelSize(width: 2400, height: 1080), client: nil, cap: PixelSize(width: 1001, height: 1001))
        XCTAssertEqual(s.width % 2, 0)
        XCTAssertEqual(s.height % 2, 0)
        XCTAssertLessThanOrEqual(s.width, 1001)
    }
}

final class InputMessageTests: XCTestCase {
    private func f32(_ v: Float) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init) }

    func testDecodePointer() {
        let payload = Data([1, 0, 2, 0b10] + f32(0.25) + f32(0.75))
        XCTAssertEqual(InputMessage.decode(type: MessageType.pointer.rawValue, payload: payload),
                       .pointer(action: .down, button: 0, clickCount: 2, relative: false, atCursor: true, x: 0.25, y: 0.75))
    }

    func testDecodeScrollAndKey() {
        XCTAssertEqual(InputMessage.decode(type: MessageType.scroll.rawValue, payload: Data(f32(-0.5) + f32(0.125))), .scroll(dx: -0.5, dy: 0.125))
        let key = Data([1, 0, 31, 0, 1, 0, 0, 0, 0, 0, 0x63])   // down, KEYCODE_C, META_META_ON, 'c'
        XCTAssertEqual(InputMessage.decode(type: MessageType.key.rawValue, payload: key), .key(down: true, keyCode: 31, metaState: 0x10000, unicode: 0x63))
    }

    func testRejectsShortOrNonFinite() {
        XCTAssertNil(InputMessage.decode(type: MessageType.pointer.rawValue, payload: Data([0, 0, 1])))
        XCTAssertNil(InputMessage.decode(type: MessageType.scroll.rawValue, payload: Data(f32(.nan) + f32(0))))
        XCTAssertNil(InputMessage.decode(type: MessageType.ping.rawValue, payload: Data()))
    }

    func testTokenGenerationAndComparison() {
        let a = InputToken.generate(), b = InputToken.generate()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(InputToken.matches(a, a))
        XCTAssertFalse(InputToken.matches(b, a))
        XCTAssertFalse(InputToken.matches(nil, a))
        XCTAssertFalse(InputToken.matches(String(a.dropLast()), a))
    }
}

final class AdbBridgeTests: XCTestCase {
    func testWirelessDuplicateOfUSBDeviceIsDropped() {
        XCTAssertEqual(AdbBridge.uniqueDevices(["5e6a805b", "adb-5e6a805b-VB9OXI._adb-tls-connect._tcp"]), ["5e6a805b"])
        XCTAssertEqual(AdbBridge.uniqueDevices(["adb-5e6a805b-VB9OXI._adb-tls-connect._tcp"]), ["adb-5e6a805b-VB9OXI._adb-tls-connect._tcp"])
        XCTAssertEqual(AdbBridge.uniqueDevices(["emulator-5554", "5e6a805b"]), ["emulator-5554", "5e6a805b"])
        XCTAssertTrue(AdbBridge.isEmulator("emulator-5554"))
        XCTAssertFalse(AdbBridge.isEmulator("5e6a805b"))
        XCTAssertFalse(AdbBridge.isEmulator("adb-5e6a805b-VB9OXI._adb-tls-connect._tcp"))
    }
}

final class DecoderLimitTests: XCTestCase {
    func testDecoderLimitShrinksStream() {
        // Redmi (Snapdragon "khaje"): screen 2400×1080, hardware decoders max 1920×1088 @ 60.
        let size = StreamGeometry.streamSize(display: PixelSize(width: 2400, height: 1080),
                                             client: PixelSize(width: 1080, height: 2400), cap: nil,
                                             decoder: PixelSize(width: 1920, height: 864))
        XCTAssertEqual(size, PixelSize(width: 1920, height: 864))
    }

    func testClientHelloDecodesDecoderMaxSize() throws {
        let json = #"{"protocolVersion":1,"deviceName":"x","screenWidth":1080,"screenHeight":2400,"densityDpi":400,"codecs":["h264"],"decoderMaxSize":{"h264":{"width":864,"height":1920}}}"#
        let hello = try JSONDecoder().decode(ClientHello.self, from: Data(json.utf8))
        XCTAssertEqual(hello.decoderLimit(for: .h264), PixelSize(width: 1920, height: 864))
        XCTAssertNil(hello.decoderLimit(for: .hevc))
    }

    func testOldClientHelloWithoutLimitStillDecodes() throws {
        let json = #"{"protocolVersion":1,"deviceName":"x","screenWidth":1080,"screenHeight":2400,"densityDpi":400,"codecs":["h264"]}"#
        XCTAssertNil(try JSONDecoder().decode(ClientHello.self, from: Data(json.utf8)).decoderMaxSize)
        XCTAssertNil(try JSONDecoder().decode(ClientHello.self, from: Data(json.utf8)).takeOver)
    }

    func testClientHelloDecodesTakeOver() throws {
        let json = #"{"protocolVersion":1,"deviceName":"x","screenWidth":1080,"screenHeight":2400,"densityDpi":400,"codecs":["h264"],"takeOver":true}"#
        XCTAssertEqual(try JSONDecoder().decode(ClientHello.self, from: Data(json.utf8)).takeOver, true)
    }
}
