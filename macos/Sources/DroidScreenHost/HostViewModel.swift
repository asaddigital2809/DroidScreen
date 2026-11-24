import AppKit
import Combine
import InputKit
import StreamKit
import VirtualDisplayKit
import os

/// State and actions for the host window (Milestones 1–2).
@MainActor
final class HostViewModel: ObservableObject {
    // Virtual display
    @Published var presetIndex = 0 { didSet { configuration = VirtualDisplayConfiguration.presets[presetIndex].configuration } }
    @Published var configuration = VirtualDisplayConfiguration.presets[0].configuration
    @Published private(set) var active: VirtualDisplayManager.ActiveDisplay?
    @Published private(set) var snapshot: DisplaySnapshot?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var selfTestLines: [String] = []

    // Streaming
    @Published var codec: VideoCodec = .h264
    @Published var fps = 60
    @Published var maxBitrateMbps = 20
    @Published var allowLAN = false
    @Published private(set) var streamStats = StreamStats()
    @Published private(set) var streamEvents: [String] = []
    @Published private(set) var screenRecordingGranted = ScreenCapturePermission.isGranted
    @Published private(set) var accessibilityGranted = InputPermission.isTrusted
    @Published var touchInputEnabled = true {
        didSet { session?.setInputEnabled(touchInputEnabled) }
    }
    var isStreaming: Bool { session != nil }

    // Automation
    /// Start DroidScreen when the user logs in (`SMAppService.mainApp`).
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published private(set) var launchAtLoginNeedsApproval = LoginItem.needsApproval
    /// Start streaming automatically (USB + Wi-Fi/LAN with Bonjour) while no physical display
    /// is connected. Stored in UserDefaults key `autoStreamWhenNoDisplay`.
    @Published var autoStreamWhenNoDisplay = UserDefaults.standard.bool(forKey: "autoStreamWhenNoDisplay") {
        didSet {
            UserDefaults.standard.set(autoStreamWhenNoDisplay, forKey: "autoStreamWhenNoDisplay")
            if !autoStreamWhenNoDisplay { autoStreamSuppressed = false }
            scheduleAutoStreamCheck(delay: 0)
        }
    }
    /// True while the current stream was started by the auto-stream mode.
    @Published private(set) var autoStreamActive = false

    let apiAvailable = VirtualDisplayManager.isAPIAvailable
    let apiReport = VirtualDisplayManager.apiAvailabilityReport

    private let manager = VirtualDisplayManager()
    private var session: StreamSession?
    private var testWindows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var lastStatsLog = Date.distantPast
    /// Stored in UserDefaults key `inputToken` and reused across launches, so a phone that
    /// received it once (over USB or typed in) keeps touch input after a restart or over Wi-Fi.
    private var inputTokenForRun = HostViewModel.storedInputToken()
    private var usbWasSetUp = false
    private var recovering = false
    private let statsLog = Logger(subsystem: "com.droidscreen.host", category: "Stats")
    /// Diagnostics events, also written to the system log (category `Host`, level notice):
    /// `log show --predicate 'subsystem == "com.droidscreen.host"' --last 1h`
    private let eventLog = Logger(subsystem: "com.droidscreen.host", category: "Host")
    private var autoStreamCheck: Task<Void, Never>?
    private var autoUSBTask: Task<Void, Never>?
    /// The user stopped an auto-started stream; do not restart it until a physical display returns.
    private var autoStreamSuppressed = false
    /// `allowLAN` before auto-stream switched it on; restored when auto-stream ends.
    private var allowLANBeforeAuto: Bool?

    init() {
        manager.onUnexpectedTermination = { [weak self] id in
            guard let self else { return }
            self.active = nil
            self.snapshot = nil
            self.message = "macOS removed virtual display \(id)."
            Task { await self.stopStreaming() }
        }
        // Refresh status whenever the display arrangement changes (user moves it, changes mode…).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleAutoStreamCheck()
            }
        }
    }

    // MARK: Virtual display

    func create() {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            await createDisplay()
        }
    }

    private func createDisplay() async {
        do {
            // Reuse the serial that last came online so macOS keeps the user's arrangement.
            var configuration = self.configuration
            let savedSerial = UserDefaults.standard.integer(forKey: "displaySerial")
            if savedSerial > 0 { configuration.serialNumber = UInt32(savedSerial) }
            let result = try await manager.create(configuration)
            UserDefaults.standard.set(Int(result.configuration.serialNumber), forKey: "displaySerial")
            active = result
            message = result.warnings.isEmpty ? "Display created. Open System Settings › Displays to arrange it." : result.warnings.joined(separator: "\n")
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func remove() {
        guard !busy else { return }
        busy = true
        closeTestWindows()
        Task {
            defer { busy = false }
            await stopStreaming()
            let removed = await manager.remove()
            active = nil
            snapshot = nil
            message = removed ? "Display removed." : "Display released, but macOS still lists it."
        }
    }

    func refresh() {
        if let id = active?.displayID, !DisplayInspector.isOnline(id) {
            // Re-check shortly: a display can briefly drop out during reconfiguration.
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let current = active?.displayID, current == id, !DisplayInspector.isOnline(id) { recoverLostDisplay() }
            }
        }
        snapshot = active.map { DisplayInspector.snapshot($0.displayID) }
        screenRecordingGranted = ScreenCapturePermission.isGranted
        accessibilityGranted = InputPermission.isTrusted
    }

    func requestAccessibility() {
        accessibilityGranted = InputPermission.request()
        if !accessibilityGranted {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            message = "Enable DroidScreen under Privacy & Security › Accessibility. Touch input starts working right away."
        }
    }

    /// The virtual display disappeared (macOS removed it). Recreate it and, if we were
    /// streaming, restart the server with the same input token and redo the USB setup.
    private func recoverLostDisplay() {
        guard !recovering else { return }
        recovering = true
        let wasStreaming = session != nil
        received(event: "Virtual display disappeared; recreating it")
        Task {
            defer { recovering = false }
            await stopStreaming()
            await manager.remove(disappearanceTimeout: 1)
            active = nil
            snapshot = nil
            await createDisplay()
            guard active != nil else { return }
            if wasStreaming {
                busy = false
                startStreaming()
                if usbWasSetUp {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    setUpUSB()
                }
            }
            message = "The virtual display was recreated" + (wasStreaming ? " and streaming restarted." : ".")
        }
    }

    func showTestWindow() {
        guard let id = active?.displayID, let screen = ScreenSupport.screen(for: id) else {
            message = "The virtual display is not available to AppKit yet."
            return
        }
        testWindows.append(ScreenSupport.showTestWindow(on: screen))
    }

    func openDisplaySettings() {
        open("x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }

    func runSelfTest() {
        guard !busy, active == nil else {
            message = "Remove the current display before running the self-test."
            return
        }
        busy = true
        selfTestLines = []
        Task {
            defer { busy = false }
            let report = await VirtualDisplaySelfTest.run(configuration: configuration) { [weak self] check in
                self?.selfTestLines.append("\(check.passed ? "✅" : "❌") \(check.name) — \(check.detail)")
            }
            selfTestLines.append(report.passed ? "RESULT: PASS" : "RESULT: FAIL")
        }
    }

    /// Replaces the stored input code. Phones must receive the new code (USB setup or typing it).
    /// Takes effect the next time streaming starts.
    func regenerateInputToken() {
        inputTokenForRun = InputToken.generate()
        UserDefaults.standard.set(inputTokenForRun, forKey: "inputToken")
        message = "New input code created. It is used the next time streaming starts."
    }

    private static func storedInputToken() -> String {
        if let token = UserDefaults.standard.string(forKey: "inputToken"), token.count == 32 { return token }
        let token = InputToken.generate()
        UserDefaults.standard.set(token, forKey: "inputToken")
        return token
    }

    // MARK: Streaming

    func requestScreenRecording() {
        screenRecordingGranted = ScreenCapturePermission.ensure()
        if !screenRecordingGranted {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            message = "Enable DroidScreen under Screen & System Audio Recording, then quit and reopen DroidScreen."
        }
    }

    /// Creates the display if needed, then starts the TCP server. Capture begins when a client connects.
    func startStreaming() {
        guard !busy, session == nil else { return }
        guard ScreenCapturePermission.ensure() else {
            screenRecordingGranted = false
            requestScreenRecording()
            return
        }
        screenRecordingGranted = true
        busy = true
        Task {
            defer { busy = false }
            if active == nil { await createDisplay() }
            guard let active else { return }
            var options = StreamOptions()
            options.codec = codec
            options.fps = fps
            options.maxBitrate = maxBitrateMbps * 1_000_000
            options.minBitrate = min(2, maxBitrateMbps) * 1_000_000
            options.allowLAN = allowLAN
            options.inputEnabled = touchInputEnabled
            options.inputToken = inputTokenForRun
            options.bonjourName = Host.current().localizedName
            if touchInputEnabled && !InputPermission.isTrusted { requestAccessibility() }
            let session = StreamSession(displayID: active.displayID, displayName: configuration.name, options: options)
            session.onStats = { [weak self] stats in self?.received(stats) }
            session.onEvent = { [weak self] event in self?.received(event: event) }
            session.onDisplayLost = { [weak self] in self?.recoverLostDisplay() }
            do {
                try session.start()
                self.session = session
                streamEvents = []
                message = allowLAN
                    ? "Streaming server listening on all interfaces (unencrypted)."
                    : "Streaming server listening on 127.0.0.1. Connect a phone over USB with “Set up USB”."
            } catch {
                message = "Could not start the stream server: \(error.localizedDescription)"
            }
        }
    }

    func stopStreaming() async {
        guard let session else { return }
        self.session = nil
        await session.stop()
        streamStats = StreamStats()
    }

    func stopStreamingClicked() {
        if autoStreamActive {
            autoStreamSuppressed = true
            endAutoStream(removeDisplay: false)
        }
        Task { await stopStreaming() }
    }

    func setUpUSB() {
        let port = session?.options.port ?? WireProtocol.defaultPort
        let token = touchInputEnabled ? session?.inputToken : nil
        usbWasSetUp = true
        Task {
            let results = await Task.detached { AdbBridge.setUpReceivers(port: port, inputToken: token, takeOver: true) }.value
            if results.isEmpty {
                message = AdbBridge.locateADB() == nil
                    ? "adb not found. Install Android platform-tools."
                    : "No authorised USB device. Enable USB debugging on the phone and accept the prompt."
            } else {
                message = results.map { "\($0.serial): \($0.succeeded ? "USB ready, receiver started (127.0.0.1:\(port))" : "failed – \($0.output)")" }.joined(separator: "\n")
            }
        }
    }

    /// Shown for manual entry on the phone (Wi-Fi) until QR pairing exists.
    var inputToken: String? { session?.inputToken }

    private func received(_ stats: StreamStats) {
        streamStats = stats
        accessibilityGranted = stats.accessibilityTrusted || InputPermission.isTrusted
        if stats.state == .streaming, Date().timeIntervalSince(lastStatsLog) >= 5 {
            lastStatsLog = Date()
            statsLog.info("\(stats.summary, privacy: .public)")
        }
    }

    private func received(event: String) {
        eventLog.notice("\(event, privacy: .public)")
        streamEvents.append(event)
        if streamEvents.count > 50 { streamEvents.removeFirst(streamEvents.count - 50) }
    }

    // MARK: Launch automation

    /// `open DroidScreen.app --args -autoServe YES [-codec hevc] [-fps 30] [-bitrateMbps 10] [-preset 1]`
    /// creates the display and starts the server at launch. Used for unattended testing.
    func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if let preset = defaults.object(forKey: "preset") as? Int, VirtualDisplayConfiguration.presets.indices.contains(preset) { presetIndex = preset }
        if let codec = defaults.string(forKey: "codec").flatMap(VideoCodec.init(rawValue:)) { self.codec = codec }
        if defaults.integer(forKey: "fps") > 0 { fps = defaults.integer(forKey: "fps") }
        if defaults.integer(forKey: "bitrateMbps") > 0 { maxBitrateMbps = defaults.integer(forKey: "bitrateMbps") }
        if defaults.object(forKey: "touchInput") != nil { touchInputEnabled = defaults.bool(forKey: "touchInput") }
        defer { scheduleAutoStreamCheck(delay: 1) }
        if defaults.bool(forKey: "autoServe") {
            startStreaming()
            // -autoUSB YES: also run the adb setup once the server is up.
            if defaults.bool(forKey: "autoUSB") {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    setUpUSB()
                }
            }
        }
    }

    // MARK: Start at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            message = "Could not \(enabled ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
        launchAtLoginNeedsApproval = LoginItem.needsApproval
        if launchAtLoginNeedsApproval {
            message = "Approve DroidScreen in System Settings › General › Login Items."
            LoginItem.openSettings()
        }
    }

    func openLoginItemsSettings() {
        LoginItem.openSettings()
    }

    // MARK: Auto-stream when no physical display is connected

    /// Re-evaluates auto-stream after display changes settle (`delay` seconds, default 2 s).
    func scheduleAutoStreamCheck(delay: Double = 2) {
        autoStreamCheck?.cancel()
        autoStreamCheck = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.evaluateAutoStream()
        }
    }

    /// No physical display + mode on → create the virtual display, listen on USB and LAN
    /// (Bonjour-advertised) and set up USB phones automatically.
    /// A physical display returns → stop the auto-started stream and remove the virtual display.
    private func evaluateAutoStream() {
        let physical = DisplayInspector.physicalDisplayIDs()
        if autoStreamWhenNoDisplay {
            eventLog.notice("Auto-stream check: \(physical.count, privacy: .public) physical display(s), active \(self.autoStreamActive, privacy: .public), streaming \(self.session != nil, privacy: .public)")
        }
        if !physical.isEmpty {
            autoStreamSuppressed = false
            if autoStreamActive {
                received(event: "Physical display connected; stopping automatic streaming")
                endAutoStream(removeDisplay: true)
            }
            return
        }
        guard autoStreamWhenNoDisplay, !autoStreamSuppressed, !autoStreamActive, !recovering, apiAvailable else { return }
        guard !busy else {
            scheduleAutoStreamCheck()
            return
        }
        if session == nil {
            received(event: "No physical display connected; starting automatic streaming")
            allowLANBeforeAuto = allowLAN
            allowLAN = true
            startStreaming()
            guard busy || session != nil else {
                // startStreaming() returned early (e.g. missing Screen Recording permission).
                allowLAN = allowLANBeforeAuto ?? allowLAN
                allowLANBeforeAuto = nil
                return
            }
        }
        autoStreamActive = true
        startAutoUSB()
    }

    private func endAutoStream(removeDisplay: Bool) {
        autoStreamActive = false
        autoUSBTask?.cancel()
        autoUSBTask = nil
        if let previous = allowLANBeforeAuto {
            allowLAN = previous
            allowLANBeforeAuto = nil
        }
        if removeDisplay, !busy {
            busy = true
            closeTestWindows()
            Task {
                defer { busy = false }
                await stopStreaming()
                _ = await manager.remove()
                active = nil
                snapshot = nil
                message = "A physical display is connected. Automatic streaming stopped."
            }
        }
    }

    /// Every 3 s: runs the USB setup (`adb reverse` + start the receiver) once for each newly
    /// attached, authorised device. A device that is unplugged and plugged in again is set up again.
    private func startAutoUSB() {
        autoUSBTask?.cancel()
        autoUSBTask = Task { [weak self] in
            var configured = Set<String>()
            while !Task.isCancelled {
                guard let self else { return }
                if self.session == nil, !self.busy, !self.recovering {
                    // The auto-started stream ended (display creation failed, macOS removed the
                    // display…). Retry through the normal check.
                    self.received(event: "Automatic stream is not running; retrying in 10 s")
                    self.endAutoStream(removeDisplay: false)
                    self.scheduleAutoStreamCheck(delay: 10)
                    return
                }
                if let session = self.session {
                    let port = session.options.port
                    let token = self.touchInputEnabled ? session.inputToken : nil
                    // Emulators are skipped: they would otherwise connect and hold the stream.
                    let serials = await Task.detached { AdbBridge.devices().filter { !AdbBridge.isEmulator($0) } }.value
                    configured.formIntersection(serials)
                    for serial in serials where !configured.contains(serial) {
                        let result = await Task.detached { AdbBridge.setUpReceiver(serial: serial, port: port, inputToken: token) }.value
                        self.received(event: "USB \(serial): \(result.succeeded ? "receiver started" : "setup failed – \(result.output)")")
                        if result.succeeded {
                            configured.insert(serial)
                            self.usbWasSetUp = true
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Shutdown

    func shutdown() async {
        autoStreamCheck?.cancel()
        autoUSBTask?.cancel()
        closeTestWindows()
        await stopStreaming()
        await manager.remove(disappearanceTimeout: 1)
    }

    private func closeTestWindows() {
        testWindows.forEach { $0.close() }
        testWindows.removeAll()
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
