import Combine
import Foundation

final class RadioMetadataService: ObservableObject {
    static let shared = RadioMetadataService()

    private static let decoder = JSONDecoder()

    @Published private(set) var currentMetadata: RadioNowPlayingMetadata?
    @Published private(set) var isConnecting = false
    @Published private(set) var isOnline = false

    private var timer: AnyCancellable?
    private var generation = 0
    private var activeAPIURL: String?
    private var activeStreamURL: String?

    private init() {}

    func startPolling(station item: RadioStationDisplayItem) {
        if item.metadata.useAzuraCastAPI,
           !item.metadata.azuraCastAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startAzuraCastPolling(apiURL: item.metadata.azuraCastAPIURL, streamURL: item.streamURL, fallbackStationName: item.name)
        } else {
            startICYPolling(streamURL: item.streamURL, fallbackStationName: item.name)
        }
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
        activeAPIURL = nil
        activeStreamURL = nil
        generation += 1
        DispatchQueue.main.async {
            self.isConnecting = false
            self.isOnline = false
        }
    }

    private func startAzuraCastPolling(apiURL: String, streamURL: String, fallbackStationName: String) {
        let trimmed = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            startICYPolling(streamURL: streamURL, fallbackStationName: fallbackStationName)
            return
        }
        let trimmedStreamURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if activeAPIURL == trimmed,
           activeStreamURL == trimmedStreamURL,
           timer != nil {
            return
        }

        stopPolling()
        activeAPIURL = trimmed
        activeStreamURL = trimmedStreamURL
        let gen = generation
        DispatchQueue.main.async {
            self.currentMetadata = RadioNowPlayingMetadata(stationName: fallbackStationName)
            self.isConnecting = true
            self.isOnline = false
        }

        Task { await self.fetchAzuraCastNowPlaying(apiURL: trimmed, fallbackStationName: fallbackStationName, generation: gen) }
        timer = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let gen = self.generation
                Task { await self.fetchAzuraCastNowPlaying(apiURL: trimmed, fallbackStationName: fallbackStationName, generation: gen) }
            }
    }

    private func startICYPolling(streamURL: String, fallbackStationName: String) {
        let trimmed = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeAPIURL == nil,
           activeStreamURL == trimmed,
           timer != nil {
            return
        }

        stopPolling()
        activeAPIURL = nil
        activeStreamURL = trimmed
        let gen = generation
        DispatchQueue.main.async {
            self.currentMetadata = RadioNowPlayingMetadata(stationName: fallbackStationName)
            self.isConnecting = false
            self.isOnline = true
        }

        Task { await self.fetchICYMetadata(streamURL: trimmed, fallbackStationName: fallbackStationName, generation: gen) }
        timer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let gen = self.generation
                Task { await self.fetchICYMetadata(streamURL: trimmed, fallbackStationName: fallbackStationName, generation: gen) }
            }
    }

    private func fetchAzuraCastNowPlaying(apiURL: String, fallbackStationName: String, generation: Int) async {
        guard let url = URL(string: apiURL) else { return }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try Self.decoder.decode(AzuraCastNowPlayingResponse.self, from: data)
            guard self.generation == generation else { return }

            let artURL = response.nowPlaying?.song?.art ?? stationArtURL(apiURL: url, shortcode: response.station.shortcode)
            let metadata = RadioNowPlayingMetadata(
                stationName: response.station.name.isEmpty ? fallbackStationName : response.station.name,
                title: response.nowPlaying?.song?.title.nilIfEmpty,
                artist: response.nowPlaying?.song?.artist.nilIfEmpty,
                album: response.nowPlaying?.song?.album?.nilIfEmpty,
                artworkURL: artURL,
                isLive: response.live?.isLive ?? false
            )
            await MainActor.run {
                self.currentMetadata = metadata
                self.isConnecting = false
                self.isOnline = response.isOnline ?? true
            }
        } catch {
            guard self.generation == generation else { return }
            if let streamURL = activeStreamURL, !streamURL.isEmpty {
                await fetchICYMetadata(streamURL: streamURL, fallbackStationName: fallbackStationName, generation: generation)
                return
            }
            await MainActor.run {
                self.isConnecting = false
                self.isOnline = false
            }
        }
    }

    private func fetchICYMetadata(streamURL: String, fallbackStationName: String, generation: Int) async {
        guard let url = URL(string: streamURL) else { return }
        let (stationName, track) = await ICYMetadataFetcher.fetch(from: url)
        guard self.generation == generation else { return }
        let resolvedStationName = stationName?.nilIfEmpty ?? fallbackStationName
        await MainActor.run {
            if let track {
                self.currentMetadata = RadioNowPlayingMetadata(
                    stationName: resolvedStationName,
                    title: track.title.nilIfEmpty,
                    artist: track.artist.nilIfEmpty,
                    album: nil,
                    artworkURL: nil,
                    isLive: false
                )
            } else if let current = self.currentMetadata,
                      current.displayTitle != nil || current.displayArtist != nil {
                self.currentMetadata = RadioNowPlayingMetadata(
                    stationName: resolvedStationName,
                    title: current.title,
                    artist: current.artist,
                    album: nil,
                    artworkURL: nil,
                    isLive: false
                )
            } else {
                self.currentMetadata = RadioNowPlayingMetadata(stationName: resolvedStationName)
            }
            self.isConnecting = false
            self.isOnline = true
        }
    }

    private func stationArtURL(apiURL: URL, shortcode: String?) -> String? {
        guard let shortcode,
              let components = URLComponents(url: apiURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme,
              let host = components.host
        else { return nil }
        var authority = host
        if let port = components.port {
            authority += ":\(port)"
        }
        return "\(scheme)://\(authority)/api/station/\(shortcode)/art"
    }
}

private struct AzuraCastNowPlayingResponse: Decodable {
    let station: StationInfo
    let nowPlaying: NowPlayingTrack?
    let live: LiveInfo?
    let isOnline: Bool?

    enum CodingKeys: String, CodingKey {
        case station
        case nowPlaying = "now_playing"
        case live
        case isOnline = "is_online"
    }

    struct StationInfo: Decodable {
        let name: String
        let shortcode: String?
    }

    struct NowPlayingTrack: Decodable {
        let song: SongInfo?
    }

    struct SongInfo: Decodable {
        let title: String
        let artist: String
        let art: String?
        let album: String?
    }

    struct LiveInfo: Decodable {
        let isLive: Bool

        enum CodingKeys: String, CodingKey {
            case isLive = "is_live"
        }
    }
}

private struct ICYTrackInfo {
    let title: String
    let artist: String
}

private final class ICYMetadataFetcher: NSObject, URLSessionDataDelegate {
    private static let maxBufferedBytes = 2 * 1024 * 1024
    private static let streamTitleSeparators = [
        " - ",
        " – ",
        " — ",
        " − ",
        " ‐ ",
        " ‑ "
    ]

    private var receivedData = Data()
    private var metaint: Int?
    private var icyName: String?
    private var continuation: CheckedContinuation<(String?, ICYTrackInfo?), Never>?
    private var completed = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    static func fetch(from url: URL) async -> (String?, ICYTrackInfo?) {
        await withCheckedContinuation { continuation in
            let fetcher = ICYMetadataFetcher()
            fetcher.continuation = continuation

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 8
            let session = URLSession(configuration: config, delegate: fetcher, delegateQueue: nil)
            fetcher.session = session

            var request = URLRequest(url: url)
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")

            let task = session.dataTask(with: request)
            fetcher.task = task
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            icyName = header("icy-name", in: http)
            if let metaintString = header("icy-metaint", in: http) {
                metaint = Int(metaintString)
            }
        }
        if metaint == nil {
            completionHandler(.cancel)
            finish()
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        if parsedTrack() != nil || receivedData.count >= Self.maxBufferedBytes {
            finish()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        let result = (icyName, parsedTrack())
        let continuation = continuation
        self.continuation = nil
        task?.cancel()
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation?.resume(returning: result)
    }

    private func header(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).caseInsensitiveCompare(name) == .orderedSame else { continue }
            if let string = value as? String { return string }
            return String(describing: value)
        }
        return nil
    }

    private func parsedTrack() -> ICYTrackInfo? {
        guard let metaint, metaint > 0 else { return nil }
        var metadataOffset = metaint

        while receivedData.count > metadataOffset {
            let lengthByte = receivedData[metadataOffset]
            let metadataLength = Int(lengthByte) * 16
            let metadataStart = metadataOffset + 1
            let metadataEnd = metadataStart + metadataLength
            guard receivedData.count >= metadataEnd else { return nil }
            defer { metadataOffset = metadataEnd + metaint }
            guard metadataLength > 0 else { continue }

            let metadata = receivedData[metadataStart..<metadataEnd]
            guard let raw = String(bytes: metadata, encoding: .utf8) ?? String(bytes: metadata, encoding: .isoLatin1),
                  let streamTitle = Self.streamTitle(from: raw)
            else { continue }
            return Self.trackInfo(from: streamTitle)
        }

        return nil
    }

    private static func streamTitle(from raw: String) -> String? {
        guard let start = raw.range(of: "StreamTitle='"),
              let end = raw[start.upperBound...].range(of: "'")
        else { return nil }
        let streamTitle = String(raw[start.upperBound..<end.lowerBound])
        return streamTitle.nilIfEmpty
    }

    private static func trackInfo(from streamTitle: String) -> ICYTrackInfo {
        for separator in Self.streamTitleSeparators {
            guard let range = streamTitle.range(of: separator) else { continue }
            let artist = String(streamTitle[..<range.lowerBound]).normalizedRadioDashText
            let title = String(streamTitle[range.upperBound...]).normalizedRadioDashText
            guard !title.isEmpty else { break }
            return ICYTrackInfo(title: title, artist: artist)
        }
        return ICYTrackInfo(title: streamTitle.normalizedRadioDashText, artist: "")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedRadioDashText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "‐", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
    }
}
