import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

nonisolated enum SubsonicResponseFormat: String, Codable, Sendable {
    case json
    case xml

    var queryValue: String { rawValue }

    var alternate: Self {
        switch self {
        case .json: return .xml
        case .xml: return .json
        }
    }
}

nonisolated enum SubsonicResponseFormatSelection: Equatable, Sendable {
    case json(allowsXMLFallback: Bool)
    case xml(shouldReprobeJSON: Bool)

    var preferredFormat: SubsonicResponseFormat {
        switch self {
        case .json: return .json
        case .xml: return .xml
        }
    }

    var fallbackFormat: SubsonicResponseFormat? {
        switch self {
        case .json(let allowsXMLFallback):
            return allowsXMLFallback ? .xml : nil
        case .xml:
            return .json
        }
    }
}

/// Persistent, endpoint-scoped response format knowledge.
///
/// JSON stays the default. XML is remembered only after it successfully
/// decoded the exact endpoint that failed as JSON. A failed XML fallback is
/// remembered too, so an incompatible response never doubles every request.
nonisolated final class SubsonicResponseFormatPreferences: @unchecked Sendable {
    static let shared = SubsonicResponseFormatPreferences()
    static let defaultJSONReprobeInterval: TimeInterval = 7 * 24 * 60 * 60

    private struct EndpointRecord: Codable, Equatable {
        enum Mode: String, Codable {
            case xmlPreferred
            case xmlRejected
        }

        var mode: Mode
        var lastJSONCheck: Date?
    }

    private struct Payload: Codable {
        var clientVersion: String
        var serverFingerprints: [String: String]
        var endpointRecords: [String: EndpointRecord]
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let clientVersion: String
    private let jsonReprobeInterval: TimeInterval
    private var payload: Payload
    private var jsonReprobesInFlight: Set<String> = []

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "shelv_subsonic_response_formats_v1",
        clientVersion: String = SubsonicResponseFormatPreferences.currentClientVersion,
        jsonReprobeInterval: TimeInterval = SubsonicResponseFormatPreferences.defaultJSONReprobeInterval
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.clientVersion = clientVersion
        self.jsonReprobeInterval = jsonReprobeInterval

        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(Payload.self, from: data),
           stored.clientVersion == clientVersion {
            payload = stored
        } else {
            payload = Payload(
                clientVersion: clientVersion,
                serverFingerprints: [:],
                endpointRecords: [:]
            )
            if let data = try? JSONEncoder().encode(payload) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }

    static var currentClientVersion: String {
        let marketing = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        let version = [marketing, build]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "|")
        return version.isEmpty ? "development" : version
    }

    func selection(
        serverKey: String,
        endpoint: String,
        now: Date = Date()
    ) -> SubsonicResponseFormatSelection {
        lock.withLock {
            guard let record = payload.endpointRecords[
                endpointKey(serverKey: serverKey, endpoint: endpoint)
            ] else {
                return .json(allowsXMLFallback: true)
            }

            switch record.mode {
            case .xmlRejected:
                return .json(allowsXMLFallback: false)
            case .xmlPreferred:
                let shouldReprobe = record.lastJSONCheck.map {
                    now.timeIntervalSince($0) >= jsonReprobeInterval
                } ?? true
                return .xml(shouldReprobeJSON: shouldReprobe)
            }
        }
    }

    func recordXMLSuccess(
        serverKey: String,
        endpoint: String,
        now: Date = Date()
    ) {
        updateRecord(
            EndpointRecord(mode: .xmlPreferred, lastJSONCheck: now),
            serverKey: serverKey,
            endpoint: endpoint
        )
    }

    func recordXMLFailure(serverKey: String, endpoint: String) {
        updateRecord(
            EndpointRecord(mode: .xmlRejected, lastJSONCheck: nil),
            serverKey: serverKey,
            endpoint: endpoint
        )
    }

    func recordJSONSuccess(serverKey: String, endpoint: String) {
        lock.withLock {
            let key = endpointKey(serverKey: serverKey, endpoint: endpoint)
            guard payload.endpointRecords.removeValue(forKey: key) != nil else { return }
            jsonReprobesInFlight.remove(key)
            persistLocked()
        }
    }

    /// Claims the infrequent background JSON re-probe. Only one caller can
    /// claim it for a server/endpoint pair at a time.
    func claimJSONReprobe(
        serverKey: String,
        endpoint: String,
        now: Date = Date()
    ) -> Bool {
        lock.withLock {
            let key = endpointKey(serverKey: serverKey, endpoint: endpoint)
            guard let record = payload.endpointRecords[key],
                  record.mode == .xmlPreferred,
                  record.lastJSONCheck.map({
                      now.timeIntervalSince($0) >= jsonReprobeInterval
                  }) ?? true,
                  jsonReprobesInFlight.insert(key).inserted else {
                return false
            }
            return true
        }
    }

    func finishJSONReprobe(
        serverKey: String,
        endpoint: String,
        decodedSuccessfully: Bool,
        receivedResponse: Bool,
        now: Date = Date()
    ) {
        lock.withLock {
            let key = endpointKey(serverKey: serverKey, endpoint: endpoint)
            jsonReprobesInFlight.remove(key)
            guard var record = payload.endpointRecords[key],
                  record.mode == .xmlPreferred else { return }

            if decodedSuccessfully {
                payload.endpointRecords.removeValue(forKey: key)
            } else if receivedResponse {
                record.lastJSONCheck = now
                payload.endpointRecords[key] = record
            }
            persistLocked()
        }
    }

    /// A changed server fingerprint invalidates every endpoint decision for
    /// that configured server. The fingerprint is optional because original
    /// Subsonic implementations do not have to expose a software build.
    func noteServerFingerprint(_ fingerprint: String?, serverKey: String) {
        guard let fingerprint = fingerprint?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !fingerprint.isEmpty else { return }

        lock.withLock {
            let previous = payload.serverFingerprints[serverKey]
            payload.serverFingerprints[serverKey] = fingerprint
            if let previous, previous != fingerprint {
                let prefix = endpointKeyPrefix(serverKey: serverKey)
                payload.endpointRecords = payload.endpointRecords.filter {
                    !$0.key.hasPrefix(prefix)
                }
                jsonReprobesInFlight = jsonReprobesInFlight.filter {
                    !$0.hasPrefix(prefix)
                }
            }
            persistLocked()
        }
    }

    private func updateRecord(
        _ record: EndpointRecord,
        serverKey: String,
        endpoint: String
    ) {
        lock.withLock {
            payload.endpointRecords[
                endpointKey(serverKey: serverKey, endpoint: endpoint)
            ] = record
            persistLocked()
        }
    }

    private func endpointKey(serverKey: String, endpoint: String) -> String {
        endpointKeyPrefix(serverKey: serverKey) + endpoint
    }

    private func endpointKeyPrefix(serverKey: String) -> String {
        "\(serverKey.utf8.count):\(serverKey)|"
    }

    private func persistLocked() {
        payload.clientVersion = clientVersion
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

nonisolated struct SubsonicResponseNegotiationResult<Value> {
    let value: Value
    let format: SubsonicResponseFormat
    let usedFallback: Bool
}

nonisolated struct SubsonicResponseDecodingFailure: Error {
    let primaryFormat: SubsonicResponseFormat
    let primaryError: Error
    let fallbackFormat: SubsonicResponseFormat
    let fallbackError: Error
}

/// Keeps transport failures separate from representation failures. The
/// fallback is reached only after a successful HTTP response could not be
/// decoded in the requested representation.
nonisolated enum SubsonicResponseNegotiator {
    static func load<Value>(
        primaryFormat: SubsonicResponseFormat,
        fallbackFormat: SubsonicResponseFormat?,
        fetch: (SubsonicResponseFormat) async throws -> Data,
        decode: (Data, SubsonicResponseFormat) async throws -> Value
    ) async throws -> SubsonicResponseNegotiationResult<Value> {
        let primaryData = try await fetch(primaryFormat)
        do {
            return SubsonicResponseNegotiationResult(
                value: try await decode(primaryData, primaryFormat),
                format: primaryFormat,
                usedFallback: false
            )
        } catch let primaryError {
            guard let fallbackFormat else { throw primaryError }

            // Intentionally outside the decoding catch: timeouts, offline
            // state and HTTP failures never become format compatibility.
            let fallbackData = try await fetch(fallbackFormat)
            do {
                return SubsonicResponseNegotiationResult(
                    value: try await decode(fallbackData, fallbackFormat),
                    format: fallbackFormat,
                    usedFallback: true
                )
            } catch let fallbackError {
                throw SubsonicResponseDecodingFailure(
                    primaryFormat: primaryFormat,
                    primaryError: primaryError,
                    fallbackFormat: fallbackFormat,
                    fallbackError: fallbackError
                )
            }
        }
    }
}

/// Coalesces identical, simultaneous fallback requests. Different endpoint
/// parameters still receive their own response data, while duplicate library
/// loads never start duplicate XML probes.
actor SubsonicResponseRequestGate {
    private struct InFlight {
        let id: UUID
        let task: Task<Data, Error>
    }

    private var requests: [String: InFlight] = [:]

    func data(
        for requestKey: String,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        if let existing = requests[requestKey] {
            return try await existing.task.value
        }

        let id = UUID()
        let task = Task { try await operation() }
        requests[requestKey] = InFlight(id: id, task: task)

        do {
            let data = try await task.value
            clear(requestKey, id: id)
            return data
        } catch {
            clear(requestKey, id: id)
            throw error
        }
    }

    private func clear(_ requestKey: String, id: UUID) {
        guard requests[requestKey]?.id == id else { return }
        requests.removeValue(forKey: requestKey)
    }
}

/// Minimal Decoder for the attribute-oriented XML representation defined by
/// Subsonic. It intentionally reuses the app's existing Decodable models so
/// JSON and XML cannot drift into separate domain model implementations.
nonisolated struct SubsonicXMLDecoder {
    func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let root = try SubsonicXMLTreeParser.parse(data)
        let document = SubsonicXMLNode(name: "", attributes: [:])
        document.children = [root]
        return try Value(
            from: SubsonicXMLValueDecoder(
                value: .node(document),
                codingPath: []
            )
        )
    }
}

nonisolated private final class SubsonicXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [SubsonicXMLNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

nonisolated private final class SubsonicXMLTreeParser: NSObject, XMLParserDelegate {
    private var stack: [SubsonicXMLNode] = []
    private var root: SubsonicXMLNode?

    static func parse(_ data: Data) throws -> SubsonicXMLNode {
        let delegate = SubsonicXMLTreeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), let root = delegate.root else {
            throw parser.parserError ?? DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid Subsonic XML response")
            )
        }
        return root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = SubsonicXMLNode(
            name: Self.localName(qName ?? elementName),
            attributes: Dictionary(uniqueKeysWithValues: attributeDict.map {
                (Self.localName($0.key), $0.value)
            })
        )
        stack.last?.children.append(node)
        stack.append(node)
        if root == nil { root = node }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }

    private static func localName(_ value: String) -> String {
        String(value.split(separator: ":", omittingEmptySubsequences: false).last ?? "")
    }
}

nonisolated private indirect enum SubsonicXMLValue {
    case node(SubsonicXMLNode)
    case nodes([SubsonicXMLNode])
    case scalar(String)
}

nonisolated private struct SubsonicXMLValueDecoder: Decoder {
    let value: SubsonicXMLValue
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        let node = try singleNode()
        return KeyedDecodingContainer(
            SubsonicXMLKeyedContainer<Key>(node: node, codingPath: codingPath)
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        SubsonicXMLUnkeyedContainer(
            values: try arrayValues(),
            codingPath: codingPath
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        SubsonicXMLSingleValueContainer(value: value, codingPath: codingPath)
    }

    private func singleNode() throws -> SubsonicXMLNode {
        switch value {
        case .node(let node):
            return node
        case .nodes(let nodes) where nodes.count == 1:
            return nodes[0]
        case .nodes, .scalar:
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(codingPath: codingPath, debugDescription: "Expected one XML element")
            )
        }
    }

    private func arrayValues() throws -> [SubsonicXMLValue] {
        switch value {
        case .nodes(let nodes):
            if nodes.count == 1,
               nodes[0].attributes.isEmpty,
               nodes[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !nodes[0].children.isEmpty,
               nodes[0].children.allSatisfy({ $0.name != nodes[0].name }) {
                return nodes[0].children.map(SubsonicXMLValue.node)
            }
            return nodes.map(SubsonicXMLValue.node)
        case .node(let node):
            return node.children.map(SubsonicXMLValue.node)
        case .scalar:
            throw DecodingError.typeMismatch(
                [Any].self,
                .init(codingPath: codingPath, debugDescription: "Expected XML elements")
            )
        }
    }
}

nonisolated private struct SubsonicXMLKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let node: SubsonicXMLNode
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        var names = Set(node.attributes.keys)
        names.formUnion(node.children.map(\.name))
        if hasMeaningfulText { names.insert("value") }
        return names.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
        value(for: key) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        false
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        guard let value = value(for: key) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Missing XML value")
            )
        }
        return try T(
            from: SubsonicXMLValueDecoder(
                value: value,
                codingPath: codingPath + [key]
            )
        )
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard let value = value(for: key) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Missing XML element")
            )
        }
        return try SubsonicXMLValueDecoder(
            value: value,
            codingPath: codingPath + [key]
        ).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        guard let value = value(for: key) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Missing XML elements")
            )
        }
        return try SubsonicXMLValueDecoder(
            value: value,
            codingPath: codingPath + [key]
        ).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        SubsonicXMLValueDecoder(value: .node(node), codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        guard let value = value(for: key) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Missing XML value")
            )
        }
        return SubsonicXMLValueDecoder(value: value, codingPath: codingPath + [key])
    }

    private var hasMeaningfulText: Bool {
        !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func value(for key: Key) -> SubsonicXMLValue? {
        if let attribute = node.attributes[key.stringValue] {
            return .scalar(attribute)
        }

        let matchingChildren = node.children.filter { $0.name == key.stringValue }
        if !matchingChildren.isEmpty { return .nodes(matchingChildren) }

        if key.stringValue == "value", hasMeaningfulText {
            return .scalar(node.text)
        }
        return nil
    }
}

nonisolated private struct SubsonicXMLUnkeyedContainer: UnkeyedDecodingContainer {
    let values: [SubsonicXMLValue]
    let codingPath: [CodingKey]
    var currentIndex = 0
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    mutating func decodeNil() throws -> Bool {
        false
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = try nextDecoder()
        return try T(from: decoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try nextDecoder().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try nextDecoder().unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        try nextDecoder()
    }

    private mutating func nextDecoder() throws -> SubsonicXMLValueDecoder {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                Any.self,
                .init(codingPath: codingPath, debugDescription: "No more XML elements")
            )
        }
        let index = currentIndex
        currentIndex += 1
        return SubsonicXMLValueDecoder(
            value: values[index],
            codingPath: codingPath + [SubsonicXMLIndexKey(index: index)]
        )
    }
}

nonisolated private struct SubsonicXMLSingleValueContainer: SingleValueDecodingContainer {
    let value: SubsonicXMLValue
    let codingPath: [CodingKey]

    func decodeNil() -> Bool { false }

    func decode(_ type: Bool.Type) throws -> Bool {
        switch try scalar().lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: throw mismatch(type)
        }
    }

    func decode(_ type: String.Type) throws -> String { try scalar(preservingWhitespace: true) }
    func decode(_ type: Double.Type) throws -> Double { try number(type, transform: Double.init) }
    func decode(_ type: Float.Type) throws -> Float { try number(type, transform: Float.init) }
    func decode(_ type: Int.Type) throws -> Int { try number(type, transform: Int.init) }
    func decode(_ type: Int8.Type) throws -> Int8 { try number(type, transform: Int8.init) }
    func decode(_ type: Int16.Type) throws -> Int16 { try number(type, transform: Int16.init) }
    func decode(_ type: Int32.Type) throws -> Int32 { try number(type, transform: Int32.init) }
    func decode(_ type: Int64.Type) throws -> Int64 { try number(type, transform: Int64.init) }
    func decode(_ type: UInt.Type) throws -> UInt { try number(type, transform: UInt.init) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try number(type, transform: UInt8.init) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try number(type, transform: UInt16.init) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try number(type, transform: UInt32.init) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try number(type, transform: UInt64.init) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: SubsonicXMLValueDecoder(value: value, codingPath: codingPath))
    }

    private func scalar(preservingWhitespace: Bool = false) throws -> String {
        let raw: String
        switch value {
        case .scalar(let value):
            raw = value
        case .node(let node):
            raw = node.text
        case .nodes(let nodes) where nodes.count == 1:
            raw = nodes[0].text
        case .nodes:
            throw mismatch(String.self)
        }
        return preservingWhitespace
            ? raw
            : raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func number<T>(
        _ type: T.Type,
        transform: (String) -> T?
    ) throws -> T {
        guard let value = transform(try scalar()) else { throw mismatch(type) }
        return value
    }

    private func mismatch(_ type: Any.Type) -> DecodingError {
        DecodingError.typeMismatch(
            type,
            .init(codingPath: codingPath, debugDescription: "Invalid XML scalar value")
        )
    }
}

nonisolated private struct SubsonicXMLIndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String

    init(index: Int) {
        intValue = index
        stringValue = "Index \(index)"
    }

    init?(intValue: Int) {
        self.init(index: intValue)
    }

    init?(stringValue: String) {
        intValue = nil
        self.stringValue = stringValue
    }
}
