import Foundation
import Intents

#if os(iOS) || os(tvOS) || os(watchOS)
/// A compact, process-safe representation of Siri's media request. The Siri
/// extension embeds this payload in the resolved media item so the tvOS app can
/// execute exactly the request Siri resolved after the foreground hand-off.
struct ShelvTVSiriRequest: Codable, Hashable, Sendable {
    static let identifierPrefix = "shelv-tv-siri-v1:"

    let mediaTypeRawValue: Int
    let mediaName: String?
    let artistName: String?
    let albumName: String?
    let playShuffled: Bool
    let playbackRepeatModeRawValue: Int
    let playbackQueueLocationRawValue: Int
    let sortOrderRawValue: Int
    let mediaReferenceRawValue: Int

    init(intent: INPlayMediaIntent) {
        if let encodedIdentifier = intent.mediaItems?.first?.identifier,
           let decoded = Self(identifier: encodedIdentifier) {
            self = decoded
            return
        }

        let search = intent.mediaSearch
        let firstItem = intent.mediaItems?.first
        let container = intent.mediaContainer
        let inferredType = search?.mediaType ?? firstItem?.type ?? container?.type ?? .unknown

        mediaTypeRawValue = inferredType.rawValue
        mediaName = Self.firstNonempty(
            search?.mediaName,
            firstItem?.title,
            inferredType == .artist ? container?.title : nil,
            inferredType == .album ? container?.title : nil
        )
        artistName = Self.firstNonempty(
            search?.artistName,
            inferredType == .artist ? search?.mediaName : nil,
            inferredType == .artist ? firstItem?.title : nil
        )
        albumName = Self.firstNonempty(
            search?.albumName,
            inferredType == .album ? search?.mediaName : nil,
            inferredType == .album ? firstItem?.title : nil
        )
        playShuffled = intent.playShuffled ?? false
        playbackRepeatModeRawValue = intent.playbackRepeatMode.rawValue
        playbackQueueLocationRawValue = intent.playbackQueueLocation.rawValue
        sortOrderRawValue = search?.sortOrder.rawValue ?? INMediaSortOrder.unknown.rawValue
        mediaReferenceRawValue = search?.reference.rawValue ?? INMediaReference.unknown.rawValue
    }

    init?(identifier: String) {
        guard identifier.hasPrefix(Self.identifierPrefix) else { return nil }
        var encoded = String(identifier.dropFirst(Self.identifierPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: encoded),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }

    var identifier: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.identifierPrefix + encoded
    }

    var mediaType: INMediaItemType {
        INMediaItemType(rawValue: mediaTypeRawValue) ?? .unknown
    }

    var displayTitle: String {
        mediaName ?? albumName ?? artistName ?? "Music"
    }

    var query: String {
        let primary: String?
        switch mediaType {
        case .artist:
            primary = artistName ?? mediaName
        case .album:
            primary = albumName ?? mediaName
        default:
            primary = mediaName ?? albumName ?? artistName
        }

        var components: [String] = []
        if let primary { components.append(primary) }
        if let artistName,
           !components.contains(where: { Self.equal($0, artistName) }) {
            components.append("by \(artistName)")
        }
        if let albumName,
           mediaType == .song,
           artistName == nil,
           !components.contains(where: { Self.equal($0, albumName) }) {
            components.append("from \(albumName)")
        }
        return components.joined(separator: " ")
    }

    var isActionableWithoutQuery: Bool {
        playShuffled
            || mediaType == .music
            || sortOrderRawValue != INMediaSortOrder.unknown.rawValue
            || mediaReferenceRawValue == INMediaReference.currentlyPlaying.rawValue
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.lazy.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
#endif
