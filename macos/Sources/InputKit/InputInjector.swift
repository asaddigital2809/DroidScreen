import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Accessibility (TCC) permission. macOS only delivers synthetic mouse/keyboard events posted
/// by a process the user has enabled under Privacy & Security › Accessibility.
public enum InputPermission {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (first time) that leads the user to the Accessibility settings.
    @discardableResult
    public static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

public enum MouseButton: UInt8, Sendable {
    case left = 0
    case right = 1
}

/// Maps normalised positions on the streamed image (0…1, origin top-left) to global display
/// coordinates of one display. Pure; unit-tested.
public struct DisplayCoordinateMapper: Sendable {
    /// Display bounds in the global Quartz coordinate space (points, origin top-left of main display).
    public var bounds: CGRect

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    public func point(normalizedX x: Double, y: Double) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        // Keep the point strictly inside the display so it is not attributed to a neighbour.
        return CGPoint(
            x: min(bounds.minX + cx * bounds.width, bounds.maxX - 1),
            y: min(bounds.minY + cy * bounds.height, bounds.maxY - 1)
        )
    }

    public func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1), y: min(max(p.y, bounds.minY), bounds.maxY - 1))
    }

    /// Converts a normalised delta (fraction of the image) to points.
    public func delta(normalizedX dx: Double, y dy: Double) -> CGVector {
        CGVector(dx: dx * bounds.width, dy: dy * bounds.height)
    }
}

/// Posts mouse, scroll and keyboard events onto one display through the HID event tap.
/// Must be used from a single serial queue.
public final class InputInjector {
    public let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var cursor: CGPoint
    private var pressed: MouseButton?
    private var scrollRemainder = CGVector.zero
    private let log = Logger(subsystem: "com.droidscreen.host", category: "Input")
    public private(set) var eventsPosted = 0

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let bounds = CGDisplayBounds(displayID)
        cursor = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private var mapper: DisplayCoordinateMapper { DisplayCoordinateMapper(bounds: CGDisplayBounds(displayID)) }

    // MARK: Pointer

    /// Moves to an absolute normalised position (direct touch).
    public func move(toNormalizedX x: Double, y: Double) {
        cursor = mapper.point(normalizedX: x, y: y)
        postMouse(dragType(default: .mouseMoved), button: pressed ?? .left)
    }

    /// Moves by a normalised delta (trackpad mode).
    public func move(byNormalizedX dx: Double, y dy: Double) {
        let m = mapper
        let d = m.delta(normalizedX: dx, y: dy)
        cursor = m.clamp(CGPoint(x: cursor.x + d.dx, y: cursor.y + d.dy))
        postMouse(dragType(default: .mouseMoved), button: pressed ?? .left)
    }

    /// Presses `button`. Position nil = current cursor (trackpad mode).
    public func down(_ button: MouseButton, normalizedX x: Double?, y: Double?, clickCount: Int) {
        if let x, let y { cursor = mapper.point(normalizedX: x, y: y) }
        if let held = pressed, held != button { up(held, normalizedX: nil, y: nil, clickCount: 1) }
        pressed = button
        postMouse(button == .left ? .leftMouseDown : .rightMouseDown, button: button, clickCount: clickCount)
    }

    public func up(_ button: MouseButton, normalizedX x: Double?, y: Double?, clickCount: Int) {
        if let x, let y { cursor = mapper.point(normalizedX: x, y: y) }
        pressed = nil
        postMouse(button == .left ? .leftMouseUp : .rightMouseUp, button: button, clickCount: clickCount)
    }

    /// Releases any held button (connection lost mid-drag).
    public func releaseAll() {
        if let held = pressed { up(held, normalizedX: nil, y: nil, clickCount: 1) }
    }

    /// Scroll by a normalised delta of the image. Positive dy = content moves down (finger moves down).
    public func scroll(normalizedX dx: Double, y dy: Double) {
        let d = mapper.delta(normalizedX: dx, y: dy)
        let total = CGVector(dx: d.dx + scrollRemainder.dx, dy: d.dy + scrollRemainder.dy)
        let wheelY = Int32(total.dy.rounded(.towardZero)), wheelX = Int32(total.dx.rounded(.towardZero))
        scrollRemainder = CGVector(dx: total.dx - Double(wheelX), dy: total.dy - Double(wheelY))
        guard wheelX != 0 || wheelY != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wheelY, wheel2: wheelX, wheel3: 0)
        else { return }
        event.location = cursor
        post(event)
    }

    // MARK: Keyboard

    /// `keyCode` nil → the character is typed with its Unicode value instead.
    public func key(down: Bool, keyCode: CGKeyCode?, unicode: UInt32, flags: CGEventFlags) {
        let code = keyCode ?? 0
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        if keyCode == nil {
            guard unicode != 0, let scalar = Unicode.Scalar(unicode) else { return }
            let utf16 = Array(String(Character(scalar)).utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        post(event)
    }

    // MARK: Posting

    private func dragType(default type: CGEventType) -> CGEventType {
        switch pressed {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case nil: return type
        }
    }

    private func postMouse(_ type: CGEventType, button: MouseButton, clickCount: Int = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursor,
                                  mouseButton: button == .left ? .left : .right) else { return }
        if clickCount > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        post(event)
    }

    private func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
        eventsPosted += 1
    }
}
