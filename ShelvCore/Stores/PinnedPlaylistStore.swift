import Foundation
import Combine

/// Angepinnte Playlists pro Server. Geordnet — Index 0 = zuletzt angepinnt (zuoberst).
/// Persistenz analog `offlinePlaylistIds`: `shelv_pinned_playlists_<serverId>`.
/// Geteilt von iOS + macOS.
@MainActor
final class PinnedPlaylistStore: ObservableObject {
    static let shared = PinnedPlaylistStore()

    @Published private(set) var pinnedIds: [String] = []

    private var serverId: String = ""

    private init() {}

    func setActiveServer(_ serverId: String) {
        guard self.serverId != serverId else { return }
        self.serverId = serverId
        load()
    }

    func isPinned(_ id: String) -> Bool { pinnedIds.contains(id) }

    /// Sortier-Rang: 0 = zuoberst (zuletzt angepinnt), nil = nicht angepinnt.
    func pinRank(_ id: String) -> Int? { pinnedIds.firstIndex(of: id) }

    func togglePin(_ id: String) {
        if let idx = pinnedIds.firstIndex(of: id) {
            pinnedIds.remove(at: idx)
        } else {
            pinnedIds.insert(id, at: 0)   // zuletzt angepinnt zuoberst
        }
        save()
    }

    private var key: String { "shelv_pinned_playlists_\(serverId)" }

    private func load() {
        guard !serverId.isEmpty else { pinnedIds = []; return }
        pinnedIds = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private func save() {
        guard !serverId.isEmpty else { return }
        UserDefaults.standard.set(pinnedIds, forKey: key)
    }
}
