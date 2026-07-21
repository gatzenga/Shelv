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
    @Environment(\.personalizationSwipeConfiguration) private var personalization

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

        if !isOffline && personalization.showInstantMixActions {
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

        if !isOffline && (personalization.showFavoriteActions || personalization.showPlaylistActions) {
            Divider()

            if personalization.showFavoriteActions {
                Button {
                    onFavorite()
                } label: {
                    Label(
                        isFavorite ? String(localized: "unfavorite") : String(localized: "favorite"),
                        systemImage: isFavorite ? "heart.slash.fill" : "heart"
                    )
                }
            }

            if personalization.showPlaylistActions {
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
            if !isOffline && personalization.showFavoriteActions {
                Button {
                    onFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.slash.fill" : "heart")
                }
                .tint(.pink)
            }
        case .addToPlaylist:
            if !isOffline && personalization.showPlaylistActions {
                Button {
                    onAddToPlaylist()
                } label: {
                    Image(systemName: "music.note.list")
                }
                .tint(accentColor)
            }
        case .instantMix:
            if !isOffline && personalization.showInstantMixActions {
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
            return PersonalizationSwipeAction(rawValue: personalization.songLeftPrimary).flatMap(normalized) ?? .none
        case .leftSecondary:
            return PersonalizationSwipeAction(rawValue: personalization.songLeftSecondary).flatMap(normalized) ?? .none
        case .rightPrimary:
            return PersonalizationSwipeAction(rawValue: personalization.songRightPrimary).flatMap(normalized) ?? .none
        case .rightSecondary:
            return PersonalizationSwipeAction(rawValue: personalization.songRightSecondary).flatMap(normalized) ?? .none
        case .rightTertiary:
            return PersonalizationSwipeAction(rawValue: personalization.songRightTertiary).flatMap(normalized) ?? .none
        default:
            return .none
        }
    }

    private func normalized(_ action: PersonalizationSwipeAction) -> PersonalizationSwipeAction {
        switch action {
        case .favorite:
            return personalization.showFavoriteActions ? action : .none
        case .addToPlaylist:
            return personalization.showPlaylistActions ? action : .none
        case .instantMix:
            return personalization.showInstantMixActions ? action : .none
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
