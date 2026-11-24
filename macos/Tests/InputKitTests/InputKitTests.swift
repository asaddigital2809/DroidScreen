import CoreGraphics
import XCTest
@testable import InputKit

final class DisplayCoordinateMapperTests: XCTestCase {
    // Virtual display at x = 1920, right of a 1920×1080 main display, 1200×540 points.
    let mapper = DisplayCoordinateMapper(bounds: CGRect(x: 1920, y: 0, width: 1200, height: 540))

    func testCornersAndCentre() {
        XCTAssertEqual(mapper.point(normalizedX: 0, y: 0), CGPoint(x: 1920, y: 0))
        XCTAssertEqual(mapper.point(normalizedX: 0.5, y: 0.5), CGPoint(x: 2520, y: 270))
        // Bottom-right stays inside the display.
        XCTAssertEqual(mapper.point(normalizedX: 1, y: 1), CGPoint(x: 3119, y: 539))
    }

    func testOutOfRangeIsClamped() {
        XCTAssertEqual(mapper.point(normalizedX: -0.2, y: 1.7), CGPoint(x: 1920, y: 539))
        XCTAssertEqual(mapper.clamp(CGPoint(x: 0, y: 9999)), CGPoint(x: 1920, y: 539))
    }

    func testDeltaScalesToPoints() {
        XCTAssertEqual(mapper.delta(normalizedX: 0.1, y: -0.5), CGVector(dx: 120, dy: -270))
    }
}

final class KeyMapTests: XCTestCase {
    func testLettersDigitsAndNamedKeys() {
        XCTAssertEqual(KeyMap.androidToMac[29], 0x00)  // A
        XCTAssertEqual(KeyMap.androidToMac[31], 0x08)  // C
        XCTAssertEqual(KeyMap.androidToMac[54], 0x06)  // Z
        XCTAssertEqual(KeyMap.androidToMac[7], 0x1D)   // 0
        XCTAssertEqual(KeyMap.androidToMac[16], 0x19)  // 9
        XCTAssertEqual(KeyMap.androidToMac[66], 0x24)  // Enter
        XCTAssertEqual(KeyMap.androidToMac[67], 0x33)  // Backspace
        XCTAssertEqual(KeyMap.androidToMac[142], 0x6F) // F12
        XCTAssertNil(KeyMap.androidToMac[1000])
    }

    func testModifierFlags() {
        let flags = KeyMap.flags(androidMetaState: 0x1 | 0x10000)
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertFalse(flags.contains(.maskControl))
        XCTAssertEqual(KeyMap.flags(androidMetaState: 0x1002), [.maskControl, .maskAlternate])
    }
}
