import Combine
import Foundation

nonisolated enum LastFMConnectionState: Equatable, Sendable {
    /// Key or secret missing.
    case notConfigured
    /// Key and secret present, but access was never granted or was revoked.
    case notConnected
    case checking
    case connected(username: String)
    case failed(LastFMConnectionProblem)
}

nonisolated enum LastFMConnectionProblem: Equatable, Sendable {
    case invalidAPIKey
    case invalidSecret
    case accessRevoked
    case authorizationIncomplete
    case unreachable
    case other(String)
}

@MainActor
final class LastFMStatus: ObservableObject {
    @Published fileprivate(set) var state: LastFMConnectionState = .notConfigured
    @Published fileprivate(set) var lastChecked: Date?

    nonisolated init() {}
}

/// Pending browser authorization. Last.fm grants the session for `token`
/// once the listener has approved Shelv on `url`.
nonisolated struct LastFMAuthorizationRequest: Sendable {
    let token: String
    let url: URL
}

/// Last.fm connection and listening data for the smart mixes.
///
/// Last.fm is used read only: Shelv never scrobbles to it. Navidrome can
/// forward plays there itself, and other players do the same, so Last.fm
/// ends up with the complete history no matter where music was played.
actor LastFMService {
    static let shared = LastFMService()

    /// Callback the authorization page redirects to, closing the browser sheet.
    static let callbackScheme = "shelv"
    static let callbackURL = "shelv://lastfm-auth"
    static let createAPIAccountURL = URL(string: "https://www.last.fm/api/account/create")!

    nonisolated let status = LastFMStatus()

    private var didVerifyOnLaunch = false
    private var matchCache: [String: CachedMatch] = [:]
    private let matchCacheLifetime: TimeInterval = 30 * 60
    private let minimumMixSize = 10

    private struct CachedMatch {
        let song: Song?
        let storedAt: Date
    }

    private init() {}

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) async {
        guard LastFMCredentialStore.isEnabled != enabled else { return }
        LastFMCredentialStore.isEnabled = enabled
        ExternalServicesLog.info(enabled ? "Last.fm turned on" : "Last.fm turned off")
        await CloudKitSyncService.shared.recordExternalServicesChange()
        if enabled {
            await verifyConnection()
        }
    }

    /// Stores new API credentials. A session belongs to the key it was granted
    /// for, so changing the key or secret also ends the current connection.
    func saveCredentials(apiKey: String, sharedSecret: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = LastFMCredentialStore.snapshot()
        guard key != current.apiKey || secret != current.sharedSecret else { return }
        var updated = current
        updated.apiKey = key
        updated.sharedSecret = secret
        updated.sessionKey = ""
        updated.username = ""
        LastFMCredentialStore.apply(updated)
        matchCache.removeAll()
        ExternalServicesLog.info("API key and secret saved")
        await CloudKitSyncService.shared.recordExternalServicesChange()
        await publish(Self.idleState(for: updated))
    }

    func disconnect() async {
        var updated = LastFMCredentialStore.snapshot()
        updated.sessionKey = ""
        updated.username = ""
        LastFMCredentialStore.apply(updated)
        matchCache.removeAll()
        ExternalServicesLog.info("Disconnected from Last.fm")
        await CloudKitSyncService.shared.recordExternalServicesChange()
        await publish(Self.idleState(for: updated))
    }

    // MARK: - Authorization

    func beginAuthorization(callback: String?) async throws -> LastFMAuthorizationRequest {
        guard let client = Self.client() else { throw LastFMAPIError(code: LastFMAPIError.invalidAPIKey, message: "") }
        do {
            let token = try await client.requestToken()
            guard let url = LastFMClient.authorizationURL(apiKey: client.apiKey, token: token, callback: callback) else {
                throw URLError(.badURL)
            }
            ExternalServicesLog.success("Approval page opened")
            return LastFMAuthorizationRequest(token: token, url: url)
        } catch {
            let problem = Self.problem(for: error)
            ExternalServicesLog.failure("Could not start approval: \(LastFMConnectionState.failed(problem).displayText)")
            await publish(.failed(problem))
            throw error
        }
    }

    /// Exchanges an approved token for a session. Safe to call even when the
    /// browser was closed early: an unapproved token simply fails.
    @discardableResult
    func completeAuthorization(token: String) async -> Bool {
        guard let client = Self.client() else { return false }
        await publish(.checking)
        do {
            let session = try await client.requestSession(token: token)
            var updated = LastFMCredentialStore.snapshot()
            updated.sessionKey = session.sessionKey
            updated.username = session.username
            updated.isEnabled = true
            LastFMCredentialStore.apply(updated)
            matchCache.removeAll()
            ExternalServicesLog.success("Connected as \(session.username)")
            await CloudKitSyncService.shared.recordExternalServicesChange()
            await publish(.connected(username: session.username), checked: true)
            return true
        } catch {
            let problem = Self.problem(for: error)
            ExternalServicesLog.failure("Approval failed: \(LastFMConnectionState.failed(problem).displayText)")
            await publish(.failed(problem))
            return false
        }
    }

    // MARK: - Connection check

    /// One check per launch is enough to show a reliable status without
    /// spending a request every time the app comes to the foreground.
    func verifyOnLaunchIfNeeded() async {
        guard !didVerifyOnLaunch else { return }
        didVerifyOnLaunch = true
        await verifyConnection()
    }

    func verifyConnection() async {
        let snapshot = LastFMCredentialStore.snapshot()
        guard snapshot.isEnabled, let client = Self.client(snapshot), !snapshot.sessionKey.isEmpty else {
            await publish(Self.idleState(for: snapshot))
            return
        }
        await publish(.checking)
        do {
            let username = try await client.authenticatedUsername(sessionKey: snapshot.sessionKey)
            if username != snapshot.username {
                LastFMCredentialStore.username = username
            }
            ExternalServicesLog.success("Connection OK, signed in as \(username)")
            await publish(.connected(username: username), checked: true)
        } catch {
            let problem = Self.problem(for: error)
            ExternalServicesLog.failure("Connection check failed: \(LastFMConnectionState.failed(problem).displayText)")
            await publish(.failed(problem), checked: true)
        }
    }

    /// Called when iCloud delivered different credentials.
    func credentialsDidChange() async {
        ExternalServicesLog.info("Last.fm settings received from iCloud")
        matchCache.removeAll()
        await verifyConnection()
    }

    // MARK: - Mixes

    /// Songs from the listener's recent Last.fm history that exist in the
    /// library, newest first. `nil` means Last.fm is not usable right now and
    /// the caller should fall back to the server.
    func recentSongs(limit: Int = 50) async -> [Song]? {
        await songs(label: "Recently Played", source: "recent tracks", limit: limit, maxPages: 5) { client, snapshot, page in
            try await client.recentTracks(username: snapshot.username, sessionKey: snapshot.sessionKey, page: page)
        }
    }

    /// The listener's most played tracks on Last.fm that exist in the library.
    func topSongs(limit: Int = 50) async -> [Song]? {
        await songs(label: "Frequently Played", source: "top tracks", limit: limit, maxPages: 3) { client, snapshot, page in
            try await client.topTracks(username: snapshot.username, sessionKey: snapshot.sessionKey, page: page)
        }
    }

    /// Pages through Last.fm until `limit` library songs are found. Tracks that
    /// are not in the library (other services, other servers) and repeats are
    /// skipped, so a few foreign scrobbles only mean one more page is read.
    private func songs(
        label: String,
        source: String,
        limit: Int,
        maxPages: Int,
        fetchPage: @Sendable (LastFMClient, LastFMCloudSnapshot, Int) async throws -> (tracks: [LastFMTrack], totalPages: Int)
    ) async -> [Song]? {
        let snapshot = LastFMCredentialStore.snapshot()
        guard snapshot.isEnabled else { return nil }
        guard !snapshot.sessionKey.isEmpty,
              !snapshot.username.isEmpty,
              let client = Self.client(snapshot)
        else {
            ExternalServicesLog.info("\(label): Last.fm not connected, using Navidrome")
            return nil
        }
        guard let serverKey = Self.activeServerKey() else { return nil }

        ExternalServicesLog.info("\(label): requesting \(source) from Last.fm")
        var result: [Song] = []
        var seenTracks = Set<String>()
        var seenSongs = Set<String>()
        var checked = 0
        var page = 1
        var totalPages = 1
        repeat {
            let fetched: (tracks: [LastFMTrack], totalPages: Int)
            do {
                fetched = try await fetchPage(client, snapshot, page)
            } catch {
                ExternalServicesLog.failure("\(label): request failed (\(LastFMConnectionState.failed(Self.problem(for: error)).displayText))")
                await handleDataError(error)
                return finish(label: label, songs: result, checked: checked, limit: limit)
            }
            totalPages = fetched.totalPages
            let fresh = fetched.tracks.filter { seenTracks.insert(LastFMTrackMatcher.key(for: $0)).inserted }
            checked += fresh.count
            for song in await resolve(fresh, serverKey: serverKey) where seenSongs.insert(song.id).inserted {
                result.append(song)
                if result.count == limit { break }
            }
            page += 1
        } while result.count < limit && page <= min(totalPages, maxPages) && !Task.isCancelled

        return finish(label: label, songs: result, checked: checked, limit: limit)
    }

    private func finish(label: String, songs: [Song], checked: Int, limit: Int) -> [Song]? {
        guard songs.count >= minimumMixSize else {
            ExternalServicesLog.failure("\(label): only \(songs.count) of \(checked) tracks are in your library, using Navidrome")
            return nil
        }
        ExternalServicesLog.success("\(label): \(songs.count) songs ready (\(checked) Last.fm tracks checked)")
        return songs
    }

    /// Resolves tracks in parallel and keeps their original order.
    private func resolve(_ tracks: [LastFMTrack], serverKey: String) async -> [Song] {
        var resolved = [Song?](repeating: nil, count: tracks.count)
        var pending: [(Int, LastFMTrack)] = []
        let now = Date()
        for (index, track) in tracks.enumerated() {
            let key = serverKey + "\u{1F}" + LastFMTrackMatcher.key(for: track)
            if let cached = matchCache[key], now.timeIntervalSince(cached.storedAt) < matchCacheLifetime {
                resolved[index] = cached.song
            } else {
                pending.append((index, track))
            }
        }

        await withTaskGroup(of: (Int, Song?).self) { group in
            var iterator = pending.makeIterator()
            let maxConcurrent = 6
            for _ in 0..<maxConcurrent {
                guard let (index, track) = iterator.next() else { break }
                group.addTask { (index, await Self.findSong(for: track)) }
            }
            for await (index, song) in group {
                resolved[index] = song
                let key = serverKey + "\u{1F}" + LastFMTrackMatcher.key(for: tracks[index])
                matchCache[key] = CachedMatch(song: song, storedAt: now)
                if let (nextIndex, nextTrack) = iterator.next() {
                    group.addTask { (nextIndex, await Self.findSong(for: nextTrack)) }
                }
            }
        }
        return resolved.compactMap { $0 }
    }

    private nonisolated static func findSong(for track: LastFMTrack) async -> Song? {
        for query in LastFMTrackMatcher.searchQueries(for: track) {
            guard !Task.isCancelled else { return nil }
            guard let result = try? await SubsonicAPIService.shared.search(query: query) else { continue }
            if let match = LastFMTrackMatcher.bestMatch(for: track, in: result.song ?? []) {
                return match
            }
        }
        return nil
    }

    private func handleDataError(_ error: Error) async {
        guard let apiError = error as? LastFMAPIError else { return }
        switch apiError.code {
        case LastFMAPIError.invalidSessionKey, LastFMAPIError.invalidAPIKey,
             LastFMAPIError.suspendedAPIKey, LastFMAPIError.authenticationFailed,
             LastFMAPIError.invalidSignature:
            await publish(.failed(Self.problem(for: error)), checked: true)
        default:
            break
        }
    }

    // MARK: - Helpers

    private nonisolated static func client(_ snapshot: LastFMCloudSnapshot = LastFMCredentialStore.snapshot()) -> LastFMClient? {
        guard !snapshot.apiKey.isEmpty, !snapshot.sharedSecret.isEmpty else { return nil }
        return LastFMClient(apiKey: snapshot.apiKey, sharedSecret: snapshot.sharedSecret)
    }

    private nonisolated static func activeServerKey() -> String? {
        guard let server = SubsonicAPIService.shared.activeServer else { return nil }
        return server.stableId.isEmpty ? server.id.uuidString : server.stableId
    }

    private nonisolated static func idleState(for snapshot: LastFMCloudSnapshot) -> LastFMConnectionState {
        if snapshot.apiKey.isEmpty || snapshot.sharedSecret.isEmpty { return .notConfigured }
        if snapshot.sessionKey.isEmpty { return .notConnected }
        return snapshot.username.isEmpty ? .notConnected : .connected(username: snapshot.username)
    }

    private nonisolated static func problem(for error: Error) -> LastFMConnectionProblem {
        if let apiError = error as? LastFMAPIError {
            switch apiError.code {
            case LastFMAPIError.invalidAPIKey, LastFMAPIError.suspendedAPIKey:
                return .invalidAPIKey
            case LastFMAPIError.invalidSignature, LastFMAPIError.authenticationFailed:
                return .invalidSecret
            case LastFMAPIError.invalidSessionKey:
                return .accessRevoked
            case LastFMAPIError.unauthorizedToken:
                return .authorizationIncomplete
            default:
                return .other(apiError.message)
            }
        }
        if error is URLError { return .unreachable }
        return .other(error.localizedDescription)
    }

    private func publish(_ state: LastFMConnectionState, checked: Bool = false) async {
        await MainActor.run {
            status.state = state
            if checked { status.lastChecked = Date() }
        }
    }
}
