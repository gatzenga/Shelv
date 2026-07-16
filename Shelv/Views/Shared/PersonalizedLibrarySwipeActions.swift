import SwiftUI

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

    @AppStorage(PersonalizationPreferenceKey.playlistSwipeLeftPrimary) private var leftPrimary = PersonalizationSwipeAction.pin.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeLeftSecondary) private var leftSecondary = PersonalizationSwipeAction.delete.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeRightPrimary) private var rightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeRightSecondary) private var rightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    @AppStorage(PersonalizationPreferenceKey.playlistSwipeRightTertiary) private var rightTertiary = PersonalizationSwipeAction.download.rawValue

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
            rawValue = leftPrimary
        case .playlistLeftSecondary:
            rawValue = leftSecondary
        case .playlistRightPrimary:
            rawValue = rightPrimary
        case .playlistRightSecondary:
            rawValue = rightSecondary
        case .playlistRightTertiary:
            rawValue = rightTertiary
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

    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeLeftPrimary) private var leftPrimary = PersonalizationSwipeAction.favorite.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeLeftSecondary) private var leftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeRightPrimary) private var rightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeRightSecondary) private var rightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    @AppStorage(PersonalizationPreferenceKey.albumArtistSwipeRightTertiary) private var rightTertiary = PersonalizationSwipeAction.download.rawValue

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
                Image(systemName: isFavorite ? "heart.slash" : "heart.fill")
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
            rawValue = leftPrimary
        case .albumArtistLeftSecondary:
            rawValue = leftSecondary
        case .albumArtistRightPrimary:
            rawValue = rightPrimary
        case .albumArtistRightSecondary:
            rawValue = rightSecondary
        case .albumArtistRightTertiary:
            rawValue = rightTertiary
        default:
            return .none
        }

        return PersonalizationSwipeAction(rawValue: rawValue).flatMap(normalized) ?? .none
    }

    private func normalized(_ action: PersonalizationSwipeAction) -> PersonalizationSwipeAction {
        switch action {
        case .favorite:
            return !isOffline && showFavoriteActions ? action : .none
        case .addToPlaylist:
            return !isOffline && showPlaylistActions ? action : .none
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
