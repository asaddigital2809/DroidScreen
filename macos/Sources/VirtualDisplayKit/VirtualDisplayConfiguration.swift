import CoreGraphics
import Foundation

/// A width × height pair in pixels.
public struct PixelSize: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)×\(height)" }

    /// Parses "2400x1080" (also accepts "×").
    public init?(parsing text: String) {
        let parts = text.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        self.init(width: w, height: h)
    }
}

/// One mode offered to macOS for the virtual display.
public struct ModeSpec: Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public var refreshRate: Double

    public var description: String { "\(width)×\(height)@\(Int(refreshRate.rounded()))Hz" }
}

/// Everything needed to create a DroidScreen virtual display.
///
/// `resolution` and `additionalResolutions` are in **pixels** (the size of the framebuffer
/// that will later be captured and streamed). With `hiDPI` enabled macOS additionally offers
/// 2× "Retina" variants, i.e. a 2400×1080 framebuffer that "looks like" 1200×540 points.
public struct VirtualDisplayConfiguration: Hashable, Codable, Sendable {
    /// Vendor/product IDs written into the virtual display's identity ("DS" / "M1").
    /// `DisplayInspector` uses the vendor ID to recognise DroidScreen displays.
    public static let droidScreenVendorID: UInt32 = 0x4453
    public static let droidScreenProductID: UInt32 = 0x4D31

    public static let minimumSize = PixelSize(width: 640, height: 360)
    public static let maximumSize = PixelSize(width: 7680, height: 4320)
    public static let refreshRateRange: ClosedRange<Double> = 1...240
    public static let diagonalRange: ClosedRange<Double> = 1...100

    public var name: String
    public var resolution: PixelSize
    public var additionalResolutions: [PixelSize]
    public var refreshRates: [Double]
    public var hiDPI: Bool
    public var diagonalInches: Double
    public var serialNumber: UInt32

    public init(
        name: String = "DroidScreen",
        resolution: PixelSize,
        additionalResolutions: [PixelSize] = [],
        refreshRates: [Double] = [60, 30],
        hiDPI: Bool = true,
        diagonalInches: Double = 6.5,
        serialNumber: UInt32 = 1
    ) {
        self.name = name
        self.resolution = resolution
        self.additionalResolutions = additionalResolutions
        self.refreshRates = refreshRates
        self.hiDPI = hiDPI
        self.diagonalInches = diagonalInches
        self.serialNumber = serialNumber
    }

    // MARK: Presets

    /// Typical 20:9 Android phone held in landscape.
    public static let phoneLandscape = VirtualDisplayConfiguration(
        resolution: PixelSize(width: 2400, height: 1080),
        additionalResolutions: [PixelSize(width: 1920, height: 1080), PixelSize(width: 1280, height: 720)],
        diagonalInches: 6.5
    )

    /// 1080p stream target.
    public static let fullHD = VirtualDisplayConfiguration(
        resolution: PixelSize(width: 1920, height: 1080),
        additionalResolutions: [PixelSize(width: 1280, height: 720)],
        diagonalInches: 10
    )

    /// 720p stream target.
    public static let hd720 = VirtualDisplayConfiguration(
        resolution: PixelSize(width: 1280, height: 720),
        hiDPI: false,
        diagonalInches: 10
    )

    public static let presets: [(name: String, configuration: VirtualDisplayConfiguration)] = [
        ("Phone landscape (2400×1080)", .phoneLandscape),
        ("1080p (1920×1080)", .fullHD),
        ("720p (1280×720)", .hd720),
    ]

    // MARK: Derived values

    /// Primary resolution first, duplicates removed.
    public var allResolutions: [PixelSize] {
        var seen = Set<PixelSize>()
        return ([resolution] + additionalResolutions).filter { seen.insert($0).inserted }
    }

    /// Every resolution × refresh rate, primary resolution and highest refresh rate first.
    public var modes: [ModeSpec] {
        let rates = Array(Set(refreshRates)).sorted(by: >)
        return allResolutions.flatMap { size in
            rates.map { ModeSpec(width: size.width, height: size.height, refreshRate: $0) }
        }
    }

    /// Largest width and height over all resolutions (the framebuffer upper bound).
    public var maxPixels: PixelSize {
        PixelSize(
            width: allResolutions.map(\.width).max() ?? resolution.width,
            height: allResolutions.map(\.height).max() ?? resolution.height
        )
    }

    /// Physical size derived from the primary resolution's aspect ratio and `diagonalInches`.
    /// macOS uses this to compute DPI and default scaling.
    public var physicalSizeMillimeters: CGSize {
        let w = Double(resolution.width), h = Double(resolution.height)
        let diagonalPixels = (w * w + h * h).squareRoot()
        let diagonalMM = diagonalInches * 25.4
        return CGSize(width: diagonalMM * w / diagonalPixels, height: diagonalMM * h / diagonalPixels)
    }

    // MARK: Validation

    public func validate() throws {
        func fail(_ message: String) -> VirtualDisplayError { .invalidConfiguration(message) }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw fail("Name must not be empty.") }
        for size in allResolutions {
            guard (Self.minimumSize.width...Self.maximumSize.width).contains(size.width),
                  (Self.minimumSize.height...Self.maximumSize.height).contains(size.height)
            else {
                throw fail("Resolution \(size) is outside \(Self.minimumSize)…\(Self.maximumSize).")
            }
            // H.264/HEVC encoders (Milestone 2) require even dimensions.
            guard size.width % 2 == 0, size.height % 2 == 0 else {
                throw fail("Resolution \(size) must have even width and height.")
            }
        }
        if refreshRates.isEmpty { throw fail("At least one refresh rate is required.") }
        for rate in refreshRates where !Self.refreshRateRange.contains(rate) {
            throw fail("Refresh rate \(rate) is outside \(Self.refreshRateRange).")
        }
        if !Self.diagonalRange.contains(diagonalInches) {
            throw fail("Diagonal \(diagonalInches)\" is outside \(Self.diagonalRange).")
        }
    }
}
