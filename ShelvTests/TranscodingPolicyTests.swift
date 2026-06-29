import XCTest

final class TranscodingPolicyTests: XCTestCase {
    func testExtensionForKnownAudioMimeTypes() {
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "audio/mpeg"), "mp3")
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "AUDIO/MP3"), "mp3")
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "audio/x-m4a"), "m4a")
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "audio/x-opus+ogg"), "opus")
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "application/ogg"), "opus")
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "audio/x-flac"), "flac")
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "audio/x-wav"), "wav")
        XCTAssertEqual(TranscodingPolicy.extensionFor(mimeType: "audio/webm"), "webm")
    }

    func testExtensionForUnknownOrMissingMimeTypeReturnsNil() {
        XCTAssertNil(TranscodingPolicy.extensionFor(mimeType: nil))
        XCTAssertNil(TranscodingPolicy.extensionFor(mimeType: "application/json"))
    }

    func testCodecFileExtensionsMatchExpectedContainerExtensions() {
        XCTAssertEqual(TranscodingCodec.raw.fileExtension, "")
        XCTAssertEqual(TranscodingCodec.opus.fileExtension, "opus")
        XCTAssertEqual(TranscodingCodec.mp3.fileExtension, "mp3")
        XCTAssertEqual(TranscodingCodec.aac.fileExtension, "m4a")
    }
}
