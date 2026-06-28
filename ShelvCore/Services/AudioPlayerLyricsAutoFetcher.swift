import Foundation

final class AudioPlayerLyricsAutoFetcher {
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    func schedule(song: Song?, enabled: Bool) {
        cancel()
        guard enabled,
              !UserDefaults.standard.bool(forKey: "offlineModeEnabled"),
              let song,
              let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString
        else { return }

        task = Task(priority: .utility) { [song, serverId] in
            await LyricsService.shared.setup()
            guard !Task.isCancelled else { return }
            _ = await LyricsService.shared.fetchAndSave(song: song, serverId: serverId)
        }
    }
}
