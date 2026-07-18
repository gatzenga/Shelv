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

    private var authoritativeSnapshot: DownloadUIStateSnapshot
    private var optimisticRecordsBySongID: [String: DownloadRecord] = [:]
    private var optimisticAlbumCounts: [String: Int] = [:]
    private var optimisticArtistNameCounts: [String: Int] = [:]
    private var optimisticArtistBadgeNameCounts: [String: Int] = [:]
    private var optimisticTotalBytes: Int64 = 0

    // Only affected identifiers cross these channels. Subscribers derive their
    // current scalar value in O(1), so the hub retains no per-row subjects.
    private let songAvailabilityChangeSubject = CurrentValueSubject<String?, Never>(nil)
    private let albumDownloadedCountChangeSubject = CurrentValueSubject<String?, Never>(nil)
    private let catalogArtistAvailabilityChangeSubject = CurrentValueSubject<String?, Never>(nil)
    private let artistBadgeAvailabilityChangeSubject = CurrentValueSubject<String?, Never>(nil)
    private let stateChangeSubject = PassthroughSubject<Void, Never>()
    private let storageStateSubject: CurrentValueSubject<DownloadUIStorageState, Never>
    private let authoritativeStorageStateSubject: CurrentValueSubject<DownloadUIStorageState, Never>
    private let hasDownloadsSubject: CurrentValueSubject<Bool, Never>

    init(initialSnapshot: DownloadUIStateSnapshot = .empty) {
        authoritativeSnapshot = initialSnapshot
        storageStateSubject = CurrentValueSubject(initialSnapshot.storageState)
        authoritativeStorageStateSubject = CurrentValueSubject(initialSnapshot.storageState)
        hasDownloadsSubject = CurrentValueSubject(!initialSnapshot.songIDs.isEmpty)
    }

    // This type is main-actor confined while alive, but its Combine storage does not
    // require executor-bound destruction. Avoid the Swift back-deployment deinit path.
    nonisolated deinit {}

    var currentSnapshot: DownloadUIStateSnapshot {
        var snapshot = authoritativeSnapshot
        for record in optimisticRecordsBySongID.values {
            Self.add(record, to: &snapshot)
        }
        return snapshot
    }

    func commit(_ snapshot: DownloadUIStateSnapshot) {
        authoritativeSnapshot = snapshot
        sendIfChanged(authoritativeStorageStateSubject, value: snapshot.storageState)
        optimisticRecordsBySongID = optimisticRecordsBySongID.filter {
            !snapshot.songIDs.contains($0.key)
        }
        rebuildOptimisticAggregates()
        publishRegisteredValues()
        stateChangeSubject.send(())
    }

    /// Hands an incremental catalog batch from the optimistic overlay to the
    /// authoritative snapshot without making already visible rows transition.
    func commitCatalogInsertions(
        _ snapshot: DownloadUIStateSnapshot,
        committedSongIDs: Set<String>
    ) {
        let canHandoffWithoutReconciliation = committedSongIDs.allSatisfy {
            optimisticRecordsBySongID[$0] != nil && snapshot.songIDs.contains($0)
        }
        guard canHandoffWithoutReconciliation else {
            commit(snapshot)
            return
        }

        authoritativeSnapshot = snapshot
        sendIfChanged(authoritativeStorageStateSubject, value: snapshot.storageState)
        let handedOffSongIDs = optimisticRecordsBySongID.keys.filter {
            snapshot.songIDs.contains($0)
        }
        for songID in handedOffSongIDs {
            guard let record = optimisticRecordsBySongID.removeValue(forKey: songID) else { continue }
            removeFromOptimisticAggregates(record)
        }
        // Song, album and visible storage values are unchanged by the overlay
        // handoff. Track ordering can still alter the resolved album artist.
        catalogArtistAvailabilityChangeSubject.send(nil)
        artistBadgeAvailabilityChangeSubject.send(nil)
        publishScalarValues()
        stateChangeSubject.send(())
    }

    /// Replaces all state after an authoritative reload or server change.
    func replace(with snapshot: DownloadUIStateSnapshot) {
        authoritativeSnapshot = snapshot
        sendIfChanged(authoritativeStorageStateSubject, value: snapshot.storageState)
        optimisticRecordsBySongID.removeAll(keepingCapacity: true)
        rebuildOptimisticAggregates()
        publishRegisteredValues()
        stateChangeSubject.send(())
    }

    /// Makes a completed download visible immediately, before the batched catalog projection.
    /// The next authoritative catalog commit replaces this optimistic projection.
    func applyCompletedRecord(_ record: DownloadRecord) {
        guard !isSongDownloaded(record.songId) else { return }
        optimisticRecordsBySongID[record.songId] = record
        addToOptimisticAggregates(record)
        publishCompletedRecord(record)
        stateChangeSubject.send(())
    }

    func removeOptimisticRecord(songID: String) {
        guard let record = optimisticRecordsBySongID.removeValue(forKey: songID) else { return }
        removeFromOptimisticAggregates(record)
        publishRemovedRecord(record)
        stateChangeSubject.send(())
    }

    func isSongDownloaded(_ songID: String) -> Bool {
        authoritativeSnapshot.songIDs.contains(songID)
            || optimisticRecordsBySongID[songID] != nil
    }

    func albumDownloadedCount(_ albumID: String) -> Int {
        (authoritativeSnapshot.albumDownloadedCounts[albumID] ?? 0)
            + (optimisticAlbumCounts[albumID] ?? 0)
    }

    func isAlbumDownloaded(_ albumID: String) -> Bool {
        albumDownloadedCount(albumID) > 0
    }

    func isCatalogArtistDownloaded(_ name: String) -> Bool {
        authoritativeSnapshot.artistNames.contains(name)
            || (optimisticArtistNameCounts[name] ?? 0) > 0
    }

    func isArtistBadgeDownloaded(_ name: String) -> Bool {
        authoritativeSnapshot.artistBadgeNames.contains(name)
            || (optimisticArtistBadgeNameCounts[name] ?? 0) > 0
    }

    func downloadedSongIDs(in songIDs: Set<String>) -> Set<String> {
        Set(songIDs.filter(isSongDownloaded))
    }

    func downloadedAlbumCounts(for albumIDs: Set<String>) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: albumIDs.compactMap { albumID in
            let count = albumDownloadedCount(albumID)
            return count > 0 ? (albumID, count) : nil
        })
    }

    var hasDownloads: Bool {
        !authoritativeSnapshot.songIDs.isEmpty || !optimisticRecordsBySongID.isEmpty
    }

    func songAvailabilityPublisher(songID: String) -> AnyPublisher<Bool, Never> {
        songAvailabilityChangeSubject
            .map { [weak self] _ in self?.isSongDownloaded(songID) ?? false }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func albumAvailabilityPublisher(albumID: String) -> AnyPublisher<Bool, Never> {
        albumDownloadedCountPublisher(albumID: albumID)
            .map { $0 > 0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func albumDownloadedCountPublisher(albumID: String) -> AnyPublisher<Int, Never> {
        albumDownloadedCountChangeSubject
            .map { [weak self] _ in self?.albumDownloadedCount(albumID) ?? 0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func catalogArtistAvailabilityPublisher(name: String) -> AnyPublisher<Bool, Never> {
        catalogArtistAvailabilityChangeSubject
            .map { [weak self] _ in self?.isCatalogArtistDownloaded(name) ?? false }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func artistAvailabilityPublisher(name: String) -> AnyPublisher<Bool, Never> {
        artistBadgeAvailabilityChangeSubject
            .map { [weak self] _ in self?.isArtistBadgeDownloaded(name) ?? false }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func downloadedSongSubsetPublisher(songIDs: Set<String>) -> AnyPublisher<Set<String>, Never> {
        guard !songIDs.isEmpty else {
            return Just(Set<String>()).eraseToAnyPublisher()
        }
        return songAvailabilityChangeSubject
            .scan(Optional<Set<String>>.none) { [weak self] current, changedSongID in
                guard let self else { return current ?? [] }
                guard let current else {
                    return self.downloadedSongIDs(in: songIDs)
                }
                guard let changedSongID else {
                    return self.downloadedSongIDs(in: songIDs)
                }
                guard songIDs.contains(changedSongID) else { return current }
                var result = current
                if self.isSongDownloaded(changedSongID) {
                    result.insert(changedSongID)
                } else {
                    result.remove(changedSongID)
                }
                return result
            }
            .compactMap { $0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func albumDownloadedCountsPublisher(albumIDs: Set<String>) -> AnyPublisher<[String: Int], Never> {
        guard !albumIDs.isEmpty else {
            return Just([String: Int]()).eraseToAnyPublisher()
        }
        return albumDownloadedCountChangeSubject
            .scan(Optional<[String: Int]>.none) { [weak self] current, changedAlbumID in
                guard let self else { return current ?? [:] }
                guard let current else {
                    return self.downloadedAlbumCounts(for: albumIDs)
                }
                guard let changedAlbumID else {
                    return self.downloadedAlbumCounts(for: albumIDs)
                }
                guard albumIDs.contains(changedAlbumID) else { return current }
                var result = current
                let count = self.albumDownloadedCount(changedAlbumID)
                if count > 0 {
                    result[changedAlbumID] = count
                } else {
                    result.removeValue(forKey: changedAlbumID)
                }
                return result
            }
            .compactMap { $0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var storageStatePublisher: AnyPublisher<DownloadUIStorageState, Never> {
        storageStateSubject.eraseToAnyPublisher()
    }

    /// Storage updates aligned with DownloadStore's committed catalog arrays.
    var authoritativeStorageStatePublisher: AnyPublisher<DownloadUIStorageState, Never> {
        authoritativeStorageStateSubject.eraseToAnyPublisher()
    }

    var hasDownloadsPublisher: AnyPublisher<Bool, Never> {
        hasDownloadsSubject.eraseToAnyPublisher()
    }

    var stateChanges: AnyPublisher<Void, Never> {
        stateChangeSubject.eraseToAnyPublisher()
    }

    private func addToOptimisticAggregates(_ record: DownloadRecord) {
        optimisticAlbumCounts[record.albumId, default: 0] += 1
        if let artistName = Self.catalogArtistName(for: record) {
            optimisticArtistNameCounts[artistName, default: 0] += 1
        }
        for name in Self.badgeArtistNames(for: record) {
            optimisticArtistBadgeNameCounts[name, default: 0] += 1
        }
        optimisticTotalBytes += record.bytes
    }

    private func removeFromOptimisticAggregates(_ record: DownloadRecord) {
        decrement(&optimisticAlbumCounts, key: record.albumId)
        if let artistName = Self.catalogArtistName(for: record) {
            decrement(&optimisticArtistNameCounts, key: artistName)
        }
        for name in Self.badgeArtistNames(for: record) {
            decrement(&optimisticArtistBadgeNameCounts, key: name)
        }
        optimisticTotalBytes -= record.bytes
    }

    private func rebuildOptimisticAggregates() {
        optimisticAlbumCounts.removeAll(keepingCapacity: true)
        optimisticArtistNameCounts.removeAll(keepingCapacity: true)
        optimisticArtistBadgeNameCounts.removeAll(keepingCapacity: true)
        optimisticTotalBytes = 0
        for record in optimisticRecordsBySongID.values {
            addToOptimisticAggregates(record)
        }
    }

    private func publishCompletedRecord(_ record: DownloadRecord) {
        songAvailabilityChangeSubject.send(record.songId)
        albumDownloadedCountChangeSubject.send(record.albumId)
        if let artistName = Self.catalogArtistName(for: record) {
            catalogArtistAvailabilityChangeSubject.send(artistName)
        }
        for name in Self.badgeArtistNames(for: record) {
            artistBadgeAvailabilityChangeSubject.send(name)
        }
        publishScalarValues()
    }

    private func publishRemovedRecord(_ record: DownloadRecord) {
        songAvailabilityChangeSubject.send(record.songId)
        albumDownloadedCountChangeSubject.send(record.albumId)
        if let artistName = Self.catalogArtistName(for: record) {
            catalogArtistAvailabilityChangeSubject.send(artistName)
        }
        for name in Self.badgeArtistNames(for: record) {
            artistBadgeAvailabilityChangeSubject.send(name)
        }
        publishScalarValues()
    }

    private func publishRegisteredValues() {
        songAvailabilityChangeSubject.send(nil)
        albumDownloadedCountChangeSubject.send(nil)
        catalogArtistAvailabilityChangeSubject.send(nil)
        artistBadgeAvailabilityChangeSubject.send(nil)
        publishScalarValues()
    }

    private func publishScalarValues() {
        let storageState = DownloadUIStorageState(
            totalBytes: authoritativeSnapshot.totalBytes + optimisticTotalBytes,
            songCount: authoritativeSnapshot.songIDs.count + optimisticRecordsBySongID.count
        )
        sendIfChanged(storageStateSubject, value: storageState)
        sendIfChanged(hasDownloadsSubject, value: hasDownloads)
    }

    private func decrement(_ counts: inout [String: Int], key: String) {
        guard let count = counts[key] else { return }
        if count <= 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
    }

    private func sendIfChanged<Value: Equatable>(
        _ subject: CurrentValueSubject<Value, Never>?,
        value: Value
    ) {
        guard let subject, subject.value != value else { return }
        subject.send(value)
    }

    private static func catalogArtistName(for record: DownloadRecord) -> String? {
        let albumArtist = record.albumArtistName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (albumArtist?.isEmpty == false ? albumArtist : nil)
            ?? record.artistName
        return resolved.isEmpty ? nil : resolved
    }

    private static func badgeArtistNames(for record: DownloadRecord) -> Set<String> {
        var names = DownloadArtistNameParser.names(from: record.artistName)
        if let catalogArtist = catalogArtistName(for: record) {
            names.insert(catalogArtist)
        }
        return names
    }

    private static func add(_ record: DownloadRecord, to snapshot: inout DownloadUIStateSnapshot) {
        guard !snapshot.songIDs.contains(record.songId) else { return }
        snapshot.songIDs.insert(record.songId)
        snapshot.albumDownloadedCounts[record.albumId, default: 0] += 1
        if let artistName = catalogArtistName(for: record) {
            snapshot.artistNames.insert(artistName)
        }
        snapshot.artistBadgeNames.formUnion(badgeArtistNames(for: record))
        snapshot.totalBytes += record.bytes
    }
}

nonisolated struct DownloadCatalogSnapshot: Equatable, Sendable {
    let songs: [DownloadedSong]
    let songIndexById: [String: Int]
    let songById: [String: DownloadedSong]
    let recordsByAlbumId: [String: [DownloadedSong]]
    let albums: [DownloadedAlbum]
    let artists: [DownloadedArtist]
    let favoriteSongs: [DownloadedSong]
    let totalBytes: Int64
    let uiState: DownloadUIStateSnapshot

    static let empty = DownloadCatalogSnapshot(
        songs: [],
        songIndexById: [:],
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
        var songIndexById = current.songIndexById
        var songById = current.songById
        var recordsByAlbumId = current.recordsByAlbumId
        var albums = current.albums
        var artists = current.artists
        var totalBytes = current.totalBytes
        var uiState = current.uiState
        var artistBadgeNames = uiState.artistBadgeNames
        var shouldRebuildArtistBadgeNames = false

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
            uiState.songIDs.insert(song.songId)
            totalBytes += song.bytes
            affectedAlbumIds.insert(song.albumId)
            recordsByAlbumId[song.albumId, default: []].removeAll { $0.songId == song.songId }
            recordsByAlbumId[song.albumId, default: []].append(song)
            recordsByAlbumId[song.albumId]?.sort(by: songsAreOrdered)

            let albumArtist = resolvedAlbumArtistName(for: song)
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
        for albumId in affectedAlbumIds {
            if let count = recordsByAlbumId[albumId]?.count, count > 0 {
                uiState.albumDownloadedCounts[albumId] = count
            } else {
                uiState.albumDownloadedCounts.removeValue(forKey: albumId)
            }
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
        for artistName in affectedArtistNames {
            if artists.contains(where: { $0.name == artistName }) {
                uiState.artistNames.insert(artistName)
            } else {
                uiState.artistNames.remove(artistName)
            }
        }

        if shouldRebuildArtistBadgeNames {
            artistBadgeNames = makeArtistBadgeNames(songs: songs, artists: artists)
        }

        uiState.artistBadgeNames = artistBadgeNames
        uiState.totalBytes = totalBytes

        return DownloadCatalogSnapshot(
            songs: songs,
            songIndexById: songIndexById,
            songById: songById,
            recordsByAlbumId: recordsByAlbumId,
            albums: albums,
            artists: artists,
            favoriteSongs: songs.filter(\.isFavorite),
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
            songIndexById: Dictionary(
                uniqueKeysWithValues: songs.enumerated().map { ($0.element.songId, $0.offset) }
            ),
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
            artistName: resolvedAlbumArtistName(for: first),
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

    private static func resolvedAlbumArtistName(for song: DownloadedSong) -> String {
        let albumArtist = song.albumArtistName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        return song.artistName
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
