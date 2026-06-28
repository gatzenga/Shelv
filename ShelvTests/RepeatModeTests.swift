import XCTest
@testable import Shelv

final class RepeatModeTests: XCTestCase {
    func testToggledCyclesThroughAllModes() {
        XCTAssertEqual(RepeatMode.off.toggled, .all)
        XCTAssertEqual(RepeatMode.all.toggled, .one)
        XCTAssertEqual(RepeatMode.one.toggled, .off)
    }

    func testSystemImageMatchesRepeatMode() {
        XCTAssertEqual(RepeatMode.off.systemImage, "repeat")
        XCTAssertEqual(RepeatMode.all.systemImage, "repeat")
        XCTAssertEqual(RepeatMode.one.systemImage, "repeat.1")
    }

    func testRawValuesRoundTripForPersistence() {
        for mode in [RepeatMode.off, .all, .one] {
            XCTAssertEqual(RepeatMode(rawValue: mode.rawValue), mode)
        }
    }
}
