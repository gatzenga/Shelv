import Foundation

@MainActor
final class AudioPlayerFormatProbe {
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    func probe(
        song: Song,
        url: URL,
        engine: PlayerEngine,
        update: @escaping @MainActor (ActualStreamFormat?) -> Void
    ) {
        cancel()
        let songDuration = Double(song.duration ?? 0)

        // Sofortiger, provisorischer Wert: Bitrate exakt, Codec ggf. noch aus Dateiendung/MIME geraten.
        var initialBitrate: Int? = nil
        if url.isFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0, songDuration > 1 { initialBitrate = Int(Double(size) * 8 / songDuration / 1000) }
            let ext = url.pathExtension.uppercased()
            update(ActualStreamFormat(codecLabel: ext.isEmpty ? "?" : ext, bitrateKbps: initialBitrate))
        } else {
            update(nil)
        }

        task = Task { [weak engine, update] in
            guard let engine else { return }
            var bitrate = initialBitrate

            // Remote: HEAD fuer exakte Bitrate (Content-Length) + provisorischer Codec.
            if !url.isFileURL {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                req.timeoutInterval = 8
                if let (_, response) = try? await URLSession.shared.data(for: req),
                   let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    let codec = ActualStreamFormat.codecLabel(forMime: http.mimeType)
                    let length = http.expectedContentLength
                    if length > 0, songDuration > 1 { bitrate = Int(Double(length) * 8 / songDuration / 1000) }
                    if Task.isCancelled { return }
                    update(ActualStreamFormat(codecLabel: codec, bitrateKbps: bitrate))
                }
            }

            // Echten Codec aus dem geladenen Player-Track nachziehen (ALAC vs. AAC).
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if let real = await engine.currentAudioFormat(matching: url) {
                    if Task.isCancelled { return }
                    let finalBitrate = bitrate ?? real.bitrateKbps
                    update(ActualStreamFormat(codecLabel: real.codec, bitrateKbps: finalBitrate))
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
