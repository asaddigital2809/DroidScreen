import CoreMedia
import Foundation

/// Converts VideoToolbox output (length-prefixed NAL units, "AVCC/HVCC") into an Annex-B
/// videoFrame wire message in a single allocation. Keyframes are prefixed with the codec's
/// parameter sets (H.264: SPS, PPS; HEVC: VPS, SPS, PPS) so a decoder can start from any keyframe.
enum AnnexB {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Appends the NAL units in `source` (each preceded by a `nalLengthSize`-byte big-endian length)
    /// to `out`, each preceded by a 4-byte start code.
    static func appendConverting(lengthPrefixed source: UnsafeRawBufferPointer, nalLengthSize: Int, to out: inout Data) throws {
        guard (1...4).contains(nalLengthSize), let base = source.baseAddress else {
            throw WireError.malformed("bad NAL length size \(nalLengthSize)")
        }
        var offset = 0
        while offset < source.count {
            guard offset + nalLengthSize <= source.count else { throw WireError.malformed("truncated NAL length at \(offset)") }
            var length = 0
            for k in 0..<nalLengthSize { length = length << 8 | Int(source[offset + k]) }
            offset += nalLengthSize
            guard length > 0, offset + length <= source.count else {
                throw WireError.malformed("NAL length \(length) at \(offset) exceeds \(source.count)")
            }
            out.append(contentsOf: startCode)
            out.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: length)
            offset += length
        }
    }

    /// Parameter sets and NAL length-field size from a compressed-video format description.
    static func parameterSets(of format: CMFormatDescription, codec: VideoCodec) -> (sets: [Data], nalLengthSize: Int) {
        var count = 0
        var nalLength: Int32 = 4
        var sets: [Data] = []
        switch codec {
        case .h264:
            _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        case .hevc:
            _ = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLength)
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        }
        return (sets, Int(nalLength))
    }

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    static func makeVideoFrameMessage(_ sampleBuffer: CMSampleBuffer, codec: VideoCodec) throws -> EncodedFrame {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer), let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw WireError.malformed("encoder output without data or format")
        }
        let keyframe = isKeyframe(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))
        let (sets, nalLengthSize) = parameterSets(of: format, codec: codec)
        let dataLength = CMBlockBufferGetDataLength(block)

        var message = Wire.beginVideoFrame(keyframe: keyframe, ptsMicros: ptsMicros, reservingPayload: dataLength + 128)
        if keyframe {
            for set in sets {
                message.append(contentsOf: startCode)
                message.append(set)
            }
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
           lengthAtOffset == totalLength, let pointer {
            try appendConverting(lengthPrefixed: UnsafeRawBufferPointer(start: pointer, count: totalLength), nalLengthSize: nalLengthSize, to: &message)
        } else {
            // Non-contiguous block buffer: copy once, then convert.
            var contiguous = Data(count: dataLength)
            let status = contiguous.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: dataLength, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw WireError.malformed("CMBlockBufferCopyDataBytes \(status)") }
            try contiguous.withUnsafeBytes {
                try appendConverting(lengthPrefixed: $0, nalLengthSize: nalLengthSize, to: &message)
            }
        }
        Wire.finishMessage(&message)
        return EncodedFrame(message: message, isKeyframe: keyframe, ptsMicros: ptsMicros)
    }
}
