import XCTest

final class AlphabetIndexSelectionTests: XCTestCase {
    func testMapsPositionsAndClampsOutsideBounds() {
        XCTAssertEqual(
            AlphabetIndexSelection.index(
                yPosition: 0,
                itemHeight: 10,
                itemCount: 3
            ),
            0
        )
        XCTAssertEqual(
            AlphabetIndexSelection.index(
                yPosition: 19.9,
                itemHeight: 10,
                itemCount: 3
            ),
            1
        )
        XCTAssertEqual(
            AlphabetIndexSelection.index(
                yPosition: -100,
                itemHeight: 10,
                itemCount: 3
            ),
            0
        )
        XCTAssertEqual(
            AlphabetIndexSelection.index(
                yPosition: 100,
                itemHeight: 10,
                itemCount: 3
            ),
            2
        )
    }

    func testRejectsInvalidGeometryAndEmptyIndexes() {
        XCTAssertNil(
            AlphabetIndexSelection.index(
                yPosition: .nan,
                itemHeight: 10,
                itemCount: 3
            )
        )
        XCTAssertNil(
            AlphabetIndexSelection.index(
                yPosition: .infinity,
                itemHeight: 10,
                itemCount: 3
            )
        )
        XCTAssertNil(
            AlphabetIndexSelection.index(
                yPosition: 10,
                itemHeight: 0,
                itemCount: 3
            )
        )
        XCTAssertNil(
            AlphabetIndexSelection.index(
                yPosition: 10,
                itemHeight: 10,
                itemCount: 0
            )
        )
    }
}
