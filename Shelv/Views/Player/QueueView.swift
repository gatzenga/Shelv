import SwiftUI

struct QueueView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @ObservedObject private var streamCacheStatus = StreamCacheStatus.shared
    @Environment(\.dismiss) var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var editMode = EditMode.inactive
    @State private var showClearConfirm = false
    @AppStorage("infinityModeEnabled") private var infinityMode = false

    @State private var localPlayNext: [Song] = []
    @State private var localAlbum: [Song] = []
    @State private var localUserQueue: [Song] = []

    private var totalCount: Int {
        if player.isShuffled {
            return localPlayNext.count + localAlbum.count
        }
        return localPlayNext.count + localAlbum.count + localUserQueue.count
    }

    private func syncFromPlayer() {
        localPlayNext = player.playNextQueue
        localUserQueue = player.userQueue
        let start = player.currentIndex + 1
        if start < player.queue.count {
            localAlbum = Array(player.queue[start...])
        } else {
            localAlbum = []
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                infinityBar
                Divider()
                Group {
                if totalCount == 0 {
                    VStack(spacing: 14) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(String(localized: "queue_is_empty"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if player.isShuffled {
                            if !localPlayNext.isEmpty {
                                Section(String(localized: "play_next")) {
                                    ForEach(localPlayNext) { song in
                                        Button {
                                            guard editMode == .inactive else { return }
                                            if let idx = localPlayNext.firstIndex(where: { $0.id == song.id }) {
                                                player.jumpToPlayNext(at: idx)
                                                dismiss()
                                            }
                                        } label: {
                                            songRow(song)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .onDelete { offsets in
                                        offsets.sorted(by: >).forEach { player.removeFromPlayNextQueue(at: $0) }
                                        syncFromPlayer()
                                    }
                                    .onMove { from, to in
                                        localPlayNext.move(fromOffsets: from, toOffset: to)
                                        player.moveInPlayNextQueue(from: from, to: to)
                                    }
                                }
                            }
                            if !localAlbum.isEmpty {
                                Section(String(localized: "shuffled_queue")) {
                                    ForEach(localAlbum) { song in
                                        Button {
                                            guard editMode == .inactive else { return }
                                            if let idx = localAlbum.firstIndex(where: { $0.id == song.id }) {
                                                player.jumpToQueueTrack(at: player.currentIndex + 1 + idx)
                                                dismiss()
                                            }
                                        } label: {
                                            songRow(song)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .onDelete { offsets in
                                        let offset = player.currentIndex + 1
                                        offsets.sorted(by: >).forEach { player.removeFromPlayQueue(at: $0 + offset) }
                                        syncFromPlayer()
                                    }
                                    .onMove { from, to in
                                        localAlbum.move(fromOffsets: from, toOffset: to)
                                        player.moveInQueue(from: from, to: to)
                                    }
                                }
                            }
                        } else {
                            if !localPlayNext.isEmpty {
                                Section(String(localized: "play_next")) {
                                    ForEach(localPlayNext) { song in
                                        Button {
                                            guard editMode == .inactive else { return }
                                            if let idx = localPlayNext.firstIndex(where: { $0.id == song.id }) {
                                                player.jumpToPlayNext(at: idx)
                                                dismiss()
                                            }
                                        } label: {
                                            songRow(song)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .onDelete { offsets in
                                        offsets.sorted(by: >).forEach { player.removeFromPlayNextQueue(at: $0) }
                                        syncFromPlayer()
                                    }
                                    .onMove { from, to in
                                        localPlayNext.move(fromOffsets: from, toOffset: to)
                                        player.moveInPlayNextQueue(from: from, to: to)
                                    }
                                }
                            }

                            if !localAlbum.isEmpty {
                                Section(String(localized: "up_next")) {
                                    ForEach(localAlbum) { song in
                                        Button {
                                            guard editMode == .inactive else { return }
                                            if let idx = localAlbum.firstIndex(where: { $0.id == song.id }) {
                                                player.jumpToQueueTrack(at: player.currentIndex + 1 + idx)
                                                dismiss()
                                            }
                                        } label: {
                                            songRow(song)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .onDelete { offsets in
                                        let offset = player.currentIndex + 1
                                        offsets.sorted(by: >).forEach { player.removeFromPlayQueue(at: $0 + offset) }
                                        syncFromPlayer()
                                    }
                                    .onMove { from, to in
                                        localAlbum.move(fromOffsets: from, toOffset: to)
                                        player.moveInQueue(from: from, to: to)
                                    }
                                }
                            }

                            if !localUserQueue.isEmpty {
                                Section(String(localized: "your_queue")) {
                                    ForEach(localUserQueue) { song in
                                        Button {
                                            guard editMode == .inactive else { return }
                                            if let idx = localUserQueue.firstIndex(where: { $0.id == song.id }) {
                                                player.jumpToUserQueue(at: idx)
                                                dismiss()
                                            }
                                        } label: {
                                            songRow(song)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .onDelete { offsets in
                                        offsets.sorted(by: >).forEach { player.removeFromUserQueue(at: $0) }
                                        syncFromPlayer()
                                    }
                                    .onMove { from, to in
                                        localUserQueue.move(fromOffsets: from, toOffset: to)
                                        player.moveInUserQueue(from: from, to: to)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
                    .environment(\.editMode, $editMode)
                }
                }
            }
            .navigationTitle(String(localized: "queue") + (totalCount > 0 ? " (\(totalCount))" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Nur im Nicht-Edit-Modus zeigen — sonst stünde links "Done" UND rechts
                    // der "Done"-Button des Edit-Modus (zwei Done-Buttons gleichzeitig).
                    if editMode == .inactive {
                        Button(String(localized: "done")) {
                            dismiss()
                        }
                        .bold()
                        .foregroundStyle(accentColor)
                    }
                }
                if totalCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        if editMode == .inactive {
                            Button(String(localized: "clear_all")) {
                                showClearConfirm = true
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode == .active ? String(localized: "done") : String(localized: "edit")) {
                            withAnimation { editMode = editMode == .active ? .inactive : .active }
                        }
                        .foregroundStyle(accentColor)
                    }
                }
            }
        }
        .task { syncFromPlayer() }
        .onChange(of: player.playNextQueue) { _, _ in syncFromPlayer() }
        .onChange(of: player.userQueue) { _, _ in syncFromPlayer() }
        .onChange(of: player.queue) { _, _ in syncFromPlayer() }
        .onChange(of: player.currentIndex) { _, _ in syncFromPlayer() }
        .onChange(of: player.isShuffled) { _, _ in syncFromPlayer() }
        .alert(String(localized: "clear_queue"), isPresented: $showClearConfirm) {
            Button(String(localized: "clear"), role: .destructive) {
                player.clearUpcomingPlayQueue()
                player.clearUserQueue()
                syncFromPlayer()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "all_upcoming_songs_will_be_removed_from_the_queue"))
        }
    }

    private var infinityBar: some View {
        HStack {
            Label { Text(String(localized: "infinity_mode")) } icon: {
                Image(systemName: "infinity").foregroundStyle(accentColor)
            }
            Spacer()
            Toggle("", isOn: $infinityMode)
                .labelsHidden()
                .tint(accentColor)
                .onChange(of: infinityMode) { _, on in
                    if on { player.topUpInfinityIfNeeded(startIfIdle: true) }
                }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func songRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Group {
                    if streamCacheStatus.cachedSongIds.contains(song.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(accentColor)
                            .accessibilityLabel(String(localized: "precache_ready"))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14, height: 14)
                Text(song.durationFormatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minWidth: 54, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }
}
