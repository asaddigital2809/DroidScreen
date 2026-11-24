import VirtualDisplayKit
import Foundation
import Security

// DroidScreen wire protocol, version 1.
//
// Every message: [type: UInt8][length: UInt32 big-endian][payload: length bytes]
//
// Host → client
//   0x01 hostHello      JSON HostHello
//   0x02 videoConfig    JSON VideoConfig (stream size/codec changed; new keyframe follows)
//   0x03 videoFrame     [flags: UInt8, bit0 = keyframe][ptsMicros: UInt64 BE][Annex-B access unit]
//   0x04 ping           [hostTimeMicros: UInt64 BE]
//   0x05 hostBusy       UTF-8 reason; the host streams to another device and closes this connection
// Client → host
//   0x81 clientHello    JSON ClientHello (must be the first client message)
//   0x82 pong           [hostTimeMicros: UInt64 BE] echoed from ping
//   0x83 frameRendered  [ptsMicros: UInt64 BE] echoed from videoFrame after it was rendered
//   0x84 keyframeRequest (empty)
//   0x85 pointer        [action u8: 0 move, 1 down, 2 up][button u8: 0 left, 1 right][clickCount u8]
//                       [flags u8: bit0 relative (x,y are deltas), bit1 at current cursor][x f32 BE][y f32 BE]
//                       x, y are normalised to the video image (0…1, origin top-left).
//   0x86 scroll         [dx f32 BE][dy f32 BE] normalised; positive dy = content moves down
//   0x87 key            [down u8][androidKeyCode u16 BE][androidMetaState u32 BE][unicode u32 BE]
//
// Input messages (0x85–0x87) are ignored unless the client hello carried the session's input token.
//
// The Android implementation lives in android/app/src/main/java/com/droidscreen/receiver/protocol/Wire.kt.

public enum WireProtocol {
    public static let version = 1
    public static let defaultPort: UInt16 = 47800
    /// Bonjour/DNS-SD service type advertised while LAN connections are allowed.
    public static let bonjourServiceType = "_droidscreen._tcp"
    public static let headerSize = 5
    /// flags (1) + ptsMicros (8)
    public static let videoFrameHeaderSize = 9
    public static let maxPayload = 16 * 1024 * 1024
}

public enum MessageType: UInt8, Sendable {
    case hostHello = 0x01
    case videoConfig = 0x02
    case videoFrame = 0x03
    case ping = 0x04
    case hostBusy = 0x05
    case clientHello = 0x81
    case pong = 0x82
    case frameRendered = 0x83
    case keyframeRequest = 0x84
    case pointer = 0x85
    case scroll = 0x86
    case key = 0x87
}

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
}

public struct VideoConfig: Codable, Equatable, Sendable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    public var fps: Int

    public init(codec: VideoCodec, width: Int, height: Int, fps: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
    }
}

public struct HostHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var displayName: String
    public var video: VideoConfig
    /// True when the client's input token was accepted and the host accepts input events.
    public var inputEnabled: Bool
}

public struct ClientHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var deviceName: String
    /// Physical screen size in pixels (any orientation).
    public var screenWidth: Int
    public var screenHeight: Int
    public var densityDpi: Int
    /// Codecs the device can decode in hardware, e.g. ["h264", "hevc"].
    public var codecs: [String]
    /// Session input token (delivered over adb for USB). Nil/wrong → view-only.
    public var inputToken: String?
    /// Random ID persisted on the device; identifies reconnects of the same device.
    public var clientId: String?
    /// Largest landscape size (width ≥ height) the device can decode at the host's frame rate,
    /// per codec, e.g. {"h264": {"width":1920,"height":864}}. Nil/missing codec → no limit known.
    public var decoderMaxSize: [String: DecoderSize]?
    /// True when the user started this connection on the device (Connect button, opening the
    /// app). The host then switches to this device even if another device is streaming.
    /// Automatic retries send false/nil, so two devices do not keep taking the stream from each other.
    public var takeOver: Bool?

    public init(protocolVersion: Int, deviceName: String, screenWidth: Int, screenHeight: Int, densityDpi: Int,
                codecs: [String], inputToken: String? = nil, clientId: String? = nil, decoderMaxSize: [String: DecoderSize]? = nil,
                takeOver: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.densityDpi = densityDpi
        self.codecs = codecs
        self.inputToken = inputToken
        self.clientId = clientId
        self.decoderMaxSize = decoderMaxSize
        self.takeOver = takeOver
    }

    /// Decoder limit for `codec`, as a landscape PixelSize.
    public func decoderLimit(for codec: VideoCodec) -> PixelSize? {
        guard let size = decoderMaxSize?[codec.rawValue], size.width > 0, size.height > 0 else { return nil }
        return PixelSize(width: max(size.width, size.height), height: min(size.width, size.height))
    }
}

public struct DecoderSize: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum WireError: Error, Equatable {
    case payloadTooLarge(Int)
    case malformed(String)
}

public enum Wire {
    public static func message(_ type: MessageType, _ payload: Data = Data()) -> Data {
        var data = Data(capacity: WireProtocol.headerSize + payload.count)
        data.append(type.rawValue)
        appendU32(&data, UInt32(payload.count))
        data.append(payload)
        return data
    }

    public static func json<T: Encodable>(_ type: MessageType, _ value: T) throws -> Data {
        message(type, try JSONEncoder().encode(value))
    }

    public static func u64(_ type: MessageType, _ value: UInt64) -> Data {
        var payload = Data(capacity: 8)
        appendU64(&payload, value)
        return message(type, payload)
    }

    /// Starts a videoFrame message whose Annex-B payload the caller appends afterwards.
    /// Call `finishMessage` once the payload is complete to write the length field.
    public static func beginVideoFrame(keyframe: Bool, ptsMicros: UInt64, reservingPayload capacity: Int) -> Data {
        var data = Data(capacity: WireProtocol.headerSize + WireProtocol.videoFrameHeaderSize + capacity)
        data.append(MessageType.videoFrame.rawValue)
        appendU32(&data, 0)
        data.append(keyframe ? 1 : 0)
        appendU64(&data, ptsMicros)
        return data
    }

    public static func finishMessage(_ data: inout Data) {
        let length = UInt32(data.count - WireProtocol.headerSize)
        let base = data.startIndex
        data[base + 1] = UInt8(truncatingIfNeeded: length >> 24)
        data[base + 2] = UInt8(truncatingIfNeeded: length >> 16)
        data[base + 3] = UInt8(truncatingIfNeeded: length >> 8)
        data[base + 4] = UInt8(truncatingIfNeeded: length)
    }

    public static func readU64(_ data: Data, at offset: Int = 0) -> UInt64? {
        guard data.count >= offset + 8 else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value = value << 8 | UInt64(data[data.startIndex + offset + i]) }
        return value
    }

    static func appendU32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    static func appendU64(_ data: inout Data, _ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Incremental parser for the framed stream. Feed bytes with `append`, drain with `next`.
public struct MessageParser {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete message, nil if more bytes are needed.
    /// Unknown message types are returned too (raw type byte) so callers can skip them.
    public mutating func next() throws -> (type: UInt8, payload: Data)? {
        guard buffer.count >= WireProtocol.headerSize else { return nil }
        let base = buffer.startIndex
        let type = buffer[base]
        let length = Int(buffer[base + 1]) << 24 | Int(buffer[base + 2]) << 16 | Int(buffer[base + 3]) << 8 | Int(buffer[base + 4])
        guard length <= WireProtocol.maxPayload else { throw WireError.payloadTooLarge(length) }
        let end = base + WireProtocol.headerSize + length
        guard buffer.endIndex >= end else { return nil }
        let payload = buffer.subdata(in: (base + WireProtocol.headerSize)..<end)
        buffer = buffer.subdata(in: end..<buffer.endIndex)
        return (type, payload)
    }
}

/// Decoded input message from the client.
public enum InputMessage: Equatable, Sendable {
    public enum PointerAction: UInt8, Sendable { case move = 0, down = 1, up = 2 }

    case pointer(action: PointerAction, button: UInt8, clickCount: Int, relative: Bool, atCursor: Bool, x: Double, y: Double)
    case scroll(dx: Double, dy: Double)
    case key(down: Bool, keyCode: Int, metaState: UInt32, unicode: UInt32)

    public static func decode(type: UInt8, payload: Data) -> InputMessage? {
        let bytes = [UInt8](payload)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]) }
        func f32(_ i: Int) -> Double? {
            let value = Double(Float(bitPattern: u32(i)))
            return value.isFinite ? value : nil
        }
        switch MessageType(rawValue: type) {
        case .pointer:
            guard bytes.count >= 12, let action = PointerAction(rawValue: bytes[0]), let x = f32(4), let y = f32(8) else { return nil }
            return .pointer(action: action, button: bytes[1], clickCount: Int(bytes[2]),
                            relative: bytes[3] & 1 != 0, atCursor: bytes[3] & 2 != 0, x: x, y: y)
        case .scroll:
            guard bytes.count >= 8, let dx = f32(0), let dy = f32(4) else { return nil }
            return .scroll(dx: dx, dy: dy)
        case .key:
            guard bytes.count >= 11 else { return nil }
            return .key(down: bytes[0] != 0, keyCode: Int(u16(1)), metaState: u32(3), unicode: u32(7))
        default:
            return nil
        }
    }
}

/// Random per-session secret that authorises input events.
public enum InputToken {
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison.
    public static func matches(_ candidate: String?, _ expected: String) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
