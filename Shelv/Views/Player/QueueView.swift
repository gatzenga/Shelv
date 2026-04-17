import SwiftUI

struct QueueView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @Environment(\.dismiss) var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var editMode = EditMode.inactive
    @State private var showClearConfirm = false

    private var remainingAlbumTracks: [(queueIndex: Int, song: Song)] {
        let start = player.currentIndex + 1
        guard start < player.queue.count else { return [] }
        return player.queue[start...].enumerated().map { (start + $0.offset, $0.element) }
    }

    private var totalCount: Int {
        if player.isShuffled {
            return remainingAlbumTracks.count
        }
        return player.playNextQueue.count + remainingAlbumTracks.count + player.userQueue.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if totalCount == 0 {
                    VStack(spacing: 14) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(tr("Queue is empty", "Warteschlange ist leer"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if player.isShuffled {
                            if !remainingAlbumTracks.isEmpty {
                                Section(tr("Shuffled Queue", "Gemischte Warteschlange")) {
                                    ForEach(Array(remainingAlbumTracks.enumerated()), id: \.element.queueIndex) { _, item in
                                        songRow(item.song)
                                            .onTapGesture {
                                                guard editMode == .inactive else { return }
                                                player.jumpToQueueTrack(at: item.queueIndex)
                                                dismiss()
                                            }
                                    }
                                    .onDelete { offsets in
                                        let offset = player.currentIndex + 1
                                        offsets.sorted(by: >).forEach { player.removeFromPlayQueue(at: $0 + offset) }
                                    }
                                    .onMove { from, to in
                                        player.moveInQueue(from: from, to: to)
                                    }
                                }
                            }
                        } else {
                            if !player.playNextQueue.isEmpty {
                                Section(tr("Play Next", "Als nächstes")) {
                                    ForEach(Array(player.playNextQueue.enumerated()), id: \.element.id) { index, song in
                                        songRow(song)
                                            .id("pn_\(index)_\(song.id)")
                                            .onTapGesture {
                                                guard editMode == .inactive else { return }
                                                player.jumpToPlayNext(at: index)
                                                dismiss()
                                            }
                                    }
                                    .onDelete { offsets in
                                        offsets.sorted(by: >).forEach { player.removeFromPlayNextQueue(at: $0) }
                                    }
                                    .onMove { from, to in
                                        player.moveInPlayNextQueue(from: from, to: to)
                                    }
                                }
                            }

                            if !remainingAlbumTracks.isEmpty {
                                Section(tr("Up Next", "Nächste Titel")) {
                                    ForEach(Array(remainingAlbumTracks.enumerated()), id: \.element.queueIndex) { _, item in
                                        songRow(item.song)
                                            .onTapGesture {
                                                guard editMode == .inactive else { return }
                                                player.jumpToQueueTrack(at: item.queueIndex)
                                                dismiss()
                                            }
                                    }
                                    .onDelete { offsets in
                                        let offset = player.currentIndex + 1
                                        offsets.sorted(by: >).forEach { player.removeFromPlayQueue(at: $0 + offset) }
                                    }
                                    .onMove { from, to in
                                        player.moveInQueue(from: from, to: to)
                                    }
                                }
                            }

                            if !player.userQueue.isEmpty {
                                Section(tr("Next in Queue", "Nächste in Warteschlange")) {
                                    ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { index, song in
                                        songRow(song)
                                            .id("uq_\(index)_\(song.id)")
                                            .onTapGesture {
                                                guard editMode == .inactive else { return }
                                                player.jumpToUserQueue(at: index)
                                                dismiss()
                                            }
                                    }
                                    .onDelete { offsets in
                                        offsets.sorted(by: >).forEach { player.removeFromUserQueue(at: $0) }
                                    }
                                    .onMove { from, to in
                                        player.moveInUserQueue(from: from, to: to)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollIndicators(.hidden)
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle(tr("Queue", "Warteschlange") + (totalCount > 0 ? " (\(totalCount))" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Done", "Fertig")) {
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
                            Button(tr("Clear all", "Alles leeren")) {
                                showClearConfirm = true
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode == .active ? tr("Done", "Fertig") : tr("Edit", "Bearbeiten")) {
                            withAnimation { editMode = editMode == .active ? .inactive : .active }
                        }
                        .foregroundStyle(accentColor)
                    }
                }
            }
        }
        .alert(tr("Clear Queue?", "Warteschlange leeren?"), isPresented: $showClearConfirm) {
            Button(tr("Clear", "Leeren"), role: .destructive) {
                player.clearUpcomingPlayQueue()
                player.clearUserQueue()
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "All upcoming songs will be removed from the queue.",
                "Alle kommenden Songs werden aus der Warteschlange entfernt."
            ))
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
