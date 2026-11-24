import AppKit
import CoreGraphics

/// Automated Milestone 1 acceptance check. Creates a display, verifies with public macOS APIs
/// that it behaves as an independent monitor, places a window on it, then removes it.
@MainActor
public enum VirtualDisplaySelfTest {
    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public struct Report: Sendable {
        public var checks: [Check] = []
        public var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    }

    /// - Parameters:
    ///   - holdSeconds: How long to keep the display (and test window) up before removing it,
    ///     so a person can look at System Settings › Displays. 0 = remove immediately.
    ///   - progress: Called with each check as it completes.
    public static func run(
        configuration: VirtualDisplayConfiguration,
        holdSeconds: TimeInterval = 0,
        progress: (Check) -> Void = { _ in }
    ) async -> Report {
        var report = Report()
        func record(_ name: String, _ passed: Bool, _ detail: String) {
            let check = Check(name: name, passed: passed, detail: detail)
            report.checks.append(check)
            progress(check)
        }

        let apiOK = VirtualDisplayManager.isAPIAvailable
        record("CGVirtualDisplay API present", apiOK, VirtualDisplayManager.apiAvailabilityReport.replacingOccurrences(of: "\n", with: "; "))
        guard apiOK else { return report }

        let before = Set(DisplayInspector.onlineDisplayIDs())
        let manager = VirtualDisplayManager()
        let active: VirtualDisplayManager.ActiveDisplay
        do {
            active = try await manager.create(configuration)
        } catch {
            record("Virtual display created", false, error.localizedDescription)
            return report
        }
        let id = active.displayID
        record("Virtual display created", true, "display ID \(id)" + (active.warnings.isEmpty ? "" : "; warnings: \(active.warnings.joined(separator: "; "))"))

        let snap = DisplayInspector.snapshot(id)
        record("New display ID in online display list", snap.isOnline && !before.contains(id), "online IDs: \(DisplayInspector.onlineDisplayIDs())")
        record("Display is active (drawable)", snap.isActive, "CGDisplayIsActive=\(snap.isActive)")
        record("Identity is DroidScreen", snap.isDroidScreen, String(format: "vendor=0x%04X model=0x%04X serial=%u", snap.vendorNumber, snap.modelNumber, snap.serialNumber))
        record("Extended, not mirrored", !snap.isInMirrorSet && snap.mirrorsDisplay == kCGNullDirectDisplay, "inMirrorSet=\(snap.isInMirrorSet) mirrors=\(snap.mirrorsDisplay)")

        let others = DisplayInspector.allDisplays().filter { $0.id != id && $0.isActive && !$0.isInMirrorSet }
        let overlaps = others.contains { $0.bounds.intersects(snap.bounds) }
        record("Own region of the global desktop", !snap.bounds.isEmpty && !overlaps, "bounds=\(snap.bounds)")

        let modes = DisplayInspector.availableModes(id)
        let wanted = configuration.resolution
        record("Requested resolution offered", modes.contains { $0.pixelWidth == wanted.width && $0.pixelHeight == wanted.height },
               "current=\(snap.currentMode?.description ?? "none"); modes=\(modes.map(\.description))")

        let screen = await ScreenSupport.waitForScreen(id)
        record("AppKit lists it as an NSScreen", screen != nil, screen.map { "frame=\($0.frame) scale=\($0.backingScaleFactor)" } ?? "not found")

        if let screen {
            let window = ScreenSupport.showTestWindow(on: screen, title: "DroidScreen self-test")
            _ = await VirtualDisplayManager.waitUntil(timeout: 2) { window.screen.flatMap(ScreenSupport.displayID) == id }
            let onScreen = window.screen.flatMap(ScreenSupport.displayID)
            record("Window can be placed on it", onScreen == id, "window.screen=\(onScreen.map(String.init) ?? "nil") frame=\(window.frame)")
            if holdSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000)) }
            window.close()
        }

        let removed = await manager.remove()
        record("Display removed cleanly", removed && !DisplayInspector.isOnline(id), "online IDs after removal: \(DisplayInspector.onlineDisplayIDs())")
        return report
    }
}
