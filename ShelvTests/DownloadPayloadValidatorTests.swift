import XCTest

final class DownloadPayloadValidatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvDownloadPayloadValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testAcceptsValidWaveWithGenericBinaryMime() async throws {
        let url = tempDir.appendingPathComponent("valid.wav")
        let data = silentWaveData()
        try data.write(to: url)

        let result = try await DownloadPayloadValidator.validate(
            fileURL: url,
            byteSize: Int64(data.count),
            statusCode: 200,
            mimeType: "application/octet-stream",
            fallbackFileExtension: "mp3"
        )

        XCTAssertEqual(result.fileExtension, "wav")
        XCTAssertEqual(result.contentType, "application/octet-stream")
    }

    func testRejectsHTTPErrorBeforeCommittingDownload() async throws {
        let url = tempDir.appendingPathComponent("server-error.wav")
        try silentWaveData().write(to: url)

        await assertValidationError(.httpStatus(500)) {
            _ = try await DownloadPayloadValidator.validate(
                fileURL: url,
                byteSize: 1,
                statusCode: 500,
                mimeType: "audio/wav",
                fallbackFileExtension: "wav"
            )
        }
    }

    func testRejectsHTMLPayload() async throws {
        let url = tempDir.appendingPathComponent("error.html")
        let data = Data("<html>not logged in</html>".utf8)
        try data.write(to: url)

        await assertValidationError(.rejectedMime("text/html")) {
            _ = try await DownloadPayloadValidator.validate(
                fileURL: url,
                byteSize: Int64(data.count),
                statusCode: 200,
                mimeType: "text/html; charset=utf-8",
                fallbackFileExtension: "mp3"
            )
        }
    }

    func testRejectsEmptyPayload() async throws {
        let url = tempDir.appendingPathComponent("empty.mp3")
        try Data().write(to: url)

        await assertValidationError(.emptyFile) {
            _ = try await DownloadPayloadValidator.validate(
                fileURL: url,
                byteSize: 0,
                statusCode: 200,
                mimeType: "audio/mpeg",
                fallbackFileExtension: "mp3"
            )
        }
    }

    private func assertValidationError(_ expected: DownloadPayloadValidationError,
                                       operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as DownloadPayloadValidationError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected \(expected), got \(error)")
        }
    }

    private func silentWaveData(sampleCount: UInt32 = 800) -> Data {
        let channelCount: UInt16 = 1
        let sampleRate: UInt32 = 8_000
        let bitsPerSample: UInt16 = 16
        let blockAlign = channelCount * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = sampleCount * UInt32(blockAlign)

        var data = Data()
        appendASCII("RIFF", to: &data)
        appendUInt32LE(36 + dataSize, to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(channelCount, to: &data)
        appendUInt32LE(sampleRate, to: &data)
        appendUInt32LE(byteRate, to: &data)
        appendUInt16LE(blockAlign, to: &data)
        appendUInt16LE(bitsPerSample, to: &data)
        appendASCII("data", to: &data)
        appendUInt32LE(dataSize, to: &data)
        data.append(Data(count: Int(dataSize)))
        return data
    }

    private func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
