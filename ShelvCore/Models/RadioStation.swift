import CryptoKit
import Foundation

nonisolated struct RadioStation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var streamURL: String
    var homePageURL: String?
    var coverArt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case streamURL
        case streamUrl
        case homePageURL
        case homePageUrl
        case homepageUrl
        case coverArt
    }

    init(id: String, name: String, streamURL: String, homePageURL: String? = nil, coverArt: String? = nil) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homePageURL = homePageURL
        self.coverArt = coverArt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamUrl)
            ?? c.decodeIfPresent(String.self, forKey: .streamURL)
            ?? ""
        homePageURL = try c.decodeIfPresent(String.self, forKey: .homePageUrl)
            ?? c.decodeIfPresent(String.self, forKey: .homepageUrl)
            ?? c.decodeIfPresent(String.self, forKey: .homePageURL)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(streamURL, forKey: .streamUrl)
        try c.encodeIfPresent(homePageURL, forKey: .homePageUrl)
        try c.encodeIfPresent(coverArt, forKey: .coverArt)
    }
}

nonisolated struct RadioStationMetadata: Identifiable, Codable, Hashable, Sendable {
    let recordName: String
    let serverId: String
    let stationId: String
    let streamURLKey: String
    var useAzuraCastAPI: Bool
    var azuraCastAPIURL: String
    var showSongCover: Bool
    var updatedAt: Double

    var id: String { recordName }

    init(
        recordName: String,
        serverId: String,
        stationId: String,
        streamURLKey: String,
        useAzuraCastAPI: Bool = false,
        azuraCastAPIURL: String = "",
        showSongCover: Bool = true,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.recordName = recordName
        self.serverId = serverId
        self.stationId = stationId
        self.streamURLKey = streamURLKey
        self.useAzuraCastAPI = useAzuraCastAPI
        self.azuraCastAPIURL = azuraCastAPIURL
        self.showSongCover = showSongCover
        self.updatedAt = updatedAt
    }

    init(serverId: String, station: RadioStation) {
        let streamKey = Self.normalizedStreamURL(station.streamURL)
        self.init(
            recordName: Self.recordName(serverId: serverId, stationId: station.id, streamURL: station.streamURL),
            serverId: serverId,
            stationId: station.id,
            streamURLKey: streamKey
        )
    }

    static func recordName(serverId: String, stationId: String, streamURL: String) -> String {
        let stationKey = stationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? normalizedStreamURL(streamURL)
            : stationId
        return "radio.\(stableHash(serverId)).\(stableHash(stationKey))"
    }

    static func normalizedStreamURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? trimmed.lowercased()
    }

    static func derivedAzuraCastAPIURL(from streamURL: String) -> String? {
        guard let url = URL(string: streamURL),
              let scheme = url.scheme,
              let host = url.host
        else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        let shortcode: String?
        if let listenIndex = components.firstIndex(of: "listen"), listenIndex + 1 < components.count {
            shortcode = components[listenIndex + 1]
        } else if let hlsIndex = components.firstIndex(of: "hls"), hlsIndex + 1 < components.count {
            shortcode = components[hlsIndex + 1]
        } else {
            shortcode = nil
        }
        guard let shortcode, !shortcode.isEmpty else { return nil }
        var authority = host
        if let port = url.port {
            authority += ":\(port)"
        }
        return "\(scheme)://\(authority)/api/nowplaying/\(shortcode)"
    }

    private static func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct RadioStationDisplayItem: Identifiable, Hashable, Sendable {
    var station: RadioStation
    var metadata: RadioStationMetadata

    var id: String { station.id }
    var name: String { station.name }
    var streamURL: String { station.streamURL }
    var coverArt: String? { station.coverArt }
    var usesDynamicSongCover: Bool { metadata.useAzuraCastAPI && metadata.showSongCover }
}

nonisolated enum RadioStationDisplayItemBuilder {
    static func makeItems(
        stations: [RadioStation],
        serverId: String,
        metadataByRecordName: [String: RadioStationMetadata]
    ) -> [RadioStationDisplayItem] {
        ordered(stations.map { station in
            let recordName = RadioStationMetadata.recordName(
                serverId: serverId,
                stationId: station.id,
                streamURL: station.streamURL
            )
            let metadata = metadataByRecordName[recordName]
                ?? RadioStationMetadata(serverId: serverId, station: station)
            return RadioStationDisplayItem(station: station, metadata: metadata)
        })
    }

    static func ordered(_ items: [RadioStationDisplayItem]) -> [RadioStationDisplayItem] {
        items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

nonisolated struct RadioNowPlayingMetadata: Codable, Hashable, Sendable {
    static let artworkRevisionQueryItemName = "_shelv_radio_artwork"

    var stationName: String?
    var title: String?
    var artist: String?
    var album: String?
    var artworkURL: String?
    var isLive: Bool

    init(
        stationName: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artworkURL: String? = nil,
        isLive: Bool = false
    ) {
        self.stationName = stationName
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.isLive = isLive
    }

    var cacheBustedArtworkURL: URL? {
        guard let raw = artworkURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        guard var components = URLComponents(string: raw) else {
            return URL(string: raw)
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == Self.artworkRevisionQueryItemName }
        queryItems.append(URLQueryItem(name: Self.artworkRevisionQueryItemName, value: artworkRevisionToken))
        components.queryItems = queryItems
        return components.url ?? URL(string: raw)
    }

    var displayTitle: String? {
        sanitizedDisplayValue(
            title,
            placeholders: ["unknown", "unknown title", "titel unbekannt", "<unknown>", "n/a", "na"]
        )
    }

    var displayArtist: String? {
        sanitizedDisplayValue(
            artist,
            placeholders: ["unknown", "unknown artist", "kunstler unbekannt", "künstler unbekannt", "<unknown>", "n/a", "na"]
        )
    }

    var artworkRevisionToken: String {
        let digest = SHA256.hash(data: Data(artworkRevisionSeed.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func resolving(
        current: RadioNowPlayingMetadata?,
        incoming: RadioNowPlayingMetadata
    ) -> RadioNowPlayingMetadata {
        guard incoming.displayTitle == nil,
              incoming.displayArtist == nil,
              var current,
              current.displayTitle != nil || current.displayArtist != nil
        else { return incoming }

        current.stationName = incoming.stationName
        current.isLive = incoming.isLive
        if current.artworkURL == nil {
            current.artworkURL = incoming.artworkURL
        }
        return current
    }

    private var artworkRevisionSeed: String {
        [
            normalizedArtworkPart(artworkURL),
            normalizedArtworkPart(stationName),
            normalizedArtworkPart(title),
            normalizedArtworkPart(artist),
            normalizedArtworkPart(album)
        ].joined(separator: "|")
    }

    private func normalizedArtworkPart(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func sanitizedDisplayValue(_ value: String?, placeholders: Set<String>) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }

        let normalized = trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
        return placeholders.contains(normalized) ? nil : trimmed
    }
}

nonisolated enum RadioMetadataPollingPolicy {
    static let azuraCastInterval: Duration = .seconds(3)

    static func usesSameSource(
        _ lhs: RadioStationDisplayItem,
        _ rhs: RadioStationDisplayItem
    ) -> Bool {
        sourceIdentifier(for: lhs) == sourceIdentifier(for: rhs)
    }

    private static func sourceIdentifier(for item: RadioStationDisplayItem) -> String {
        let streamURL = item.streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiURL = item.metadata.azuraCastAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.metadata.useAzuraCastAPI, !apiURL.isEmpty {
            return "azura|\(apiURL)|\(streamURL)"
        }
        return "icy|\(streamURL)"
    }
}
