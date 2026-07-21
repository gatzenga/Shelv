import SwiftUI

struct PersonalizationSwipeConfiguration: Equatable {
    var showFavoriteActions = true
    var showPlaylistActions = true
    var showInstantMixActions = true

    var songLeftPrimary = PersonalizationSwipeAction.favorite.rawValue
    var songLeftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    var songRightPrimary = PersonalizationSwipeAction.playNext.rawValue
    var songRightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    var songRightTertiary = PersonalizationSwipeAction.instantMix.rawValue

    var playlistLeftPrimary = PersonalizationSwipeAction.pin.rawValue
    var playlistLeftSecondary = PersonalizationSwipeAction.delete.rawValue
    var playlistRightPrimary = PersonalizationSwipeAction.playNext.rawValue
    var playlistRightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    var playlistRightTertiary = PersonalizationSwipeAction.download.rawValue

    var albumArtistLeftPrimary = PersonalizationSwipeAction.favorite.rawValue
    var albumArtistLeftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    var albumArtistRightPrimary = PersonalizationSwipeAction.playNext.rawValue
    var albumArtistRightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    var albumArtistRightTertiary = PersonalizationSwipeAction.download.rawValue
}

private struct PersonalizationSwipeConfigurationKey: EnvironmentKey {
    static let defaultValue = PersonalizationSwipeConfiguration()
}

extension EnvironmentValues {
    var personalizationSwipeConfiguration: PersonalizationSwipeConfiguration {
        get { self[PersonalizationSwipeConfigurationKey.self] }
        set { self[PersonalizationSwipeConfigurationKey.self] = newValue }
    }
}

private struct PersonalizationSwipeEnvironmentModifier: ViewModifier {
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true

    @AppStorage(PersonalizationPreferenceKey.swipeLeftPrimary) private var songLeftPrimary = PersonalizationSwipeAction.favorite.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeLeftSecondary) private var songLeftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightPrimary) private var songRightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightSecondary) private var songRightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightTertiary) private var songRightTertiary = PersonalizationSwipeAction.instantMix.rawValue

    @AppStorage(PersonalizationPreferenceKey.playlistSwipeLeftPrimary) private var playlistLeftPrimary = PersonalizationSwipeAction.pin.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeLeftSecondary) private var playlistLeftSecondary = PersonalizationSwipeAction.delete.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeRightPrimary) private var playlistRightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeRightSecondary) private var playlistRightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeRightTertiary) private var playlistRightTertiary = PersonalizationSwipeAction.download.rawValue

    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeLeftPrimary) private var albumArtistLeftPrimary = PersonalizationSwipeAction.favorite.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeLeftSecondary) private var albumArtistLeftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeRightPrimary) private var albumArtistRightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeRightSecondary) private var albumArtistRightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeRightTertiary) private var albumArtistRightTertiary = PersonalizationSwipeAction.download.rawValue

    func body(content: Content) -> some View {
        content.environment(
            \.personalizationSwipeConfiguration,
            PersonalizationSwipeConfiguration(
                showFavoriteActions: showFavoriteActions,
                showPlaylistActions: showPlaylistActions,
                showInstantMixActions: showInstantMixActions,
                songLeftPrimary: songLeftPrimary,
                songLeftSecondary: songLeftSecondary,
                songRightPrimary: songRightPrimary,
                songRightSecondary: songRightSecondary,
                songRightTertiary: songRightTertiary,
                playlistLeftPrimary: playlistLeftPrimary,
                playlistLeftSecondary: playlistLeftSecondary,
                playlistRightPrimary: playlistRightPrimary,
                playlistRightSecondary: playlistRightSecondary,
                playlistRightTertiary: playlistRightTertiary,
                albumArtistLeftPrimary: albumArtistLeftPrimary,
                albumArtistLeftSecondary: albumArtistLeftSecondary,
                albumArtistRightPrimary: albumArtistRightPrimary,
                albumArtistRightSecondary: albumArtistRightSecondary,
                albumArtistRightTertiary: albumArtistRightTertiary
            )
        )
    }
}

enum PersonalizedDownloadSwipeState: Equatable {
    case hidden
    case download
    case delete
}

struct PersonalizedPlaylistSwipeActionsModifier: ViewModifier {
    let isPinned: Bool
    let canDelete: Bool
    let downloadState: PersonalizedDownloadSwipeState
    let accentColor: Color
    let onPin: () -> Void
    let onDelete: () -> Void
    let onDownload: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    @Environment(\.personalizationSwipeConfiguration) private var personalization

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                swipeButton(for: .playlistLeftPrimary)
                swipeButton(for: .playlistLeftSecondary)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeButton(for: .playlistRightPrimary)
                swipeButton(for: .playlistRightSecondary)
                swipeButton(for: .playlistRightTertiary)
            }
    }

    @ViewBuilder
    private func swipeButton(for slot: PersonalizationSwipeSlot) -> some View {
        switch action(for: slot) {
        case .none, .favorite, .addToPlaylist, .instantMix:
            EmptyView()
        case .pin:
            Button {
                onPin()
            } label: {
                Image(systemName: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(accentColor)
        case .download:
            downloadButton()
        case .delete:
            if canDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .tint(.red)
            }
        case .playNext:
            Button {
                onPlayNext()
            } label: {
                Image(systemName: "text.insert")
            }
            .tint(.orange)
        case .addToQueue:
            Button {
                onAddToQueue()
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .tint(accentColor)
        }
    }

    @ViewBuilder
    private func downloadButton() -> some View {
        switch downloadState {
        case .hidden:
            EmptyView()
        case .download:
            Button {
                onDownload()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .tint(accentColor)
        case .delete:
            Button {
                onDownload()
            } label: {
                Image(systemName: DownloadActionSymbols.filledDelete)
            }
            .tint(.red)
        }
    }

    private func action(for slot: PersonalizationSwipeSlot) -> PersonalizationSwipeAction {
        let rawValue: String
        switch slot {
        case .playlistLeftPrimary:
            rawValue = personalization.playlistLeftPrimary
        case .playlistLeftSecondary:
            rawValue = personalization.playlistLeftSecondary
        case .playlistRightPrimary:
            rawValue = personalization.playlistRightPrimary
        case .playlistRightSecondary:
            rawValue = personalization.playlistRightSecondary
        case .playlistRightTertiary:
            rawValue = personalization.playlistRightTertiary
        default:
            return .none
        }

        return PersonalizationSwipeAction(rawValue: rawValue).flatMap(normalized) ?? .none
    }

    private func normalized(_ action: PersonalizationSwipeAction) -> PersonalizationSwipeAction {
        switch action {
        case .pin, .playNext, .addToQueue:
            return action
        case .download:
            return downloadState == .hidden ? .none : action
        case .delete:
            return canDelete ? action : .none
        case .none, .favorite, .addToPlaylist, .instantMix:
            return .none
        }
    }
}

struct PersonalizedAlbumArtistSwipeActionsModifier: ViewModifier {
    let isOffline: Bool
    let isFavorite: Bool
    let downloadState: PersonalizedDownloadSwipeState
    let accentColor: Color
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onDownload: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    @Environment(\.personalizationSwipeConfiguration) private var personalization

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                swipeButton(for: .albumArtistLeftPrimary)
                swipeButton(for: .albumArtistLeftSecondary)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeButton(for: .albumArtistRightPrimary)
                swipeButton(for: .albumArtistRightSecondary)
                swipeButton(for: .albumArtistRightTertiary)
            }
    }

    @ViewBuilder
    private func swipeButton(for slot: PersonalizationSwipeSlot) -> some View {
        switch action(for: slot) {
        case .none, .pin, .delete, .instantMix:
            EmptyView()
        case .favorite:
            Button {
                onFavorite()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
            }
            .tint(.pink)
        case .addToPlaylist:
            Button {
                onAddToPlaylist()
            } label: {
                Image(systemName: "music.note.list")
            }
            .tint(accentColor)
        case .download:
            downloadButton()
        case .playNext:
            Button {
                onPlayNext()
            } label: {
                Image(systemName: "text.insert")
            }
            .tint(.orange)
        case .addToQueue:
            Button {
                onAddToQueue()
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .tint(accentColor)
        }
    }

    @ViewBuilder
    private func downloadButton() -> some View {
        switch downloadState {
        case .hidden:
            EmptyView()
        case .download:
            Button {
                onDownload()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .tint(accentColor)
        case .delete:
            Button {
                onDownload()
            } label: {
                Image(systemName: DownloadActionSymbols.filledDelete)
            }
            .tint(.red)
        }
    }

    private func action(for slot: PersonalizationSwipeSlot) -> PersonalizationSwipeAction {
        let rawValue: String
        switch slot {
        case .albumArtistLeftPrimary:
            rawValue = personalization.albumArtistLeftPrimary
        case .albumArtistLeftSecondary:
            rawValue = personalization.albumArtistLeftSecondary
        case .albumArtistRightPrimary:
            rawValue = personalization.albumArtistRightPrimary
        case .albumArtistRightSecondary:
            rawValue = personalization.albumArtistRightSecondary
        case .albumArtistRightTertiary:
            rawValue = personalization.albumArtistRightTertiary
        default:
            return .none
        }

        return PersonalizationSwipeAction(rawValue: rawValue).flatMap(normalized) ?? .none
    }

    private func normalized(_ action: PersonalizationSwipeAction) -> PersonalizationSwipeAction {
        switch action {
        case .favorite:
            return !isOffline && personalization.showFavoriteActions ? action : .none
        case .addToPlaylist:
            return !isOffline && personalization.showPlaylistActions ? action : .none
        case .download:
            return downloadState == .hidden ? .none : action
        case .playNext, .addToQueue:
            return action
        case .none, .pin, .delete, .instantMix:
            return .none
        }
    }
}

extension View {
    func personalizationSwipeEnvironment() -> some View {
        modifier(PersonalizationSwipeEnvironmentModifier())
    }

    func personalizedPlaylistSwipeActions(
        isPinned: Bool,
        canDelete: Bool,
        downloadState: PersonalizedDownloadSwipeState,
        accentColor: Color,
        onPin: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onPlayNext: @escaping () -> Void,
        onAddToQueue: @escaping () -> Void
    ) -> some View {
        modifier(
            PersonalizedPlaylistSwipeActionsModifier(
                isPinned: isPinned,
                canDelete: canDelete,
                downloadState: downloadState,
                accentColor: accentColor,
                onPin: onPin,
                onDelete: onDelete,
                onDownload: onDownload,
                onPlayNext: onPlayNext,
                onAddToQueue: onAddToQueue
            )
        )
    }

    func personalizedAlbumArtistSwipeActions(
        isOffline: Bool,
        isFavorite: Bool,
        downloadState: PersonalizedDownloadSwipeState,
        accentColor: Color,
        onFavorite: @escaping () -> Void,
        onAddToPlaylist: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onPlayNext: @escaping () -> Void,
        onAddToQueue: @escaping () -> Void
    ) -> some View {
        modifier(
            PersonalizedAlbumArtistSwipeActionsModifier(
                isOffline: isOffline,
                isFavorite: isFavorite,
                downloadState: downloadState,
                accentColor: accentColor,
                onFavorite: onFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onDownload: onDownload,
                onPlayNext: onPlayNext,
                onAddToQueue: onAddToQueue
            )
        )
    }
}
