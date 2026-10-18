import SwiftUI

/// The song actions menu, shared between long-press (a `List` row's
/// `.contextMenu`) and an explicit "..." button (used where long-press and
/// swipe would otherwise fight a scroll view's own gesture recognizer, e.g.
/// the Top Songs shelf's horizontal grid).
struct SongActionsMenuContent: View {
    let song: Song
    let isOffline: Bool
    let isFavorite: Bool
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    @Binding var songInfoSong: Song?
    @Binding var shareURL: IdentifiableURL?
    @Binding var shareErrorToast: ShelveToast?

    @Environment(\.personalizationSwipeConfiguration) private var personalization

    var body: some View {
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

        Button {
            shareSong()
        } label: {
            Label(String(localized: "share"), systemImage: "square.and.arrow.up")
        }
    }

    private func shareSong() {
        Task {
            do {
                let share = try await SubsonicAPIService.shared.createShare(id: song.id)
                guard let url = URL(string: share.url) else {
                    await MainActor.run {
                        shareErrorToast = ShelveToast(message: String(localized: "share_link_failed"), isError: true)
                    }
                    return
                }
                await MainActor.run { shareURL = IdentifiableURL(url: url) }
            } catch {
                await MainActor.run {
                    shareErrorToast = ShelveToast(message: error.localizedDescription, isError: true)
                }
            }
        }
    }
}

/// An explicit "..." button carrying the same song actions as
/// `personalizedSongSwipeActions`, for contexts like a horizontal shelf/grid
/// where long-press and swipe conflict with the container's own scroll
/// gestures instead of being reliably recognized.
struct SongMenuButton: View {
    let song: Song
    let isOffline: Bool
    let isFavorite: Bool
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    @State private var songInfoSong: Song?
    @State private var shareURL: IdentifiableURL?
    @State private var shareErrorToast: ShelveToast?

    var body: some View {
        Menu {
            SongActionsMenuContent(
                song: song,
                isOffline: isOffline,
                isFavorite: isFavorite,
                onPlay: onPlay,
                onFavorite: onFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onPlayNext: onPlayNext,
                onAddToQueue: onAddToQueue,
                songInfoSong: $songInfoSong,
                shareURL: $shareURL,
                shareErrorToast: $shareErrorToast
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .sheet(item: $songInfoSong) { song in
            SongInfoSheetView(song: song, initialTab: .details)
        }
        .sheet(item: $shareURL) { wrapped in
            ActivityShareSheet(items: [wrapped.url])
        }
        .shelveToast($shareErrorToast)
    }
}

struct PersonalizedSongSwipeActionsModifier: ViewModifier {
    let song: Song
    let isOffline: Bool
    let isFavorite: Bool
    let accentColor: Color
    let isEnabled: Bool
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    @State private var songInfoSong: Song?
    @State private var shareURL: IdentifiableURL?
    @State private var shareErrorToast: ShelveToast?
    @Environment(\.personalizationSwipeConfiguration) private var personalization

    @ViewBuilder
    func body(content: Content) -> some View {
        // Fixed on purpose. Left to itself, the list starts the separator where the row's
        // first text or image does, so it moved whenever the rank number became the
        // "now playing" waveform and stopped short of the cover.
        let aligned = content.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        if isEnabled {
            aligned
                .contextMenu {
                    SongActionsMenuContent(
                        song: song,
                        isOffline: isOffline,
                        isFavorite: isFavorite,
                        onPlay: onPlay,
                        onFavorite: onFavorite,
                        onAddToPlaylist: onAddToPlaylist,
                        onPlayNext: onPlayNext,
                        onAddToQueue: onAddToQueue,
                        songInfoSong: $songInfoSong,
                        shareURL: $shareURL,
                        shareErrorToast: $shareErrorToast
                    )
                }
                .sheet(item: $songInfoSong) { song in
                    SongInfoSheetView(song: song, initialTab: .details)
                }
                .sheet(item: $shareURL) { wrapped in
                    ActivityShareSheet(items: [wrapped.url])
                }
                .shelveToast($shareErrorToast)
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    swipeButton(for: .leftPrimary)
                    swipeButton(for: .leftSecondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    swipeButton(for: .rightPrimary)
                    swipeButton(for: .rightSecondary)
                    swipeButton(for: .rightTertiary)
                }
        } else {
            aligned
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
        isEnabled: Bool = true,
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
                isEnabled: isEnabled,
                onPlay: onPlay,
                onFavorite: onFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onPlayNext: onPlayNext,
                onAddToQueue: onAddToQueue
            )
        )
    }
}
