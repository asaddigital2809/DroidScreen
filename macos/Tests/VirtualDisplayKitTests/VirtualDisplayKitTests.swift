import XCTest
@testable import VirtualDisplayKit

final class VirtualDisplayConfigurationTests: XCTestCase {
    func testPresetsAreValid() throws {
        for preset in VirtualDisplayConfiguration.presets {
            XCTAssertNoThrow(try preset.configuration.validate(), preset.name)
        }
    }

    func testModesPrimaryFirstHighestRateFirstNoDuplicates() {
        let config = VirtualDisplayConfiguration(
            resolution: PixelSize(width: 2400, height: 1080),
            additionalResolutions: [PixelSize(width: 1280, height: 720), PixelSize(width: 2400, height: 1080)],
            refreshRates: [30, 60, 30]
        )
        XCTAssertEqual(config.modes.map(\.description), [
            "2400×1080@60Hz", "2400×1080@30Hz", "1280×720@60Hz", "1280×720@30Hz",
        ])
    }

    func testMaxPixelsCoversAllResolutions() {
        let config = VirtualDisplayConfiguration(
            resolution: PixelSize(width: 2400, height: 1080),
            additionalResolutions: [PixelSize(width: 1920, height: 1200)]
        )
        XCTAssertEqual(config.maxPixels, PixelSize(width: 2400, height: 1200))
    }

    func testPhysicalSizeMatchesDiagonalAndAspect() {
        let config = VirtualDisplayConfiguration(resolution: PixelSize(width: 1600, height: 1200), diagonalInches: 10)
        // 4:3 at 10" → 8" × 6" = 203.2 mm × 152.4 mm
        XCTAssertEqual(config.physicalSizeMillimeters.width, 203.2, accuracy: 0.01)
        XCTAssertEqual(config.physicalSizeMillimeters.height, 152.4, accuracy: 0.01)
    }

    func testValidationRejectsBadInput() {
        var c = VirtualDisplayConfiguration.fullHD
        c.resolution = PixelSize(width: 1921, height: 1080)
        XCTAssertThrowsError(try c.validate())
        c = .fullHD; c.resolution = PixelSize(width: 100, height: 100)
        XCTAssertThrowsError(try c.validate())
        c = .fullHD; c.refreshRates = []
        XCTAssertThrowsError(try c.validate())
        c = .fullHD; c.refreshRates = [500]
        XCTAssertThrowsError(try c.validate())
        c = .fullHD; c.name = "  "
        XCTAssertThrowsError(try c.validate())
    }

    func testPixelSizeParsing() {
        XCTAssertEqual(PixelSize(parsing: "2400x1080"), PixelSize(width: 2400, height: 1080))
        XCTAssertEqual(PixelSize(parsing: "1280×720"), PixelSize(width: 1280, height: 720))
        XCTAssertNil(PixelSize(parsing: "abc"))
    }
}

final class DisplayModeMatcherTests: XCTestCase {
    let modes = [
        DisplayModeInfo(width: 2400, height: 1080, pixelWidth: 2400, pixelHeight: 1080, refreshRate: 60),
        DisplayModeInfo(width: 1200, height: 540, pixelWidth: 2400, pixelHeight: 1080, refreshRate: 30),
        DisplayModeInfo(width: 1200, height: 540, pixelWidth: 2400, pixelHeight: 1080, refreshRate: 60),
        DisplayModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60),
    ]

    func testPrefersHiDPIAndClosestRate() {
        let i = DisplayModeMatcher.bestMatch(in: modes, pixelSize: PixelSize(width: 2400, height: 1080), preferHiDPI: true, refreshRate: 60)
        XCTAssertEqual(i, 2)
    }

    func testPrefersNonHiDPIWhenAsked() {
        let i = DisplayModeMatcher.bestMatch(in: modes, pixelSize: PixelSize(width: 2400, height: 1080), preferHiDPI: false, refreshRate: 30)
        XCTAssertEqual(i, 0)
    }

    func testHighestRateWhenNoneRequested() {
        let i = DisplayModeMatcher.bestMatch(in: modes, pixelSize: PixelSize(width: 2400, height: 1080), preferHiDPI: true, refreshRate: nil)
        XCTAssertEqual(i, 2)
    }

    func testNilWhenNoPixelMatch() {
        XCTAssertNil(DisplayModeMatcher.bestMatch(in: modes, pixelSize: PixelSize(width: 3840, height: 2160), preferHiDPI: true, refreshRate: 60))
    }
}

final class PhysicalDisplayTests: XCTestCase {
    func testSystemPlaceholderIsRecognised() {
        // Values from the WindowServer log: "v: 0x756e6b6e m: 0x76697274".
        XCTAssertTrue(DisplayInspector.isSystemPlaceholder(vendor: 0x756E6B6E, model: 0x76697274))
        XCTAssertFalse(DisplayInspector.isSystemPlaceholder(vendor: 0x10AC, model: 0x4099)) // DELL P2314H
        XCTAssertFalse(DisplayInspector.isSystemPlaceholder(vendor: VirtualDisplayConfiguration.droidScreenVendorID,
                                                            model: VirtualDisplayConfiguration.droidScreenProductID))
    }
}
