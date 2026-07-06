import Foundation

nonisolated enum DownloadState: Equatable {
    case none
    case queued
    case downloading(progress: Double)
    case completed
    case failed(message: String)

    static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.queued, .queued), (.completed, .completed): return true
        case (.downloading(let a), .downloading(let b)): return abs(a - b) < 0.0001
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

nonisolated struct DownloadedSong: Identifiable, Hashable {
    let songId: String
    let serverId: String
    let albumId: String
    let artistId: String?
    let title: String
    let albumTitle: String
    let artistName: String
    let albumArtistName: String?
    let albumCoverArtId: String?
    let track: Int?
    let disc: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let playCount: Int?
    let explicitStatus: String?
    let bytes: Int64
    let coverArtId: String?
    let artistCoverArtId: String?
    let isFavorite: Bool
    let filePath: String
    let fileExtension: String
    let contentType: String?
    let bitRate: Int?
    let bitDepth: Int?
    let samplingRate: Int?
    let channelCount: Int?
    let bpm: Int?
    let replayGainTrackGain: Float?
    let replayGainAlbumGain: Float?
    let addedAt: Date

    var id: String { "\(serverId)::\(songId)" }

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    /// Konvertiert zurück in ein Subsonic Song-Modell für Player/Queue.
    func asSong() -> Song {
        let albumArtist = Self.trimmedNonEmpty(albumArtistName)
        let genreValue = Self.trimmedNonEmpty(genre)
        let estimatedBitRate = Self.estimatedBitRateKbps(bytes: bytes, duration: duration)
        let replayGain = Self.replayGain(trackGain: replayGainTrackGain, albumGain: replayGainAlbumGain)
        return Song(
            id: songId,
            title: title,
            artist: artistName,
            artistId: artistId,
            album: albumTitle,
            albumId: albumId,
            track: track,
            discNumber: disc,
            duration: duration,
            coverArt: coverArtId,
            year: year,
            genre: genreValue,
            playCount: playCount,
            starred: isFavorite ? Date() : nil,
            contentType: contentType,
            suffix: fileExtension,
            fileSize: bytes > 0 ? bytes : nil,
            bitRate: bitRate ?? estimatedBitRate,
            bitDepth: bitDepth,
            samplingRate: samplingRate,
            channelCount: channelCount,
            bpm: bpm,
            genres: genreValue.map { [SongGenre(name: $0)] },
            albumArtists: albumArtist.map {
                [Artist(id: "album-artist:\($0)", name: $0, coverArt: albumCoverArtId)]
            },
            displayAlbumArtist: albumArtist,
            explicitStatus: Self.trimmedNonEmpty(explicitStatus),
            replayGain: replayGain
        )
    }

    private static func estimatedBitRateKbps(bytes: Int64, duration: Int?) -> Int? {
        guard bytes > 0, let duration, duration > 0 else { return nil }
        return max(1, Int((Double(bytes) * 8.0 / Double(duration) / 1_000.0).rounded()))
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func replayGain(trackGain: Float?, albumGain: Float?) -> ReplayGain? {
        guard trackGain != nil || albumGain != nil else { return nil }
        return ReplayGain(
            trackGain: trackGain,
            albumGain: albumGain,
            trackPeak: nil,
            albumPeak: nil,
            baseGain: nil
        )
    }
}

nonisolated struct DownloadedAlbum: Identifiable, Hashable {
    let albumId: String
    let serverId: String
    let title: String
    let artistName: String
    let artistId: String?
    let coverArtId: String?
    let songs: [DownloadedSong]

    var id: String { "\(serverId)::\(albumId)" }
    var totalBytes: Int64 { songs.reduce(0) { $0 + $1.bytes } }
    var songCount: Int { songs.count }

    func asAlbum() -> Album {
        Album(
            id: albumId,
            name: title,
            artist: artistName,
            artistId: artistId,
            coverArt: coverArtId,
            songCount: songs.count,
            duration: songs.reduce(0) { $0 + ($1.duration ?? 0) },
            year: nil,
            genre: nil,
            playCount: nil,
            starred: nil,
            created: nil,
            songs: songs.map { $0.asSong() }
        )
    }
}

nonisolated struct DownloadedArtist: Identifiable, Hashable {
    let artistId: String
    let serverId: String
    let name: String
    let coverArtId: String?
    let albums: [DownloadedAlbum]

    var id: String { "\(serverId)::\(artistId)" }
    var albumCount: Int { albums.count }
    var totalBytes: Int64 { albums.reduce(0) { $0 + $1.totalBytes } }

    func asArtist() -> Artist {
        Artist(
            id: artistId,
            name: name,
            albumCount: albums.count,
            coverArt: coverArtId,
            starred: nil
        )
    }
}

nonisolated struct ActualStreamFormat: Equatable, Sendable {
    let codecLabel: String
    let bitrateKbps: Int?

    var displayString: String {
        if let b = bitrateKbps {
            return "\(codecLabel) · \(b) kbps"
        }
        return codecLabel
    }

    static func codecLabel(forMime mime: String?) -> String {
        guard let m = mime?.lowercased() else { return "?" }
        switch m {
        case "audio/mpeg", "audio/mp3":          return "MP3"
        case "audio/aac", "audio/aacp":          return "AAC"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "AAC"
        case "audio/ogg", "audio/opus", "application/ogg", "audio/x-opus+ogg": return "OPUS"
        case "audio/flac", "audio/x-flac":       return "FLAC"
        case "audio/wav", "audio/x-wav":         return "WAV"
        case "audio/webm":                        return "WEBM"
        default:
            return m.split(separator: "/").last.map { String($0).uppercased() } ?? "?"
        }
    }
}

struct BatchProgress: Equatable {
    let total: Int
    let completed: Int
    let failed: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed + failed) / Double(total)))
    }

    var remaining: Int { max(0, total - completed - failed) }
}

nonisolated struct BulkDownloadPlaylistMarker: Hashable, Sendable {
    let id: String
    let name: String
    let songIds: [String]
}

struct BulkDownloadPlan {
    let planned: [Song]
    let skipped: [Song]
    let totalBytes: Int64
    let limitBytes: Int64
    var availableBytes: Int64? = nil
    var isKeepLibraryOffline: Bool = false
    var playlistMarkers: [BulkDownloadPlaylistMarker] = []
    var recapPlaylistSongIds: [String: [String]] = [:]

    var isEmpty: Bool { planned.isEmpty }
}

enum KeepLibraryOfflineStatus: Equatable {
    case inactive
    case idle
    case checking
    case downloading
    case pausedLowStorage
    case failed(String)
}

struct DownloadStorageStats {
    let totalBytes: Int64
    let songCount: Int
    let albumCount: Int
    let artistCount: Int
    let topArtists: [(name: String, bytes: Int64)]
    let freeDiskBytes: Int64?
}
