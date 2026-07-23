import Combine
import Foundation

@MainActor
final class MacPersonalizationVisibilityStore: ObservableObject {
    static let shared = MacPersonalizationVisibilityStore()

    @Published var showPlaylistsInSidebar: Bool {
        didSet {
            persist(
                showPlaylistsInSidebar,
                forKey: PersonalizationPreferenceKey.showPlaylistsTab
            )
        }
    }

    @Published var showPlaylistActions: Bool {
        didSet {
            persist(
                showPlaylistActions,
                forKey: PersonalizationPreferenceKey.showPlaylistActions
            )
        }
    }

    @Published var showFavoritesInLibrary: Bool {
        didSet {
            persist(
                showFavoritesInLibrary,
                forKey: PersonalizationPreferenceKey.showFavoritesInLibrary
            )
        }
    }

    @Published var showFavoriteActions: Bool {
        didSet {
            persist(
                showFavoriteActions,
                forKey: PersonalizationPreferenceKey.showFavoriteActions
            )
        }
    }

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showPlaylistsInSidebar = Self.boolValue(
            forKey: PersonalizationPreferenceKey.showPlaylistsTab,
            in: defaults
        )
        showPlaylistActions = Self.boolValue(
            forKey: PersonalizationPreferenceKey.showPlaylistActions,
            in: defaults
        )
        showFavoritesInLibrary = Self.boolValue(
            forKey: PersonalizationPreferenceKey.showFavoritesInLibrary,
            in: defaults
        )
        showFavoriteActions = Self.boolValue(
            forKey: PersonalizationPreferenceKey.showFavoriteActions,
            in: defaults
        )

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadFromDefaults()
            }
        }
    }

    private func reloadFromDefaults() {
        update(
            \.showPlaylistsInSidebar,
            fromKey: PersonalizationPreferenceKey.showPlaylistsTab
        )
        update(
            \.showPlaylistActions,
            fromKey: PersonalizationPreferenceKey.showPlaylistActions
        )
        update(
            \.showFavoritesInLibrary,
            fromKey: PersonalizationPreferenceKey.showFavoritesInLibrary
        )
        update(
            \.showFavoriteActions,
            fromKey: PersonalizationPreferenceKey.showFavoriteActions
        )
    }

    private func update(
        _ keyPath: ReferenceWritableKeyPath<MacPersonalizationVisibilityStore, Bool>,
        fromKey key: String
    ) {
        let value = Self.boolValue(forKey: key, in: defaults)
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    private func persist(_ value: Bool, forKey key: String) {
        guard Self.boolValue(forKey: key, in: defaults) != value else { return }
        defaults.set(value, forKey: key)
    }

    private static func boolValue(forKey key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
