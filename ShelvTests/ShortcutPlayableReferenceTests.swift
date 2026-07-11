import XCTest

final class ShortcutPlayableReferenceTests: XCTestCase {
    func testIdentifierRoundTripsUnicodeAndReservedCharacters() {
        let reference = ShortcutPlayableReference(
            serverConfigID: "server-123",
            kind: .album,
            contentID: "Mercury/Deluxe|版本+ä"
        )

        XCTAssertEqual(ShortcutPlayableReference(identifier: reference.identifier), reference)
        XCTAssertEqual(reference.identifier.split(separator: "|").count, 3)
    }

    func testIdentifierKeepsExistingEncodingFormat() {
        let reference = ShortcutPlayableReference(
            serverConfigID: "server-123",
            kind: .song,
            contentID: "track-42"
        )

        XCTAssertEqual(reference.identifier, "server-123|song|dHJhY2stNDI")
    }

    func testRejectsMalformedIdentifiers() {
        XCTAssertNil(ShortcutPlayableReference(identifier: "missing-components"))
        XCTAssertNil(ShortcutPlayableReference(identifier: "server|unknown|dHJhY2s"))
        XCTAssertNil(ShortcutPlayableReference(identifier: "server|song|%%%"))
    }
}
