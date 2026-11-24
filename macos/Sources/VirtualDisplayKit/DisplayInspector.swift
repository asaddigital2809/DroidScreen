import CoreGraphics
import Foundation

/// A CoreGraphics display mode reduced to plain values (testable without a real display).
public struct DisplayModeInfo: Hashable, Sendable, CustomStringConvertible {
    /// Size in points (the "looks like" size).
    public var width: Int
    public var height: Int
    /// Size of the backing framebuffer in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var isUsableForDesktopGUI: Bool

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, isUsableForDesktopGUI: Bool = true) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isUsableForDesktopGUI = isUsableForDesktopGUI
    }

    init(_ mode: CGDisplayMode) {
        self.init(
            width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate, isUsableForDesktopGUI: mode.isUsableForDesktopGUI()
        )
    }

    public var isHiDPI: Bool { pixelWidth > width }

    public var description: String {
        let hz = refreshRate > 0 ? "@\(Int(refreshRate.rounded()))Hz" : ""
        return isHiDPI
            ? "\(width)×\(height) pt (HiDPI, \(pixelWidth)×\(pixelHeight) px)\(hz)"
            : "\(width)×\(height)\(hz)"
    }
}

/// Point-in-time state of one display as macOS sees it.
public struct DisplaySnapshot: Sendable, Identifiable {
    public var id: CGDirectDisplayID
    public var isOnline: Bool
    public var isActive: Bool
    public var isMain: Bool
    public var isBuiltin: Bool
    /// True when the display is part of a mirror set (i.e. NOT an independent extended desktop).
    public var isInMirrorSet: Bool
    /// The display this one mirrors, or `kCGNullDirectDisplay`.
    public var mirrorsDisplay: CGDirectDisplayID
    /// Position and size in the global desktop coordinate space (points).
    public var bounds: CGRect
    public var currentMode: DisplayModeInfo?
    public var vendorNumber: UInt32
    public var modelNumber: UInt32
    public var serialNumber: UInt32

    public var isDroidScreen: Bool {
        vendorNumber == VirtualDisplayConfiguration.droidScreenVendorID
            && modelNumber == VirtualDisplayConfiguration.droidScreenProductID
    }

    /// The stand-in display macOS adds when the last monitor is unplugged
    /// (vendor 'unkn' 0x756E6B6E, model 'virt' 0x76697274, 1920×1080). It is not a real screen.
    public var isSystemPlaceholder: Bool {
        DisplayInspector.isSystemPlaceholder(vendor: vendorNumber, model: modelNumber)
    }

    /// Extended (independent) desktop = online, active, not mirroring/mirrored, non-empty bounds.
    public var isExtendedDesktop: Bool {
        isOnline && isActive && !isInMirrorSet && !bounds.isEmpty
    }
}

/// Read-only queries against CoreGraphics' display list. All functions are public CG API.
public enum DisplayInspector {
    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        id != kCGNullDirectDisplay && onlineDisplayIDs().contains(id)
    }

    public static func snapshot(_ id: CGDirectDisplayID) -> DisplaySnapshot {
        let mode = CGDisplayCopyDisplayMode(id).map(DisplayModeInfo.init)
        return DisplaySnapshot(
            id: id,
            isOnline: isOnline(id),
            isActive: CGDisplayIsActive(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isInMirrorSet: CGDisplayIsInMirrorSet(id) != 0,
            mirrorsDisplay: CGDisplayMirrorsDisplay(id),
            bounds: CGDisplayBounds(id),
            currentMode: mode,
            vendorNumber: CGDisplayVendorNumber(id),
            modelNumber: CGDisplayModelNumber(id),
            serialNumber: CGDisplaySerialNumber(id)
        )
    }

    /// Online displays that are neither DroidScreen virtual displays (vendor/product ID check) nor
    /// the placeholder macOS adds when no monitor is connected (`isSystemPlaceholder`).
    /// The host's auto-stream mode treats an empty result as "no physical display connected".
    /// A display that is asleep is still online and counts here.
    public static func physicalDisplayIDs() -> [CGDirectDisplayID] {
        allDisplays().filter { !$0.isDroidScreen && !$0.isSystemPlaceholder }.map(\.id)
    }

    /// Vendor 'unkn' (0x756E6B6E) + model 'virt' (0x76697274): the placeholder display macOS
    /// creates when the last monitor is disconnected (observed on macOS 27.2, Apple M4).
    public static func isSystemPlaceholder(vendor: UInt32, model: UInt32) -> Bool {
        vendor == 0x756E_6B6E && model == 0x7669_7274
    }

    public static func allDisplays() -> [DisplaySnapshot] {
        onlineDisplayIDs().map(snapshot)
    }

    /// Every mode macOS exposes for the display, including HiDPI duplicates.
    public static func availableModes(_ id: CGDirectDisplayID) -> [DisplayModeInfo] {
        rawModes(id).map(DisplayModeInfo.init)
    }

    static func rawModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }
}
