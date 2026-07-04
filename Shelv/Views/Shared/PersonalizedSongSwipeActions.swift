import SwiftUI

struct PersonalizedSongSwipeActionsModifier: ViewModifier {
    let song: Song
    let isOffline: Bool
    let isFavorite: Bool
    let accentColor: Color
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    @State private var songInfoSong: Song?
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage(PersonalizationPreferenceKey.swipeLeftPrimary) private var leftPrimary = PersonalizationSwipeAction.favorite.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeLeftSecondary) private var leftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightPrimary) private var rightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightSecondary) private var rightSecondary = PersonalizationSwipeAction.addToQueue.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightTertiary) private var rightTertiary = PersonalizationSwipeAction.instantMix.rawValue

    func body(content: Content) -> some View {
        content
            .contextMenu {
                songContextMenuItems
            }
            .sheet(item: $songInfoSong) { song in
                SongInfoSheetView(song: song, initialTab: .details)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                swipeButton(for: .leftPrimary)
                swipeButton(for: .leftSecondary)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeButton(for: .rightPrimary)
                swipeButton(for: .rightSecondary)
                swipeButton(for: .rightTertiary)
            }
    }

    @ViewBuilder
    private var songContextMenuItems: some View {
        Button {
            onPlay()
        } label: {
            Label(String(localized: "play"), systemImage: "play.fill")
        }

        if !isOffline && showInstantMixActions {
            Button {
                InstantMixService.playSongMix(for: song)
            } label: {
                Label(String(localized: "instant_mix"), systemImage: "sparkles")
            }
        }

        Divider()

        Button {
            onPlayNext()
        } label: {
            Label(String(localized: "play_next"), systemImage: "text.insert")
        }

        Button {
            onAddToQueue()
        } label: {
            Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
        }

        if !isOffline && (showFavoriteActions || showPlaylistActions) {
            Divider()

            if showFavoriteActions {
                Button {
                    onFavorite()
                } label: {
                    Label(
                        isFavorite ? String(localized: "unfavorite") : String(localized: "favorite"),
                        systemImage: isFavorite ? "heart.slash" : "heart"
                    )
                }
            }

            if showPlaylistActions {
                Button {
                    onAddToPlaylist()
                } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "music.note.list")
                }
            }
        }

        Divider()

        Button {
            songInfoSong = song
        } label: {
            Label(String(localized: "song_info_details"), systemImage: "info.circle")
        }
    }

    @ViewBuilder
    private func swipeButton(for slot: PersonalizationSwipeSlot) -> some View {
        switch action(for: slot) {
        case .none, .download, .pin, .delete:
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
        case .instantMix:
            if !isOffline && showInstantMixActions {
                Button {
                    InstantMixService.playSongMix(for: song)
                } label: {
                    Image(systemName: "sparkles")
                }
                .tint(.purple)
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
        case .rightTertiary:
            return PersonalizationSwipeAction(rawValue: rightTertiary).flatMap(normalized) ?? .none
        default:
            return .none
        }
    }

    private func normalized(_ action: PersonalizationSwipeAction) -> PersonalizationSwipeAction {
        switch action {
        case .favorite:
            return showFavoriteActions ? action : .none
        case .addToPlaylist:
            return showPlaylistActions ? action : .none
        case .instantMix:
            return showInstantMixActions ? action : .none
        case .none, .playNext, .addToQueue:
            return action
        case .download, .pin, .delete:
            return .none
        }
    }
}

extension View {
    func personalizedSongSwipeActions(
        song: Song,
        isOffline: Bool,
        isFavorite: Bool,
        accentColor: Color,
        onPlay: @escaping () -> Void,
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
                onPlay: onPlay,
                onFavorite: onFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onPlayNext: onPlayNext,
                onAddToQueue: onAddToQueue
            )
        )
    }
}
