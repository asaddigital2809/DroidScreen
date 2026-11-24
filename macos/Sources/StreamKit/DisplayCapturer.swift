import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VirtualDisplayKit

/// Captures one display with ScreenCaptureKit and delivers NV12 (420v) pixel buffers, which
/// VideoToolbox encodes without a colour conversion or copy.
///
/// ScreenCaptureKit only delivers a frame when the display content changes (up to `fps`),
/// so an idle desktop produces no frames.
final class DisplayCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let displayID: CGDirectDisplayID
    private let queue: DispatchQueue
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    private let onStop: (Error) -> Void
    private let lock = NSLock()
    private var stream: SCStream?

    /// `onFrame` runs on `queue`. `onStop` runs on an arbitrary thread.
    init(displayID: CGDirectDisplayID, queue: DispatchQueue,
         onFrame: @escaping (CVPixelBuffer, CMTime) -> Void,
         onStop: @escaping (Error) -> Void) {
        self.displayID = displayID
        self.queue = queue
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// Screen Recording permission (TCC). Does not prompt.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must enable it in
    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func configuration(size: PixelSize, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.itur_709
        config.queueDepth = 4
        config.showsCursor = true
        config.capturesAudio = false
        config.scalesToFit = true
        return config
    }

    func start(size: PixelSize, fps: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw StreamError.displayNotCapturable(displayID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.configuration(size: size, fps: fps), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        lock.withLock { self.stream = stream }
        try await stream.startCapture()
    }

    func update(size: PixelSize, fps: Int) async throws {
        guard let stream = lock.withLock({ self.stream }) else { return }
        try await stream.updateConfiguration(Self.configuration(size: size, fps: fps))
    }

    func stop() async {
        guard let stream = lock.withLock({ () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }) else { return }
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { if self.stream === stream { self.stream = nil } }
        onStop(error)
    }
}

/// Screen Recording (TCC) permission, required by ScreenCaptureKit.
public enum ScreenCapturePermission {
    /// True when this process may capture the screen. Never prompts.
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true if granted. Otherwise asks macOS to show its consent prompt (first time only;
    /// later the user must enable it in System Settings) and returns the current state.
    public static func ensure() -> Bool {
        if isGranted { return true }
        return CGRequestScreenCaptureAccess()
    }
}
