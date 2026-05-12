import SwiftUI

struct QueueView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @Environment(\.dismiss) var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var editMode = EditMode.inactive
    @State private var showClearConfirm = false

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
            Group {
                if totalCount == 0 {
                    VStack(spacing: 14) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(tr("car.play.car.play.queue.queue_empty"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if player.isShuffled {
                            if !localPlayNext.isEmpty {
                                Section(tr("car.play.car.play.queue.play_next")) {
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
                                Section(tr("car.play.car.play.queue.shuffled_queue")) {
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
                                Section(tr("car.play.car.play.queue.play_next")) {
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
                                Section(tr("car.play.car.play.queue.up_next")) {
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
                                Section(tr("car.play.car.play.queue.queue.6f06e0cd")) {
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
            .navigationTitle(tr("car.play.car.play.queue.queue") + (totalCount > 0 ? " (\(totalCount))" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("player.queue.done")) {
                        if editMode == .active {
                            withAnimation { editMode = .inactive }
                        } else {
                            dismiss()
                        }
                    }
                    .bold()
                    .foregroundStyle(accentColor)
                }
                if totalCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        if editMode == .inactive {
                            Button(tr("player.queue.clear")) {
                                showClearConfirm = true
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode == .active ? tr("player.queue.done") : tr("player.queue.edit")) {
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
        .alert(tr("player.queue.clear_queue"), isPresented: $showClearConfirm) {
            Button(tr("player.queue.clear.9529e8af"), role: .destructive) {
                player.clearUpcomingPlayQueue()
                player.clearUserQueue()
                syncFromPlayer()
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("player.queue.upcoming_songs_removed_from_queue"))
        }
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
            Text(song.durationFormatted)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}
