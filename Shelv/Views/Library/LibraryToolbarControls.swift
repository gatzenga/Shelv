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

struct LibrarySortMenu: View {
    let segment: LibrarySegment
    @Binding var albumSortRaw: String
    @Binding var albumDirectionRaw: String
    @Binding var artistSortRaw: String
    @Binding var artistDirectionRaw: String
    let isOffline: Bool
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

            if albumSortOption != .alphabetical {
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
        }
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
        }
    }
}
