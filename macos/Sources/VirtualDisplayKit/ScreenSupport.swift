import AppKit
import CoreGraphics

/// Bridges CoreGraphics display IDs to AppKit screens and windows.
@MainActor
public enum ScreenSupport {
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    public static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    /// Waits until AppKit lists a screen for `id`. AppKit refreshes `NSScreen.screens` from the
    /// main run loop, so the caller must not block the main thread.
    public static func waitForScreen(_ id: CGDirectDisplayID, timeout: TimeInterval = 5) async -> NSScreen? {
        _ = await VirtualDisplayManager.waitUntil(timeout: timeout) { screen(for: id) != nil }
        return screen(for: id)
    }

    /// Opens a titled, movable window centred on `screen`. It is an ordinary app window,
    /// so the user can drag it between the Mac screen and the virtual display.
    @discardableResult
    public static func showTestWindow(on screen: NSScreen, title: String = "DroidScreen test window") -> NSWindow {
        let size = NSSize(width: min(480, screen.visibleFrame.width * 0.8), height: min(240, screen.visibleFrame.height * 0.6))
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = title
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "This window is on display \(displayID(of: screen) ?? 0).\nDrag it between screens.")
        label.alignment = .center
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
        return window
    }
}
