import CGVirtualDisplayBridge
import CoreGraphics
import Foundation
import os

let log = Logger(subsystem: "com.droidscreen.host", category: "VirtualDisplay")

/// Owns the lifecycle of one DroidScreen virtual display.
///
/// Create → macOS registers a new monitor (System Settings › Displays lists it) →
/// `remove()` or process exit → macOS removes it.
@MainActor
public final class VirtualDisplayManager {
    public struct ActiveDisplay: Sendable {
        public let displayID: CGDirectDisplayID
        public let configuration: VirtualDisplayConfiguration
        public let createdAt: Date
        /// Mode macOS is using right after creation.
        public let appliedMode: DisplayModeInfo?
        /// Non-fatal problems during setup (e.g. could not un-mirror).
        public let warnings: [String]
    }

    public private(set) var active: ActiveDisplay?
    private var backing: DSVirtualDisplay?

    /// Called when WindowServer removes the display without `remove()` being called.
    public var onUnexpectedTermination: ((CGDirectDisplayID) -> Void)?

    public init() {}

    public static var isAPIAvailable: Bool { DSVirtualDisplay.isAPIAvailable() }
    public static var apiAvailabilityReport: String { DSVirtualDisplay.apiAvailabilityReport() }

    /// Creates the virtual display and waits until macOS reports it online.
    ///
    /// If macOS registers the display but never brings it online, the identity
    /// (vendor/product/serial) is retried with a fresh serial number up to `serialFallbacks`
    /// times. This was observed on macOS 27.2: after a session in which the display was removed
    /// unexpectedly, WindowServer stopped bringing that one identity online, while new
    /// identities worked. `ActiveDisplay.configuration.serialNumber` reports the serial used.
    public func create(
        _ configuration: VirtualDisplayConfiguration,
        appearanceTimeout: TimeInterval = 5,
        serialFallbacks: Int = 2
    ) async throws -> ActiveDisplay {
        if let active { throw VirtualDisplayError.alreadyActive(active.displayID) }
        try configuration.validate()
        guard Self.isAPIAvailable else {
            throw VirtualDisplayError.apiUnavailable(Self.apiAvailabilityReport)
        }

        var configuration = configuration
        var warnings: [String] = []
        var lastID: CGDirectDisplayID = 0
        var online: DSVirtualDisplay?
        for attempt in 0...max(0, serialFallbacks) {
            if attempt > 0 {
                let previous = configuration.serialNumber
                configuration.serialNumber = Self.freshSerial(excluding: previous)
                warnings.append("macOS did not bring the display with serial \(previous) online; using serial \(configuration.serialNumber).")
                log.error("display serial \(previous) did not come online; retrying with serial \(configuration.serialNumber)")
            }
            let candidate = try register(configuration)
            lastID = candidate.displayID
            backing = candidate
            log.info("virtual display \(lastID) (serial \(configuration.serialNumber)) registered; waiting for it to come online")
            if await Self.waitUntil(timeout: appearanceTimeout, { DisplayInspector.isOnline(candidate.displayID) }) {
                online = candidate
                break
            }
            candidate.invalidate()
            backing = nil
        }
        guard let display = online else { throw VirtualDisplayError.displayDidNotAppear(lastID) }
        let id = display.displayID

        // The display goes online before WindowServer publishes its mode list; CoreGraphics
        // returns no current mode and an empty mode list for a short time. Wait for both.
        let modesReady = await Self.waitUntil(timeout: appearanceTimeout) {
            CGDisplayCopyDisplayMode(id) != nil && !DisplayInspector.availableModes(id).isEmpty
        }
        if !modesReady { log.error("display \(id) online but no modes published yet") }

        do {
            if try DisplayConfigurator.ensureExtended(id) {
                log.info("display \(id) was mirrored; switched to extended")
            }
        } catch {
            warnings.append("Could not switch to extended mode: \(error.localizedDescription)")
        }

        var applied = CGDisplayCopyDisplayMode(id).map(DisplayModeInfo.init)
        do {
            applied = try DisplayConfigurator.applyMode(
                id,
                pixelSize: configuration.resolution,
                preferHiDPI: configuration.hiDPI,
                refreshRate: configuration.refreshRates.max()
            )
        } catch {
            warnings.append("Could not select \(configuration.resolution): \(error.localizedDescription)")
        }

        let result = ActiveDisplay(displayID: id, configuration: configuration, createdAt: Date(), appliedMode: applied, warnings: warnings)
        active = result
        log.info("virtual display \(id) online, mode \(applied?.description ?? "unknown", privacy: .public)")
        return result
    }

    /// Registers a display with WindowServer (not yet waiting for it to come online).
    private func register(_ configuration: VirtualDisplayConfiguration) throws -> DSVirtualDisplay {
        let descriptor = DSVirtualDisplayDescriptor()
        descriptor.name = configuration.name
        descriptor.maxPixelsWide = UInt32(configuration.maxPixels.width)
        descriptor.maxPixelsHigh = UInt32(configuration.maxPixels.height)
        descriptor.sizeInMillimeters = configuration.physicalSizeMillimeters
        descriptor.vendorID = VirtualDisplayConfiguration.droidScreenVendorID
        descriptor.productID = VirtualDisplayConfiguration.droidScreenProductID
        descriptor.serialNumber = configuration.serialNumber

        let display: DSVirtualDisplay
        do {
            display = try DSVirtualDisplay(descriptor: descriptor, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.handleTermination() }
            }
        } catch {
            log.error("create failed: \(error.localizedDescription, privacy: .public)")
            throw VirtualDisplayError.creationFailed(error.localizedDescription)
        }
        let modes = configuration.modes.map {
            DSVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: $0.refreshRate)
        }
        do {
            try display.apply(modes, hiDPI: configuration.hiDPI)
        } catch {
            display.invalidate()
            log.error("applyModes failed: \(error.localizedDescription, privacy: .public)")
            throw VirtualDisplayError.applySettingsFailed(error.localizedDescription)
        }
        return display
    }

    static func freshSerial(excluding old: UInt32) -> UInt32 {
        var serial: UInt32
        repeat { serial = UInt32.random(in: 1000...0x00FF_FFFF) } while serial == old
        return serial
    }

    /// Removes the display. Returns true once macOS reports it offline.
    @discardableResult
    public func remove(disappearanceTimeout: TimeInterval = 5) async -> Bool {
        guard let backing else { return true }
        let id = backing.displayID
        backing.invalidate()
        self.backing = nil
        active = nil
        log.info("virtual display \(id) released")
        return await Self.waitUntil(timeout: disappearanceTimeout) { !DisplayInspector.isOnline(id) }
    }

    private func handleTermination() {
        guard let active else { return }
        log.error("WindowServer terminated virtual display \(active.displayID)")
        backing = nil
        self.active = nil
        onUnexpectedTermination?(active.displayID)
    }

    static func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval = 0.05, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}
