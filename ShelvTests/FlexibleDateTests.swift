import XCTest

final class FlexibleDateTests: XCTestCase {
    func testDecodesISODateWithFractionalSeconds() throws {
        let raw = "2024-01-02T03:04:05.678Z"

        let decoded = try decodeDate(from: #"{"date":"\#(raw)"}"#)

        XCTAssertEqual(
            try XCTUnwrap(decoded).timeIntervalSince1970,
            try XCTUnwrap(fractionalISOFormatter.date(from: raw)).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testDecodesISODateWithoutFractionalSeconds() throws {
        let raw = "2024-01-02T03:04:05Z"

        let decoded = try decodeDate(from: #"{"date":"\#(raw)"}"#)

        XCTAssertEqual(
            try XCTUnwrap(decoded).timeIntervalSince1970,
            try XCTUnwrap(isoFormatter.date(from: raw)).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testDecodesDateUsingDecoderStrategyBeforeStringFallback() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decodeDate(from: #"{"date":1704164645}"#, decoder: decoder)

        XCTAssertEqual(try XCTUnwrap(decoded).timeIntervalSince1970, 1_704_164_645, accuracy: 0.001)
    }

    func testEmptyOrMissingDateReturnsNil() throws {
        XCTAssertNil(try decodeDate(from: #"{"date":""}"#))
        XCTAssertNil(try decodeDate(from: #"{}"#))
    }
}

private struct FlexibleDateProbe: Decodable {
    let date: Date?

    enum CodingKeys: String, CodingKey {
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = FlexibleDate.decode(container, .date)
    }
}

private func decodeDate(from json: String, decoder: JSONDecoder = JSONDecoder()) throws -> Date? {
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try decoder.decode(FlexibleDateProbe.self, from: data).date
}

private let fractionalISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoFormatter = ISO8601DateFormatter()
