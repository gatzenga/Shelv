import SwiftUI

struct PersonalizedSongSwipeActionsModifier: ViewModifier {
    let song: Song
    let isOffline: Bool
    let isFavorite: Bool
    let accentColor: Color
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.swipeLeftPrimary) private var leftPrimary = PersonalizationSwipeAction.favorite.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeLeftSecondary) private var leftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightPrimary) private var rightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightSecondary) private var rightSecondary = PersonalizationSwipeAction.addToQueue.rawValue

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                swipeButton(for: .leftPrimary)
                swipeButton(for: .leftSecondary)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeButton(for: .rightPrimary)
                swipeButton(for: .rightSecondary)
            }
    }

    @ViewBuilder
    private func swipeButton(for slot: PersonalizationSwipeSlot) -> some View {
        switch action(for: slot) {
        case .none:
            EmptyView()
        case .favorite:
            if !isOffline && showFavoriteActions {
                Button {
                    onFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.slash" : "heart.fill")
                }
                .tint(.pink)
            }
        case .addToPlaylist:
            if !isOffline && showPlaylistActions {
                Button {
                    onAddToPlaylist()
                } label: {
                    Image(systemName: "music.note.list")
                }
                .tint(accentColor)
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

    private func action(for slot: PersonalizationSwipeSlot) -> PersonalizationSwipeAction {
        switch slot {
        case .leftPrimary:
            return PersonalizationSwipeAction(rawValue: leftPrimary).flatMap(normalized) ?? .none
        case .leftSecondary:
            return PersonalizationSwipeAction(rawValue: leftSecondary).flatMap(normalized) ?? .none
        case .rightPrimary:
            return PersonalizationSwipeAction(rawValue: rightPrimary).flatMap(normalized) ?? .none
        case .rightSecondary:
            return PersonalizationSwipeAction(rawValue: rightSecondary).flatMap(normalized) ?? .none
        }
    }

    private func normalized(_ action: PersonalizationSwipeAction) -> PersonalizationSwipeAction {
        switch action {
        case .favorite:
            return showFavoriteActions ? action : .none
        case .addToPlaylist:
            return showPlaylistActions ? action : .none
        case .none, .playNext, .addToQueue:
            return action
        }
    }
}

extension View {
    func personalizedSongSwipeActions(
        song: Song,
        isOffline: Bool,
        isFavorite: Bool,
        accentColor: Color,
        onFavorite: @escaping () -> Void,
        onAddToPlaylist: @escaping () -> Void,
        onPlayNext: @escaping () -> Void,
        onAddToQueue: @escaping () -> Void
    ) -> some View {
        modifier(
            PersonalizedSongSwipeActionsModifier(
                song: song,
                isOffline: isOffline,
                isFavorite: isFavorite,
                accentColor: accentColor,
                onFavorite: onFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onPlayNext: onPlayNext,
                onAddToQueue: onAddToQueue
            )
        )
    }
}
