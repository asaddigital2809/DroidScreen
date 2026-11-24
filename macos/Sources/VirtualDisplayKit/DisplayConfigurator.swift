import CoreGraphics
import Foundation

/// Picks the best CoreGraphics mode for a requested pixel size. Pure logic (unit-tested).
public enum DisplayModeMatcher {
    /// Returns the index of the best candidate, or nil if none has the requested pixel size.
    /// Preference order: exact pixel size → HiDPI flag matches `preferHiDPI` → usable for GUI
    /// → refresh rate closest to `refreshRate` (or highest, if nil).
    public static func bestMatch(
        in candidates: [DisplayModeInfo],
        pixelSize: PixelSize,
        preferHiDPI: Bool,
        refreshRate: Double?
    ) -> Int? {
        let matching = candidates.indices.filter {
            candidates[$0].pixelWidth == pixelSize.width && candidates[$0].pixelHeight == pixelSize.height
        }
        return matching.min { a, b in
            score(candidates[a], preferHiDPI, refreshRate) < score(candidates[b], preferHiDPI, refreshRate)
        }
    }

    /// Lower is better. Tuple comparison gives lexicographic priority.
    private static func score(_ mode: DisplayModeInfo, _ preferHiDPI: Bool, _ refreshRate: Double?) -> (Int, Int, Double) {
        let hiDPIPenalty = mode.isHiDPI == preferHiDPI ? 0 : 1
        let usablePenalty = mode.isUsableForDesktopGUI ? 0 : 1
        let ratePenalty = refreshRate.map { abs(mode.refreshRate - $0) } ?? -mode.refreshRate
        return (hiDPIPenalty, usablePenalty, ratePenalty)
    }
}

/// Changes display configuration through the public CoreGraphics configuration API.
/// Changes are applied `.forSession` so they never overwrite the user's saved preferences.
public enum DisplayConfigurator {
    /// Makes sure `id` is an independent extended desktop: if it mirrors another display, or
    /// another display mirrors it, the mirroring is removed.
    /// - Returns: true if a change was made.
    @discardableResult
    public static func ensureExtended(_ id: CGDirectDisplayID) throws -> Bool {
        var toUnmirror: [CGDirectDisplayID] = []
        if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { toUnmirror.append(id) }
        for other in DisplayInspector.onlineDisplayIDs() where other != id && CGDisplayMirrorsDisplay(other) == id {
            toUnmirror.append(other)
        }
        guard !toUnmirror.isEmpty else { return false }
        try transaction("CGConfigureDisplayMirrorOfDisplay") { config in
            for display in toUnmirror {
                let result = CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)
                if result != .success { return result }
            }
            return .success
        }
        return true
    }

    /// Switches the display to the mode best matching `pixelSize`.
    /// - Returns: The mode that was applied.
    @discardableResult
    public static func applyMode(
        _ id: CGDirectDisplayID,
        pixelSize: PixelSize,
        preferHiDPI: Bool,
        refreshRate: Double?
    ) throws -> DisplayModeInfo {
        let raw = DisplayInspector.rawModes(id)
        let infos = raw.map(DisplayModeInfo.init)
        guard let index = DisplayModeMatcher.bestMatch(in: infos, pixelSize: pixelSize, preferHiDPI: preferHiDPI, refreshRate: refreshRate) else {
            throw VirtualDisplayError.noMatchingMode("\(pixelSize) not among \(infos.map(\.description))")
        }
        if let current = CGDisplayCopyDisplayMode(id).map(DisplayModeInfo.init), current == infos[index] {
            return current
        }
        try transaction("CGConfigureDisplayWithDisplayMode") { config in
            CGConfigureDisplayWithDisplayMode(config, id, raw[index], nil)
        }
        return infos[index]
    }

    private static func transaction(_ operation: String, _ body: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            throw VirtualDisplayError.displayConfigurationFailed(operation: "CGBeginDisplayConfiguration", code: begin.rawValue)
        }
        let result = body(config)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            throw VirtualDisplayError.displayConfigurationFailed(operation: operation, code: result.rawValue)
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        guard complete == .success else {
            throw VirtualDisplayError.displayConfigurationFailed(operation: "CGCompleteDisplayConfiguration", code: complete.rawValue)
        }
    }
}
