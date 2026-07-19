import Foundation
import XCTest

final class SubsonicRequestCompatibilityTests: XCTestCase {
    func testCurrentRequestsPreserveNavidromeAndOpenSubsonicFormat() {
        let compatibility = SubsonicRequestCompatibility.current

        XCTAssertEqual(compatibility.endpointPath(for: "getAlbum"), "getAlbum")
        XCTAssertEqual(compatibility.apiVersion, "1.16.1")
    }

    func testNotFoundRetriesHistoricalViewSuffixWithoutChangingVersion() throws {
        let retry = try XCTUnwrap(
            SubsonicRequestCompatibility.current.retrying(
                afterHTTPStatus: 404,
                responseData: Data()
            )
        )

        XCTAssertEqual(retry.endpointPath(for: "getAlbum"), "getAlbum.view")
        XCTAssertEqual(retry.endpointPath(for: "getAlbum.view"), "getAlbum.view")
        XCTAssertEqual(retry.apiVersion, "1.16.1")
        XCTAssertNil(SubsonicRequestCompatibility.current.retrying(afterHTTPStatus: 401))

        let authenticationFailure = Data(#"""
        {
          "subsonic-response": {
            "status": "failed",
            "version": "1.16.1",
            "error": { "code": 40 }
          }
        }
        """#.utf8)
        XCTAssertNil(
            SubsonicRequestCompatibility.current.retrying(
                afterHTTPStatus: 200,
                responseData: authenticationFailure
            )
        )
    }

    func testOlderServerResponseSelectsAdvertisedSupportedVersion() throws {
        let response = Data(#"""
        {
          "subsonic-response": {
            "status": "failed",
            "version": "1.15.0",
            "error": { "code": 30, "message": "Server must upgrade" }
          }
        }
        """#.utf8)
        let retry = try XCTUnwrap(
            SubsonicRequestCompatibility.current.retrying(
                afterHTTPStatus: 200,
                responseData: response
            )
        )

        XCTAssertEqual(retry.endpointPath(for: "getSong"), "getSong")
        XCTAssertEqual(retry.apiVersion, "1.15.0")
    }

    func testVersionFallbackNeverUsesPreTokenAuthentication() throws {
        let oldServerResponse = Data(#"""
        {
          "subsonic-response": {
            "status": "failed",
            "version": "1.12.0",
            "error": { "code": 30 }
          }
        }
        """#.utf8)
        let fallback = try XCTUnwrap(
            SubsonicRequestCompatibility.current.retrying(
                afterHTTPStatus: 200,
                responseData: oldServerResponse
            )
        )
        XCTAssertEqual(fallback.apiVersion, "1.13.0")

        let upgradedServerResponse = Data(#"""
        {
          "subsonic-response": {
            "status": "failed",
            "version": "1.16.1",
            "error": { "code": 20 }
          }
        }
        """#.utf8)
        let restored = try XCTUnwrap(
            fallback.retrying(
                afterHTTPStatus: 200,
                responseData: upgradedServerResponse
            )
        )
        XCTAssertEqual(restored.apiVersion, "1.16.1")
    }
}
