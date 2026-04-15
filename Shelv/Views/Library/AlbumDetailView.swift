import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var player: AudioPlayerService
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var detail: AlbumDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var queueToast = false
    @State private var toastMessage = ""

    var body: some View {
        List {
            Section {
                headerView
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            } else if let songs = detail?.song {
                Section {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.play(songs: songs, startIndex: index)
                        } label: {
                            HStack(spacing: 14) {
                                Text("\(song.track ?? (index + 1))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)
                                Text(song.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(song.durationFormatted)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                player.addToQueue(song)
                                showToast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                            } label: {
                                Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
                            }
                            .tint(accentColor)

                            Button {
                                player.addPlayNext(song)
                                showToast(tr("Plays Next", "Wird als nächstes gespielt"))
                            } label: {
                                Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
                            }
                            .tint(.orange)
                        }
                    }
                }
            } else if let err = errorMessage {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                Color.clear
                    .frame(height: player.currentSong != nil ? 90 : 0)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if let songs = detail?.song, !songs.isEmpty {
                            player.addPlayNext(songs)
                            showToast(tr("Plays Next", "Wird als nächstes gespielt"))
                        }
                    } label: {
                        Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
                    }
                    .disabled(detail == nil)

                    Button {
                        if let songs = detail?.song, !songs.isEmpty {
                            player.addToQueue(songs)
                            showToast(tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                        }
                    } label: {
                        Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
                    }
                    .disabled(detail == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .overlay(alignment: .top) {
            if queueToast {
                toastBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .task {
            await loadDetail()
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            AlbumArtView(coverArtId: album.coverArt, size: 600, cornerRadius: 16)
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            VStack(spacing: 4) {
                Text(album.name)
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                if let artist = album.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let year = album.year  { Text(String(year)) }
                    if let genre = album.genre { Text(genre) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)

            HStack(spacing: 14) {
                Button {
                    if let songs = detail?.song, !songs.isEmpty {
                        player.play(songs: songs, startIndex: 0)
                    }
                } label: {
                    Label(tr("Play", "Abspielen"), systemImage: "play.fill")
                        .font(.body).bold()
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(detail == nil)

                Button {
                    if let songs = detail?.song, !songs.isEmpty {
                        player.play(songs: songs.shuffled(), startIndex: 0)
                    }
                } label: {
                    Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
                        .font(.body).bold()
                        .foregroundStyle(accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(detail == nil)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 16)
    }

    private var toastBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(toastMessage)
                .font(.subheadline).bold()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(accentColor)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .padding(.top, 8)
    }

    private func showToast(_ message: String) {
        toastMessage = message
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            queueToast = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { queueToast = false }
        }
    }

    private func loadDetail() async {
        isLoading = true
        do {
            detail = try await SubsonicAPIService.shared.getAlbum(id: album.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
