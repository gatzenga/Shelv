import SwiftUI

struct LibrarySegmentPicker: View {
    @Binding var selection: LibrarySegment
    let enableFavorites: Bool

    var body: some View {
        Picker("", selection: $selection) {
            Text(String(localized: "albums")).tag(LibrarySegment.albums)
            Text(String(localized: "artists")).tag(LibrarySegment.artists)
            if enableFavorites {
                Text(String(localized: "favorites")).tag(LibrarySegment.favorites)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct LibraryViewToggleButton: View {
    let segment: LibrarySegment
    @Binding var albumIsGrid: Bool
    @Binding var artistIsGrid: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if segment == .albums {
                    albumIsGrid.toggle()
                } else {
                    artistIsGrid.toggle()
                }
            }
        } label: {
            Image(systemName: (segment == .albums ? albumIsGrid : artistIsGrid)
                  ? "list.bullet"
                  : "square.grid.2x2")
        }
    }
}

struct LibraryPlaybackMenu: View {
    let isLoading: Bool
    let isDisabled: Bool
    let accentColor: Color
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        Menu {
            Button(action: onPlay) {
                Label(String(localized: "play"), systemImage: "play.fill")
            }
            Button(action: onShuffle) {
                Label(String(localized: "shuffle"), systemImage: "shuffle")
            }
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accentColor)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: 18, height: 18)
        }
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(String(localized: "playback"))
    }
}

struct LibraryGenreFilterMenu: View {
    @Binding var selectedGenre: String
    let options: [AlbumGenreFilterOption]
    let accentColor: Color

    private var effectiveSelectedGenre: String? {
        AlbumGenreFilterOption.selectedGenre(selectedGenre, in: options)
    }

    private var hasActiveFilter: Bool {
        effectiveSelectedGenre != nil
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { effectiveSelectedGenre ?? "" },
                set: { selectedGenre = $0 }
            )) {
                Text(String(localized: "all_genres")).tag("")
                ForEach(options) { option in
                    Text(option.label).tag(option.name)
                }
            } label: {
                Label(String(localized: "genre"), systemImage: "guitars")
            }

            if hasActiveFilter {
                Divider()

                Button {
                    selectedGenre = ""
                } label: {
                    Label(String(localized: "clear_genre_filter"), systemImage: "xmark.circle")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "guitars")
                    .foregroundStyle(accentColor)

                if hasActiveFilter {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 4, y: -3)
                }
            }
        }
        .tint(accentColor)
        .disabled(options.isEmpty && !hasActiveFilter)
        .accessibilityLabel(
            effectiveSelectedGenre.map {
                String(format: String(localized: "genre_filter_active_format"), $0)
            }
            ?? String(localized: "genre")
        )
    }
}

struct LibrarySortMenu: View {
    let segment: LibrarySegment
    @Binding var albumSortRaw: String
    @Binding var albumDirectionRaw: String
    @Binding var artistSortRaw: String
    @Binding var artistDirectionRaw: String
    let isOffline: Bool
    let accentColor: Color
    let onAlbumSortChanged: (String) -> Void

    private var albumSortOption: AlbumSortOption {
        AlbumSortOption(rawValue: albumSortRaw) ?? .alphabetical
    }

    private var artistSortOption: ArtistSortOption {
        ArtistSortOption(rawValue: artistSortRaw) ?? .alphabetical
    }

    var body: some View {
        switch segment {
        case .albums:
            albumSortMenu
        case .artists:
            artistSortMenu
        case .favorites:
            EmptyView()
        }
    }

    private var albumSortMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { albumSortRaw },
                set: { newValue in
                    albumSortRaw = newValue
                    onAlbumSortChanged(newValue)
                }
            )) {
                ForEach(AlbumSortOption.allCases.filter { !isOffline || !$0.requiresServer }, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label(String(localized: "sort"), systemImage: "arrow.up.arrow.down")
            }

            if albumSortOption.allowsDirection {
                Picker(selection: $albumDirectionRaw) {
                    ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                        Text(dir.label).tag(dir.rawValue)
                    }
                } label: {
                    Label(String(localized: "direction"), systemImage: "arrow.up.and.down")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(accentColor)
        }
        .tint(accentColor)
    }

    private var artistSortMenu: some View {
        Menu {
            Picker(selection: $artistSortRaw) {
                ForEach(ArtistSortOption.allCases.filter { !isOffline || !$0.requiresServer }, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label(String(localized: "sort"), systemImage: "arrow.up.arrow.down")
            }

            if artistSortOption != .alphabetical {
                Picker(selection: $artistDirectionRaw) {
                    ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                        Text(dir.label).tag(dir.rawValue)
                    }
                } label: {
                    Label(String(localized: "direction"), systemImage: "arrow.up.and.down")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(accentColor)
        }
        .tint(accentColor)
    }
}
