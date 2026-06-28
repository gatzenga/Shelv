import XCTest
@testable import Shelv

final class URLQueryParamTests: XCTestCase {
    func testReturnsRequestedQueryParameter() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/stream?id=song-1&format=opus&bitRate=192"))

        XCTAssertEqual(url.queryParam("format"), "opus")
        XCTAssertEqual(url.queryParam("bitRate"), "192")
    }

    func testReturnsNilWhenParameterIsMissing() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/stream?id=song-1"))

        XCTAssertNil(url.queryParam("format"))
    }

    func testDecodesPercentEscapedValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/stream?title=Hello%20World"))

        XCTAssertEqual(url.queryParam("title"), "Hello World")
    }
}
