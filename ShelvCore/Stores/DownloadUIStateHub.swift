import Combine
import Foundation

nonisolated enum DownloadArtistNameParser {
    private static let separators = [" feat. ", " feat ", " ft. ", " ft ", " / ", "; "]

    static func names(from value: String) -> Set<String> {
        var parts = [value]
        for separator in separators {
            parts = parts.flatMap { part in
                var result: [String] = []
                var remainder = part
                while let range = remainder.range(of: separator, options: .caseInsensitive) {
                    result.append(String(remainder[..<range.lowerBound]))
                    remainder = String(remainder[range.upperBound...])
                }
                result.append(remainder)
                return result
            }
        }
        return Set(parts.compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
    }
}

nonisolated struct DownloadUIStorageState: Hashable, Sendable {
    let totalBytes: Int64
    let songCount: Int
}

nonisolated struct DownloadUIStateSnapshot: Equatable, Sendable {
    var songIDs: Set<String>
    var albumDownloadedCounts: [String: Int]
    var artistNames: Set<String>
    var artistBadgeNames: Set<String>
    var totalBytes: Int64

    static let empty = DownloadUIStateSnapshot(
        songIDs: [],
        albumDownloadedCounts: [:],
        artistNames: [],
        artistBadgeNames: [],
        totalBytes: 0
    )

    var albumIDs: Set<String> { Set(albumDownloadedCounts.keys) }
    var storageState: DownloadUIStorageState {
        DownloadUIStorageState(totalBytes: totalBytes, songCount: songIDs.count)
    }
}

/// Publishes coherent, narrowly filterable download state for SwiftUI.
/// The legacy DownloadStore publishers remain intact for CarPlay and other consumers.
@MainActor
final class DownloadUIStateHub {
    static let shared = DownloadUIStateHub()

    private let subject: CurrentValueSubject<DownloadUIStateSnapshot, Never>
    private let authoritativeSubject: CurrentValueSubject<DownloadUIStateSnapshot, Never>
    private var authoritativeSnapshot: DownloadUIStateSnapshot
    private var optimisticRecordsBySongID: [String: DownloadRecord] = [:]

    init(initialSnapshot: DownloadUIStateSnapshot = .empty) {
        authoritativeSnapshot = initialSnapshot
        subject = CurrentValueSubject(initialSnapshot)
        authoritativeSubject = CurrentValueSubject(initialSnapshot)
    }

    // This type is main-actor confined while alive, but its Combine storage does not
    // require executor-bound destruction. Avoid the Swift back-deployment deinit path.
    nonisolated deinit {}

    var currentSnapshot: DownloadUIStateSnapshot { subject.value }

    var snapshots: AnyPublisher<DownloadUIStateSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func commit(_ snapshot: DownloadUIStateSnapshot) {
        authoritativeSnapshot = snapshot
        if authoritativeSubject.value != snapshot {
            authoritativeSubject.send(snapshot)
        }
        optimisticRecordsBySongID = optimisticRecordsBySongID.filter {
            !snapshot.songIDs.contains($0.key)
        }
        publishMergedSnapshot()
    }

    /// Replaces all state after an authoritative reload or server change.
    func replace(with snapshot: DownloadUIStateSnapshot) {
        authoritativeSnapshot = snapshot
        if authoritativeSubject.value != snapshot {
            authoritativeSubject.send(snapshot)
        }
        optimisticRecordsBySongID.removeAll(keepingCapacity: true)
        publishMergedSnapshot()
    }

    /// Makes a completed download visible immediately, before the batched catalog projection.
    /// The next authoritative catalog commit replaces this optimistic projection.
    func applyCompletedRecord(_ record: DownloadRecord) {
        guard !subject.value.songIDs.contains(record.songId) else { return }
        optimisticRecordsBySongID[record.songId] = record
        publishMergedSnapshot()
    }

    func removeOptimisticRecord(songID: String) {
        guard optimisticRecordsBySongID.removeValue(forKey: songID) != nil else { return }
        publishMergedSnapshot()
    }

    func songAvailabilityPublisher(songID: String) -> AnyPublisher<Bool, Never> {
        subject
            .map { $0.songIDs.contains(songID) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func albumAvailabilityPublisher(albumID: String) -> AnyPublisher<Bool, Never> {
        subject
            .map { ($0.albumDownloadedCounts[albumID] ?? 0) > 0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func albumDownloadedCountPublisher(albumID: String) -> AnyPublisher<Int, Never> {
        subject
            .map { $0.albumDownloadedCounts[albumID] ?? 0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func artistAvailabilityPublisher(name: String) -> AnyPublisher<Bool, Never> {
        subject
            .map { $0.artistBadgeNames.contains(name) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func downloadedSongSubsetPublisher(songIDs: Set<String>) -> AnyPublisher<Set<String>, Never> {
        subject
            .map { $0.songIDs.intersection(songIDs) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var songIDsPublisher: AnyPublisher<Set<String>, Never> {
        subject
            .map(\.songIDs)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var albumIDsPublisher: AnyPublisher<Set<String>, Never> {
        subject
            .map(\.albumIDs)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var artistBadgeNamesPublisher: AnyPublisher<Set<String>, Never> {
        subject
            .map(\.artistBadgeNames)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var storageStatePublisher: AnyPublisher<DownloadUIStorageState, Never> {
        subject
            .map(\.storageState)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Storage updates aligned with DownloadStore's committed catalog arrays.
    var authoritativeStorageStatePublisher: AnyPublisher<DownloadUIStorageState, Never> {
        authoritativeSubject
            .map(\.storageState)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var hasDownloadsPublisher: AnyPublisher<Bool, Never> {
        subject
            .map { !$0.songIDs.isEmpty }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private func publishMergedSnapshot() {
        var merged = authoritativeSnapshot
        for record in optimisticRecordsBySongID.values
        where !merged.songIDs.contains(record.songId) {
            merged.songIDs.insert(record.songId)
            merged.albumDownloadedCounts[record.albumId, default: 0] += 1

            let albumArtist = record.albumArtistName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedArtist = (albumArtist?.isEmpty == false ? albumArtist : nil)
                ?? record.artistName
            if !resolvedArtist.isEmpty {
                merged.artistNames.insert(resolvedArtist)
                merged.artistBadgeNames.insert(resolvedArtist)
            }
            merged.artistBadgeNames.formUnion(
                DownloadArtistNameParser.names(from: record.artistName)
            )
            merged.totalBytes += record.bytes
        }

        guard subject.value != merged else { return }
        subject.send(merged)
    }
}

nonisolated struct DownloadCatalogSnapshot: Equatable, Sendable {
    let songs: [DownloadedSong]
    let songById: [String: DownloadedSong]
    let recordsByAlbumId: [String: [DownloadedSong]]
    let albums: [DownloadedAlbum]
    let artists: [DownloadedArtist]
    let favoriteSongs: [DownloadedSong]
    let totalBytes: Int64
    let uiState: DownloadUIStateSnapshot

    static let empty = DownloadCatalogSnapshot(
        songs: [],
        songById: [:],
        recordsByAlbumId: [:],
        albums: [],
        artists: [],
        favoriteSongs: [],
        totalBytes: 0,
        uiState: .empty
    )
}

nonisolated enum DownloadCatalogBuilder {
    static func rebuilding(
        _ records: [DownloadRecord],
        serverId: String,
        artistCoverByName: [String: String]
    ) -> DownloadCatalogSnapshot {
        var songs: [DownloadedSong] = []
        var songIndexById: [String: Int] = [:]
        songs.reserveCapacity(records.count)
        songIndexById.reserveCapacity(records.count)
        for record in records where record.serverId == serverId {
            let song = record.toDownloadedSong()
            if let index = songIndexById[song.songId] {
                songs[index] = song
            } else {
                songIndexById[song.songId] = songs.count
                songs.append(song)
            }
        }

        var recordsByAlbumId = Dictionary(grouping: songs, by: \.albumId)
        for key in recordsByAlbumId.keys {
            recordsByAlbumId[key]?.sort {
                ($0.disc ?? 0, $0.track ?? 0) < ($1.disc ?? 0, $1.track ?? 0)
            }
        }

        let albums = recordsByAlbumId.compactMap { albumId, group in
            makeAlbum(albumId: albumId, songs: group, serverId: serverId)
        }.sorted(by: albumsAreOrdered)

        let artists = Dictionary(grouping: albums, by: \.artistName).compactMap {
            artistName, artistAlbums -> DownloadedArtist? in
            makeArtist(
                name: artistName,
                albums: artistAlbums,
                serverId: serverId,
                artistCoverByName: artistCoverByName
            )
        }.sorted(by: artistsAreOrdered)

        return snapshot(
            songs: songs,
            recordsByAlbumId: recordsByAlbumId,
            albums: albums,
            artists: artists
        )
    }

    static func applying(
        _ records: [DownloadRecord],
        to current: DownloadCatalogSnapshot,
        serverId: String,
        artistCoverByName: [String: String]
    ) -> DownloadCatalogSnapshot {
        guard !records.isEmpty else { return current }

        var songs = current.songs
        var songById = current.songById
        var recordsByAlbumId = current.recordsByAlbumId
        var albums = current.albums
        var artists = current.artists
        var totalBytes = current.totalBytes
        var artistBadgeNames = current.uiState.artistBadgeNames
        var shouldRebuildArtistBadgeNames = false

        var songIndexById = Dictionary(
            uniqueKeysWithValues: songs.enumerated().map { ($0.element.songId, $0.offset) }
        )
        let previousAlbumsById = Dictionary(uniqueKeysWithValues: albums.map { ($0.albumId, $0) })
        var affectedAlbumIds: Set<String> = []
        var affectedArtistNames: Set<String> = []

        for record in records where record.serverId == serverId {
            let song = record.toDownloadedSong()
            if let previous = songById[song.songId] {
                totalBytes -= previous.bytes
                affectedAlbumIds.insert(previous.albumId)
                recordsByAlbumId[previous.albumId]?.removeAll { $0.songId == song.songId }
                if recordsByAlbumId[previous.albumId]?.isEmpty == true {
                    recordsByAlbumId.removeValue(forKey: previous.albumId)
                }
                shouldRebuildArtistBadgeNames = shouldRebuildArtistBadgeNames
                    || previous.artistName != song.artistName
                    || previous.albumArtistName != song.albumArtistName
            }

            if let index = songIndexById[song.songId] {
                songs[index] = song
            } else {
                songIndexById[song.songId] = songs.count
                songs.append(song)
            }
            songById[song.songId] = song
            totalBytes += song.bytes
            affectedAlbumIds.insert(song.albumId)
            recordsByAlbumId[song.albumId, default: []].removeAll { $0.songId == song.songId }
            recordsByAlbumId[song.albumId, default: []].append(song)
            recordsByAlbumId[song.albumId]?.sort(by: songsAreOrdered)

            let albumArtist = song.albumArtistName ?? song.artistName
            if !albumArtist.isEmpty {
                artistBadgeNames.insert(albumArtist)
            }
            artistBadgeNames.formUnion(DownloadArtistNameParser.names(from: song.artistName))
        }

        for albumId in affectedAlbumIds {
            let previous = previousAlbumsById[albumId]
            if let previous {
                affectedArtistNames.insert(previous.artistName)
            }
            albums.removeAll { $0.albumId == albumId }
            var rebuiltArtistName: String?
            if let albumSongs = recordsByAlbumId[albumId],
               let album = makeAlbum(albumId: albumId, songs: albumSongs, serverId: serverId) {
                albums.append(album)
                affectedArtistNames.insert(album.artistName)
                rebuiltArtistName = album.artistName
            }
            if let previous, previous.artistName != rebuiltArtistName {
                shouldRebuildArtistBadgeNames = true
            }
        }
        if !affectedAlbumIds.isEmpty {
            albums.sort(by: albumsAreOrdered)
        }

        for artistName in affectedArtistNames {
            artists.removeAll { $0.name == artistName }
            let artistAlbums = albums.filter { $0.artistName == artistName }
            if let artist = makeArtist(
                name: artistName,
                albums: artistAlbums,
                serverId: serverId,
                artistCoverByName: artistCoverByName
            ) {
                artists.append(artist)
            }
        }
        if !affectedArtistNames.isEmpty {
            artists.sort(by: artistsAreOrdered)
        }

        if shouldRebuildArtistBadgeNames {
            artistBadgeNames = makeArtistBadgeNames(songs: songs, artists: artists)
        }

        let favoriteSongs = songs.filter(\.isFavorite)
        let uiState = DownloadUIStateSnapshot(
            songIDs: Set(songById.keys),
            albumDownloadedCounts: recordsByAlbumId.mapValues(\.count),
            artistNames: Set(artists.map(\.name)),
            artistBadgeNames: artistBadgeNames,
            totalBytes: totalBytes
        )

        return DownloadCatalogSnapshot(
            songs: songs,
            songById: songById,
            recordsByAlbumId: recordsByAlbumId,
            albums: albums,
            artists: artists,
            favoriteSongs: favoriteSongs,
            totalBytes: totalBytes,
            uiState: uiState
        )
    }

    static func makeArtistBadgeNames(
        songs: [DownloadedSong],
        artists: [DownloadedArtist]
    ) -> Set<String> {
        var names = Set(artists.map(\.name))
        for song in songs {
            names.formUnion(DownloadArtistNameParser.names(from: song.artistName))
        }
        return names
    }

    private static func snapshot(
        songs: [DownloadedSong],
        recordsByAlbumId: [String: [DownloadedSong]],
        albums: [DownloadedAlbum],
        artists: [DownloadedArtist]
    ) -> DownloadCatalogSnapshot {
        let songById = Dictionary(uniqueKeysWithValues: songs.map { ($0.songId, $0) })
        let totalBytes = songs.reduce(0) { $0 + $1.bytes }
        return DownloadCatalogSnapshot(
            songs: songs,
            songById: songById,
            recordsByAlbumId: recordsByAlbumId,
            albums: albums,
            artists: artists,
            favoriteSongs: songs.filter(\.isFavorite),
            totalBytes: totalBytes,
            uiState: DownloadUIStateSnapshot(
                songIDs: Set(songById.keys),
                albumDownloadedCounts: recordsByAlbumId.mapValues(\.count),
                artistNames: Set(artists.map(\.name)),
                artistBadgeNames: makeArtistBadgeNames(songs: songs, artists: artists),
                totalBytes: totalBytes
            )
        )
    }

    private static func makeAlbum(
        albumId: String,
        songs: [DownloadedSong],
        serverId: String
    ) -> DownloadedAlbum? {
        guard let first = songs.first else { return nil }
        return DownloadedAlbum(
            albumId: albumId,
            serverId: serverId,
            title: first.albumTitle,
            artistName: first.albumArtistName ?? first.artistName,
            artistId: first.artistId,
            coverArtId: first.albumCoverArtId ?? first.coverArtId,
            songs: songs
        )
    }

    private static func makeArtist(
        name: String,
        albums: [DownloadedAlbum],
        serverId: String,
        artistCoverByName: [String: String]
    ) -> DownloadedArtist? {
        guard let first = albums.first else { return nil }
        return DownloadedArtist(
            artistId: first.artistId ?? "name:\(name)",
            serverId: serverId,
            name: name,
            coverArtId: first.songs.first?.artistCoverArtId ?? artistCoverByName[name],
            albums: albums
        )
    }

    private static func songsAreOrdered(_ lhs: DownloadedSong, _ rhs: DownloadedSong) -> Bool {
        (lhs.disc ?? 0, lhs.track ?? 0) < (rhs.disc ?? 0, rhs.track ?? 0)
    }

    private static func albumsAreOrdered(_ lhs: DownloadedAlbum, _ rhs: DownloadedAlbum) -> Bool {
        let leftArtist = lhs.artistName.lowercased()
        let rightArtist = rhs.artistName.lowercased()
        return leftArtist == rightArtist
            ? lhs.title.lowercased() < rhs.title.lowercased()
            : leftArtist < rightArtist
    }

    private static func artistsAreOrdered(_ lhs: DownloadedArtist, _ rhs: DownloadedArtist) -> Bool {
        lhs.name.lowercased() < rhs.name.lowercased()
    }
}
