import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

struct EncodedFrame {
    /// Complete videoFrame wire message (header + Annex-B).
    let message: Data
    let isKeyframe: Bool
    let ptsMicros: UInt64
}

/// VideoToolbox hardware encoder configured for real-time screen content.
///
/// - No frame reordering (no B-frames): every frame can be decoded and shown immediately.
/// - H.264 uses Apple's low-latency rate control when available (Apple silicon / recent Intel).
/// - Falls back to a non-low-latency hardware session, then to any encoder.
final class VideoEncoder {
    struct Settings: Equatable {
        var codec: VideoCodec
        var width: Int
        var height: Int
        var fps: Int
        var bitrate: Int
    }

    let settings: Settings
    private(set) var isHardware = false
    private(set) var isLowLatency = false
    private var session: VTCompressionSession?
    private var lastPTS = CMTime.invalid
    private let onOutput: (EncodedFrame) -> Void
    private let onError: (OSStatus) -> Void
    private let log = Logger(subsystem: "com.droidscreen.host", category: "Encoder")

    /// `onOutput` / `onError` are called on a VideoToolbox thread.
    init(settings: Settings, onOutput: @escaping (EncodedFrame) -> Void, onError: @escaping (OSStatus) -> Void) throws {
        self.settings = settings
        self.onOutput = onOutput
        self.onError = onError

        let codecType = settings.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        var attempts: [(requireHardware: Bool, lowLatency: Bool)] = []
        if settings.codec == .h264 { attempts.append((true, true)) }
        attempts += [(true, false), (false, false)]

        var lastStatus: OSStatus = noErr
        var requiredHardware = false
        for attempt in attempts {
            var spec: [CFString: Any] = [:]
            if attempt.requireHardware {
                spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
            } else {
                spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = true
            }
            if attempt.lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(settings.width), height: Int32(settings.height),
                codecType: codecType,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil,
                compressionSessionOut: &created
            )
            if status == noErr, let created {
                session = created
                isLowLatency = attempt.lowLatency
                requiredHardware = attempt.requireHardware
                break
            }
            lastStatus = status
            log.info("encoder attempt hw=\(attempt.requireHardware) lowLatency=\(attempt.lowLatency) failed: \(status)")
        }
        guard let session else { throw StreamError.encoderUnavailable(lastStatus) }

        configure(session)
        // VTSessionCopyProperty writes a +1 retained CFTypeRef; deinitialize() balances it.
        let valueOut = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        valueOut.initialize(to: nil)
        VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: valueOut)
        // Low-latency sessions do not answer this query; a session created with
        // RequireHardwareAcceleratedVideoEncoder is hardware by definition.
        isHardware = requiredHardware || ((valueOut.pointee as? Bool) ?? false)
        valueOut.deinitialize(count: 1)
        valueOut.deallocate()
        VTCompressionSessionPrepareToEncodeFrames(session)
        log.info("encoder \(settings.codec.rawValue, privacy: .public) \(settings.width)x\(settings.height)@\(settings.fps) hw=\(self.isHardware) lowLatency=\(self.isLowLatency)")
    }

    deinit {
        invalidate()
    }

    private func configure(_ session: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef) {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr { log.debug("VTSessionSetProperty \(key as String, privacy: .public) → \(status)") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            settings.codec == .h264 ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: settings.fps * 2))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        // Signal BT.709 in the bitstream so the Android decoder converts colours correctly.
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        applyBitrate(settings.bitrate, to: session)
    }

    private func applyBitrate(_ bitrate: Int, to session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        if !isLowLatency {
            // Bytes per 1-second window: allow 1.5× average to absorb bursts after scene changes.
            let limits = [NSNumber(value: bitrate * 3 / 2 / 8), NSNumber(value: 1)] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        }
    }

    func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        applyBitrate(bitrate, to: session)
    }

    /// Must be called from one serial queue.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) throws {
        guard let session else { throw StreamError.encodeFailed(kVTInvalidSessionErr) }
        // VideoToolbox requires strictly increasing timestamps.
        var pts = pts
        if lastPTS.isValid, pts <= lastPTS { pts = lastPTS + CMTime(value: 1, timescale: 1_000_000) }
        lastPTS = pts

        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let codec = settings.codec
        let onOutput = onOutput
        let onError = onError
        let log = log
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { status, flags, sampleBuffer in
            guard status == noErr else { onError(status); return }
            guard !flags.contains(.frameDropped), let sampleBuffer else { return }
            do {
                onOutput(try AnnexB.makeVideoFrameMessage(sampleBuffer, codec: codec))
            } catch {
                log.error("packetize failed: \(String(describing: error), privacy: .public)")
            }
        }
        if status != noErr { throw StreamError.encodeFailed(status) }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}
