import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import InputKit
import Network
import VirtualDisplayKit
import os

public struct StreamOptions: Sendable {
    public var port: UInt16 = WireProtocol.defaultPort
    /// false: listen on 127.0.0.1 only (USB via `adb reverse`, emulator via 10.0.2.2).
    /// true: listen on all interfaces. Unencrypted until Milestone 3.
    public var allowLAN = false
    public var codec: VideoCodec = .h264
    public var fps = 60
    public var maxBitrate = 20_000_000
    public var minBitrate = 2_000_000
    /// Upper bound for the encoded size (aspect ratio kept).
    public var maxStreamSize: PixelSize?
    /// Shrink the stream to the client's screen size when it is smaller than the display.
    public var matchClientResolution = true
    /// Accept touch/keyboard input from clients that present the session's input token.
    public var inputEnabled = true
    /// Fixed input token (e.g. kept across session restarts). Nil = generate a new one.
    public var inputToken: String?
    /// Bonjour service name advertised (type `WireProtocol.bonjourServiceType`) when `allowLAN`
    /// is true, so Android receivers on the same network find the Mac. Nil = the computer name.
    public var bonjourName: String?
    /// Advertise the LAN listener over Bonjour. Has no effect when `allowLAN` is false.
    public var advertiseBonjour = true

    public init() {}
}

public struct StreamStats: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case stopped
        case listening
        case streaming
        case failed(String)
    }

    public var state: State = .stopped
    public var port: UInt16 = 0
    public var clientName: String?
    public var clientAddress: String?
    public var video: VideoConfig?
    public var hardwareEncoder = false
    public var lowLatencyRateControl = false
    /// Frames per second over the last stats interval.
    public var captureFPS = 0.0
    public var sentFPS = 0.0
    public var skippedFPS = 0.0
    public var renderedFPS = 0.0
    public var sentKbps = 0.0
    public var targetKbps = 0
    public var inFlight = 0
    public var rttMs: Double?
    /// Capture timestamp → Android render call, minus half the RTT (median / 95th percentile).
    public var latencyMs: Double?
    public var latencyP95Ms: Double?
    public var totalFramesSent = 0
    public var totalKeyframes = 0
    public var clientSessions = 0
    /// The connected client presented a valid input token and input is enabled.
    public var inputAuthorized = false
    /// Accessibility permission granted (required to post events).
    public var accessibilityTrusted = false
    public var inputEventsPerSecond = 0.0

    public init() {}

    public var summary: String {
        switch state {
        case .stopped: return "stopped"
        case .failed(let message): return "failed: \(message)"
        case .listening: return "listening on :\(port), waiting for Android client"
        case .streaming:
            let v = video.map { "\($0.codec.rawValue) \($0.width)×\($0.height)" } ?? "-"
            func ms(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "-" }
            return String(
                format: "%@ | cap %.0f sent %.0f shown %.0f skip %.0f fps | %.1f Mbps (target %.1f) | rtt %@ ms | latency %@ ms (p95 %@)",
                v, captureFPS, sentFPS, renderedFPS, skippedFPS, sentKbps / 1000, Double(targetKbps) / 1000,
                ms(rttMs), ms(latencyMs), ms(latencyP95Ms)
            )
        }
    }
}

/// Streams one display to one Android client.
///
/// Pipeline: ScreenCaptureKit (NV12) → VideoToolbox (H.264/HEVC, no B-frames) → TCP.
/// All state lives on one serial queue. A new client replaces the current one (this makes
/// reconnection after a half-open TCP connection immediate).
public final class StreamSession: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    public let displayName: String
    public let options: StreamOptions
    /// Called on the main queue.
    public var onStats: ((StreamStats) -> Void)?
    /// Called on the main queue with human-readable events.
    public var onEvent: ((String) -> Void)?
    /// Called on the main queue (once) when the streamed display no longer exists.
    /// The owner should recreate the display and start a new session.
    public var onDisplayLost: (() -> Void)?
    /// Secret a client must present (ClientHello.inputToken) before input events are accepted.
    public let inputToken: String

    private let queue = DispatchQueue(label: "com.droidscreen.stream", qos: .userInteractive)
    private let log = Logger(subsystem: "com.droidscreen.host", category: "Stream")

    private var running = false
    private var server: StreamServer?
    private var client: ClientConnection?
    private var pendingClients: [ObjectIdentifier: ClientConnection] = [:]
    private var clientHello: ClientHello?
    private var generation = 0
    private var capturer: DisplayCapturer?
    private var encoder: VideoEncoder?
    private var video: VideoConfig?
    private var forceKeyframe = true
    private var lastPixelBuffer: CVPixelBuffer?
    /// Increments on every capture; an idle refresh only runs if no newer capture arrived.
    private var captureSequence = 0
    /// PTS (µs) of the pending idle-refresh frame; it is sent but not tracked as in flight.
    private var refreshPTSMicros: UInt64?
    /// Delay after the last capture before the latest image is sent once more.
    static let idleRefreshDelay = 0.15
    private var tracker = InFlightTracker()
    private var bitrate: BitrateController
    private var latency = LatencyEstimator()
    private var rttSeconds: Double?
    private var lastPongAt = 0.0
    private var timer: DispatchSourceTimer?
    private var stats = StreamStats()
    private var counters = Counters()
    private var lastTick = 0.0
    private var reconfigurePending = false
    private var reconfigurationRegistered = false
    private var inputEnabled: Bool
    private var inputAuthorized = false
    private var injector: InputInjector?
    private var warnedNoAccessibility = false
    private var displayLost = false

    private struct Counters {
        var captured = 0, sent = 0, skipped = 0, rendered = 0, bytes = 0, input = 0
    }

    public init(displayID: CGDirectDisplayID, displayName: String = "DroidScreen", options: StreamOptions = StreamOptions()) {
        self.displayID = displayID
        self.displayName = displayName
        self.options = options
        self.bitrate = BitrateController(minBitrate: options.minBitrate, maxBitrate: options.maxBitrate)
        self.inputToken = options.inputToken ?? InputToken.generate()
        self.inputEnabled = options.inputEnabled
    }

    /// Enables or disables input for the current and future clients.
    public func setInputEnabled(_ enabled: Bool) {
        queue.async {
            self.inputEnabled = enabled
            if !enabled {
                self.injector?.releaseAll()
                self.injector = nil
                self.inputAuthorized = false
            } else if let hello = self.clientHello {
                self.inputAuthorized = InputToken.matches(hello.inputToken, self.inputToken)
            }
            self.stats.inputAuthorized = self.inputAuthorized
            self.event("Touch input \(enabled ? "enabled" : "disabled")")
            self.publish()
        }
    }

    deinit {
        if reconfigurationRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    // MARK: Public control

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            let server = StreamServer(port: options.port, allowLAN: options.allowLAN, queue: queue,
                                      bonjourName: options.allowLAN && options.advertiseBonjour ? (options.bonjourName ?? "") : nil)
            server.onConnection = { [weak self] in self?.accept($0) }
            server.onReady = { [weak self] in self?.event("Listening on \(self?.options.allowLAN == true ? "all interfaces" : "127.0.0.1"):\(self?.options.port ?? 0)") }
            server.onFailure = { [weak self] error in self?.fail("Listener failed: \(error)") }
            try server.start()
            self.server = server
            running = true
            stats.state = .listening
            stats.port = options.port
            stats.targetKbps = bitrate.current / 1000
            CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
            reconfigurationRegistered = true
            startTimer()
            publish()
        }
    }

    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                let capturer = self.teardownClient(reason: nil)
                self.pendingClients.values.forEach { $0.close() }
                self.pendingClients.removeAll()
                self.server?.stop()
                self.server = nil
                self.timer?.cancel()
                self.timer = nil
                if self.reconfigurationRegistered {
                    CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
                    self.reconfigurationRegistered = false
                }
                self.running = false
                self.stats = StreamStats()
                self.publish()
                Task {
                    await capturer?.stop()
                    continuation.resume()
                }
            }
        }
    }

    // MARK: Connection handling (queue)

    /// New connections stay pending until their hello arrives; only then may they replace
    /// the current client (see `promote`).
    private func accept(_ connection: NWConnection) {
        let pending = ClientConnection(connection: connection, queue: queue)
        let key = ObjectIdentifier(pending)
        pendingClients[key] = pending
        pending.onMessage = { [weak self, weak pending] type, payload in
            guard let self, let pending else { return }
            self.route(pending, type: type, payload: payload)
        }
        pending.onClose = { [weak self] _ in self?.pendingClients[key] = nil }
        pending.start()
        event("Connection from \(pending.endpointDescription)")

        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let stale = self.pendingClients.removeValue(forKey: key) else { return }
            self.event("\(stale.endpointDescription) sent no hello within 5 s; closing")
            stale.close()
        }
    }

    private func route(_ connection: ClientConnection, type: UInt8, payload: Data) {
        if connection === client {
            handle(type: type, payload: payload, generation: generation)
            return
        }
        let key = ObjectIdentifier(connection)
        guard pendingClients[key] != nil, MessageType(rawValue: type) == .clientHello else { return }
        pendingClients[key] = nil
        guard let hello = try? JSONDecoder().decode(ClientHello.self, from: payload) else {
            event("Malformed client hello from \(connection.endpointDescription); closing")
            connection.close()
            return
        }
        guard hello.protocolVersion == WireProtocol.version else {
            event("Client protocol \(hello.protocolVersion) ≠ host protocol \(WireProtocol.version); closing")
            connection.close()
            return
        }
        promote(connection, hello: hello)
    }

    /// Makes `connection` the streaming client. If another client is active, it is replaced only
    /// when it is the same device reconnecting (same clientId), it has stopped answering pings, or
    /// the newcomer asks to take over (`ClientHello.takeOver`, a connection the user started);
    /// otherwise the newcomer receives `hostBusy` and is closed.
    private func promote(_ connection: ClientConnection, hello: ClientHello) {
        guard !displayLost, DisplayInspector.isOnline(displayID) else {
            markDisplayLost()
            connection.send(Wire.message(.hostBusy, Data("The Mac's virtual display is not available".utf8)))
            queue.asyncAfter(deadline: .now() + 0.5) { connection.close() }
            return
        }
        if client != nil, let current = clientHello {
            let sameDevice = hello.clientId != nil && hello.clientId == current.clientId
            let silent = Self.now() - lastPongAt > 3
            let takeOver = hello.takeOver == true
            guard sameDevice || silent || takeOver else {
                event("Rejected \(hello.deviceName): already streaming to \(current.deviceName)")
                connection.send(Wire.message(.hostBusy, Data("Streaming to \(current.deviceName)".utf8)))
                queue.asyncAfter(deadline: .now() + 0.5) { connection.close() }
                return
            }
            event(sameDevice ? "\(hello.deviceName) reconnected; replacing its old connection"
                  : silent ? "\(current.deviceName) stopped responding; switching to \(hello.deviceName)"
                  : "\(hello.deviceName) took over the stream from \(current.deviceName)")
            if let old = teardownClient(reason: nil) { Task { await old.stop() } }
        }
        generation += 1
        let gen = generation
        connection.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload, generation: gen) }
        connection.onClose = { [weak self] error in self?.clientClosed(generation: gen, error: error) }
        client = connection
        clientHello = hello
        stats.clientAddress = connection.endpointDescription
        lastPongAt = Self.now()
        beginStreaming()
    }

    private func handle(type: UInt8, payload: Data, generation gen: Int) {
        guard gen == generation, client != nil else { return }
        switch MessageType(rawValue: type) {
        case .clientHello:
            return

        case .pong:
            guard let sent = Wire.readU64(payload) else { return }
            let rtt = Self.now() - Double(sent) / 1_000_000
            if rtt >= 0 { rttSeconds = rttSeconds.map { $0 * 0.8 + rtt * 0.2 } ?? rtt }
            lastPongAt = Self.now()

        case .frameRendered:
            guard let pts = Wire.readU64(payload) else { return }
            counters.rendered += tracker.acknowledge(pts: pts)
            let ageMs = (Self.now() - Double(pts) / 1_000_000) * 1000
            latency.add(ageMs - (rttSeconds ?? 0) * 500)

        case .keyframeRequest:
            event("Client requested a keyframe")
            forceKeyframe = true
            tracker.reset()
            encodeLastFrame()

        case .pointer, .scroll, .key:
            guard let message = InputMessage.decode(type: type, payload: payload) else { return }
            inject(message)

        default:
            break
        }
    }

    private func beginStreaming() {
        guard let hello = clientHello, let client else { return }
        let codec: VideoCodec = hello.codecs.contains(options.codec.rawValue) ? options.codec : .h264
        let size = currentStreamSize(codec: codec)
        bitrate.reset()
        do {
            try makeEncoder(codec: codec, size: size)
        } catch {
            fail("Encoder: \(error.localizedDescription)")
            if let old = teardownClient(reason: nil) { Task { await old.stop() } }
            return
        }
        let config = VideoConfig(codec: codec, width: size.width, height: size.height, fps: options.fps)
        video = config
        inputAuthorized = inputEnabled && InputToken.matches(hello.inputToken, inputToken)
        stats.inputAuthorized = inputAuthorized
        if inputEnabled && !inputAuthorized {
            event(hello.inputToken == nil ? "Client has no input token; view-only" : "Client input token rejected; view-only")
        }
        do {
            client.send(try Wire.json(.hostHello, HostHello(protocolVersion: WireProtocol.version, displayName: displayName, video: config, inputEnabled: inputAuthorized)))
        } catch {
            fail("hello encode: \(error)")
            return
        }
        forceKeyframe = true
        tracker.reset()
        latency.reset()
        rttSeconds = nil
        stats.state = .streaming
        stats.clientName = hello.deviceName
        stats.video = config
        stats.clientSessions += 1
        event("Streaming \(codec.rawValue) \(size) @ \(options.fps) fps to \(hello.deviceName) (screen \(hello.screenWidth)×\(hello.screenHeight))")
        startCapture(size: size)
        publish()
    }

    private func clientClosed(generation gen: Int, error: Error?) {
        guard gen == generation, client != nil else { return }
        event("Client disconnected" + (error.map { ": \($0)" } ?? ""))
        if let old = teardownClient(reason: nil) { Task { await old.stop() } }
    }

    /// Resets per-client state. Returns the capturer so the caller can stop it asynchronously.
    @discardableResult
    private func teardownClient(reason: String?) -> DisplayCapturer? {
        let old = client
        client = nil
        old?.onClose = nil
        old?.close()
        clientHello = nil
        video = nil
        injector?.releaseAll()
        injector = nil
        inputAuthorized = false
        stats.inputAuthorized = false
        encoder?.invalidate()
        encoder = nil
        lastPixelBuffer = nil
        tracker.reset()
        latency.reset()
        rttSeconds = nil
        let capturer = self.capturer
        self.capturer = nil
        if running {
            stats.state = .listening
            stats.clientName = nil
            stats.clientAddress = nil
            stats.video = nil
            publish()
        }
        return capturer
    }

    // MARK: Capture and encode (queue)

    private func currentStreamSize(codec: VideoCodec) -> PixelSize {
        let mode = CGDisplayCopyDisplayMode(displayID)
        let display = PixelSize(width: mode?.pixelWidth ?? CGDisplayPixelsWide(displayID), height: mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID))
        let client = options.matchClientResolution ? clientHello.map { PixelSize(width: $0.screenWidth, height: $0.screenHeight) } : nil
        return StreamGeometry.streamSize(display: display, client: client, cap: options.maxStreamSize,
                                         decoder: clientHello?.decoderLimit(for: codec))
    }

    private func makeEncoder(codec: VideoCodec, size: PixelSize) throws {
        encoder?.invalidate()
        encoder = nil
        let gen = generation
        let settings = VideoEncoder.Settings(codec: codec, width: size.width, height: size.height, fps: options.fps, bitrate: bitrate.current)
        let encoder = try VideoEncoder(
            settings: settings,
            onOutput: { [weak self] frame in self?.queue.async { self?.sendEncoded(frame, generation: gen) } },
            onError: { [weak self] status in self?.queue.async { self?.encoderFailed(status, generation: gen) } }
        )
        self.encoder = encoder
        stats.hardwareEncoder = encoder.isHardware
        stats.lowLatencyRateControl = encoder.isLowLatency
        stats.targetKbps = bitrate.current / 1000
    }

    private func startCapture(size: PixelSize) {
        let gen = generation
        let capturer = DisplayCapturer(
            displayID: displayID, queue: queue,
            onFrame: { [weak self] buffer, pts in self?.captured(buffer, pts: pts, generation: gen) },
            onStop: { [weak self] error in self?.queue.async { self?.captureStopped(error, generation: gen) } }
        )
        self.capturer = capturer
        let fps = options.fps
        Task { [weak self] in
            do {
                try await capturer.start(size: size, fps: fps)
            } catch {
                self?.queue.async {
                    guard let self, self.generation == gen else { return }
                    if !DisplayCapturer.hasPermission {
                        self.fail(StreamError.screenRecordingDenied.localizedDescription)
                    } else if !DisplayInspector.isOnline(self.displayID) || (error as? StreamError) == .displayNotCapturable(self.displayID) {
                        self.markDisplayLost()
                    } else {
                        self.event("Capture failed to start: \(error.localizedDescription)")
                    }
                    if let old = self.teardownClient(reason: nil) { Task { await old.stop() } }
                }
            }
        }
    }

    private func captured(_ pixelBuffer: CVPixelBuffer, pts: CMTime, generation gen: Int) {
        guard gen == generation else { return }
        counters.captured += 1
        lastPixelBuffer = pixelBuffer
        guard client != nil, video != nil, let encoder else { return }
        captureSequence += 1
        scheduleIdleRefresh(after: captureSequence, generation: gen)
        let now = Self.now()
        if tracker.expireStale(now: now) {
            event("No render acknowledgements for \(tracker.staleTimeout) s; resetting flow control")
            forceKeyframe = true
        }
        if !forceKeyframe, tracker.shouldThrottle(now: now) {
            counters.skipped += 1
            bitrate.recordCongestion()
            return
        }
        encode(pixelBuffer, pts: pts, with: encoder)
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, with encoder: VideoEncoder) {
        let keyframe = forceKeyframe
        forceKeyframe = false
        do {
            try encoder.encode(pixelBuffer, pts: pts, forceKeyframe: keyframe)
        } catch {
            encoderFailed((error as? StreamError).flatMap { if case .encodeFailed(let s) = $0 { return s } else { return nil } } ?? -1, generation: generation)
        }
    }

    /// Re-encodes the most recent capture (used when a keyframe is needed on an idle screen).
    private func encodeLastFrame() {
        guard let pixelBuffer = lastPixelBuffer, let encoder, client != nil else { return }
        encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()), with: encoder)
    }

    /// ScreenCaptureKit only delivers frames when the screen changes. When it goes quiet, the
    /// newest image may not have reached the phone: it may have been throttled, or the decoder
    /// may hold one frame until the next input arrives. Once the screen has been idle for
    /// `idleRefreshDelay`, the latest image is encoded one more time.
    private func scheduleIdleRefresh(after sequence: Int, generation gen: Int) {
        queue.asyncAfter(deadline: .now() + Self.idleRefreshDelay) { [weak self] in
            guard let self, gen == self.generation, sequence == self.captureSequence,
                  let pixelBuffer = self.lastPixelBuffer, let encoder = self.encoder, self.client != nil else { return }
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            self.refreshPTSMicros = UInt64(max(0, pts.seconds * 1_000_000))
            self.encode(pixelBuffer, pts: pts, with: encoder)
        }
    }

    private func sendEncoded(_ frame: EncodedFrame, generation gen: Int) {
        guard gen == generation, let client else { return }
        client.send(frame.message)
        if let refresh = refreshPTSMicros, frame.ptsMicros >= refresh &- 1, frame.ptsMicros <= refresh &+ 1 {
            // Idle refresh: not tracked, so a decoder that holds it back does not look like a stall.
            refreshPTSMicros = nil
            counters.sent += 1
            counters.bytes += frame.message.count
            stats.totalFramesSent += 1
            return
        }
        tracker.sent(pts: frame.ptsMicros, at: Self.now())
        counters.sent += 1
        counters.bytes += frame.message.count
        stats.totalFramesSent += 1
        if frame.isKeyframe { stats.totalKeyframes += 1 }
    }

    private func encoderFailed(_ status: OSStatus, generation gen: Int) {
        guard gen == generation, let video else { return }
        event("Encoder error \(status); recreating encoder")
        do {
            try makeEncoder(codec: video.codec, size: PixelSize(width: video.width, height: video.height))
            forceKeyframe = true
            tracker.reset()
            encodeLastFrame()
        } catch {
            fail("Encoder could not be recreated: \(error.localizedDescription)")
            if let old = teardownClient(reason: nil) { Task { await old.stop() } }
        }
    }

    private func captureStopped(_ error: Error, generation gen: Int) {
        guard gen == generation, client != nil, let video else { return }
        event("Capture stopped (\(error.localizedDescription)); restarting in 1 s")
        capturer = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == gen, self.client != nil, self.capturer == nil else { return }
            self.forceKeyframe = true
            self.startCapture(size: PixelSize(width: video.width, height: video.height))
        }
    }

    // MARK: Input (queue)

    private func inject(_ message: InputMessage) {
        guard inputAuthorized else { return }
        guard InputPermission.isTrusted else {
            if !warnedNoAccessibility {
                warnedNoAccessibility = true
                event("Input received but Accessibility permission is not granted; events dropped")
            }
            return
        }
        let injector = self.injector ?? InputInjector(displayID: displayID)
        self.injector = injector
        counters.input += 1
        switch message {
        case let .pointer(action, buttonRaw, clickCount, relative, atCursor, x, y):
            let button = MouseButton(rawValue: buttonRaw) ?? .left
            let nx: Double? = atCursor ? nil : x, ny: Double? = atCursor ? nil : y
            switch action {
            case .move:
                if relative { injector.move(byNormalizedX: x, y: y) } else { injector.move(toNormalizedX: x, y: y) }
            case .down:
                injector.down(button, normalizedX: nx, y: ny, clickCount: max(1, clickCount))
            case .up:
                injector.up(button, normalizedX: nx, y: ny, clickCount: max(1, clickCount))
            }
        case let .scroll(dx, dy):
            injector.scroll(normalizedX: dx, y: dy)
        case let .key(down, keyCode, metaState, unicode):
            guard !KeyMap.modifierKeyCodes.contains(keyCode) else { return }
            injector.key(down: down, keyCode: KeyMap.androidToMac[keyCode], unicode: unicode, flags: KeyMap.flags(androidMetaState: metaState))
        }
    }

    // MARK: Display reconfiguration (queue)

    /// The display was removed (by macOS, the user, or the owning process). Clients are told the
    /// display is unavailable; `onDisplayLost` lets the owner recreate it.
    private func markDisplayLost() {
        guard !displayLost else { return }
        displayLost = true
        if let old = teardownClient(reason: nil) { Task { await old.stop() } }
        fail("Virtual display \(displayID) is no longer available")
        DispatchQueue.main.async { [weak self] in self?.onDisplayLost?() }
    }

    fileprivate func displayWasRemoved() {
        queue.async { [weak self] in self?.markDisplayLost() }
    }

    fileprivate func displayDidReconfigure() {
        queue.async { [weak self] in
            guard let self, !self.reconfigurePending else { return }
            self.reconfigurePending = true
            // Debounce: a mode change produces several callbacks.
            self.queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.reconfigurePending = false
                self?.applyReconfiguration()
            }
        }
    }

    private func applyReconfiguration() {
        guard let client, let current = video else { return }
        let size = currentStreamSize(codec: current.codec)
        guard size.width != current.width || size.height != current.height else { return }
        event("Display changed; stream \(current.width)×\(current.height) → \(size)")
        do {
            try makeEncoder(codec: current.codec, size: size)
        } catch {
            fail("Encoder for new size: \(error.localizedDescription)")
            return
        }
        let config = VideoConfig(codec: current.codec, width: size.width, height: size.height, fps: options.fps)
        video = config
        stats.video = config
        if let message = try? Wire.json(.videoConfig, config) { client.send(message) }
        forceKeyframe = true
        tracker.reset()
        lastPixelBuffer = nil
        if let capturer {
            let fps = options.fps
            Task { try? await capturer.update(size: size, fps: fps) }
        }
        publish()
    }

    // MARK: Timer, stats (queue)

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        lastTick = Self.now()
    }

    private func tick() {
        let now = Self.now()
        let elapsed = max(0.001, now - lastTick)
        lastTick = now

        if let client {
            if clientHello != nil, now - lastPongAt > 5 {
                event("Client unresponsive for 5 s; dropping connection")
                if let old = teardownClient(reason: nil) { Task { await old.stop() } }
            } else {
                client.send(Wire.u64(.ping, UInt64(now * 1_000_000)))
            }
        }
        if video != nil, let rate = bitrate.tick(now: now) {
            encoder?.setBitrate(rate)
        }

        stats.captureFPS = Double(counters.captured) / elapsed
        stats.sentFPS = Double(counters.sent) / elapsed
        stats.skippedFPS = Double(counters.skipped) / elapsed
        stats.renderedFPS = Double(counters.rendered) / elapsed
        stats.sentKbps = Double(counters.bytes) * 8 / 1000 / elapsed
        stats.targetKbps = bitrate.current / 1000
        stats.inFlight = tracker.count
        stats.rttMs = rttSeconds.map { $0 * 1000 }
        stats.latencyMs = latency.median
        stats.latencyP95Ms = latency.p95
        stats.inputEventsPerSecond = Double(counters.input) / elapsed
        stats.accessibilityTrusted = InputPermission.isTrusted
        counters = Counters()
        publish()
    }

    private func publish() {
        let snapshot = stats
        DispatchQueue.main.async { [weak self] in self?.onStats?(snapshot) }
    }

    private func event(_ message: String) {
        log.info("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onEvent?(message) }
    }

    private func fail(_ message: String) {
        stats.state = .failed(message)
        event(message)
        publish()
    }

    /// Host clock in seconds (same clock as ScreenCaptureKit presentation timestamps).
    static func now() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}

private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    let session = Unmanaged<StreamSession>.fromOpaque(userInfo).takeUnretainedValue()
    guard display == session.displayID else { return }
    if flags.contains(.removeFlag) {
        session.displayWasRemoved()
    } else {
        session.displayDidReconfigure()
    }
}
