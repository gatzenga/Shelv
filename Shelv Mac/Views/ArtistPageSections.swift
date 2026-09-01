import SwiftUI

extension ArtistReleaseGroup {
    /// Localised in each UI target, the way the other sort and filter enums are.
    var label: String {
        switch self {
        case .all: String(localized: "release_group_all")
        case .albums: String(localized: "albums")
        case .singlesAndEPs: String(localized: "release_group_singles_eps")
        }
    }

    /// Title of a grid shelf, or `nil` when the page has already titled it.
    /// `.all` is the whole discography on one shelf, which is exactly what the
    /// standing "Discography" heading above it says.
    var shelfTitle: String? {
        self == .all ? nil : label
    }
}

/// Identifies the full, sortable album list behind a release shelf's title:
/// the escape hatch from a shelf that doesn't scale to a large discography.
struct ArtistAlbumGroup: Hashable {
    let title: String
    let albums: [Album]
}

/// A horizontal shelf of releases. Splitting albums from singles reads better
/// than one long grid with a filter on top of it. The title opens the full,
/// sortable list, with the same grid/list and sort options as the Library's
/// own Albums screen.
struct ArtistReleaseShelf: View {
    /// `nil` drops the header row, and with it the link to the full list. A
    /// shelf the page has already titled holds every release the artist has,
    /// and the sort and grid/list controls right above it do what that list
    /// would have offered.
    let title: String?
    let albums: [Album]

    private let itemWidth: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                NavigationLink(value: ArtistAlbumGroup(title: title, albums: albums)) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumGridItem(album: album)
                                .equatable()
                                .frame(width: itemWidth)
                        }
                        .buttonStyle(.plain)
                        .albumContextMenu(album)
                    }
                }
                .padding(.horizontal, 24)
                // Room for the hover scale-up: without it, a ScrollView clips
                // the top of the enlarged cover to its own established
                // height, same fix as the Discover shelf's `AlbumShelfSection`.
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// The full, sortable list behind a release shelf's title, with the same
/// grid/list toggle and sort menu as the Library's own Albums screen, just
/// scoped to this artist's releases.
struct ArtistAllAlbumsView: View {
    let title: String
    let albums: [Album]

    @AppStorage("artistAllAlbumsIsGrid") private var isGrid = true
    @AppStorage("artistDetailAlbumSort") private var sortRaw: String = LibrarySortOption.recentlyAdded.rawValue
    @AppStorage("artistDetailAlbumDirection") private var directionRaw: String = SortDirection.descending.rawValue
    @ObservedObject private var offlineMode = OfflineModeService.shared

    private var sortOption: LibrarySortOption {
        LibrarySortOption(rawValue: sortRaw) ?? .recentlyAdded
    }
    private var direction: SortDirection {
        SortDirection(rawValue: directionRaw) ?? .descending
    }

    private var sortedAlbums: [Album] {
        ArtistAlbumPlaybackOrder.sorted(
            albums,
            preference: ArtistAlbumSortPreference(sortRaw: sortRaw, directionRaw: directionRaw)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("\(String(localized: "sort")):", selection: $sortRaw) {
                    ForEach(LibrarySortOption.allCases.filter {
                        $0 != .artist && (!offlineMode.isOffline || !$0.requiresServer)
                    }, id: \.rawValue) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(width: 180)
                if sortOption.allowsDirection {
                    Button {
                        directionRaw = direction == .ascending
                            ? SortDirection.descending.rawValue
                            : SortDirection.ascending.rawValue
                    } label: {
                        Image(systemName: direction == .ascending ? "arrow.up" : "arrow.down")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help(direction == .ascending ? String(localized: "ascending") : String(localized: "descending"))
                }
                Button { isGrid.toggle() } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(isGrid ? String(localized: "list_view") : String(localized: "grid_view"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if isGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)], spacing: 20) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumGridItem(album: album)
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album)
                        }
                    }
                    .padding(20)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumListRow(album: album)
                                    .equatable()
                            }
                            .buttonStyle(.plain)
                            .albumContextMenu(album)
                            if album.id != sortedAlbums.last?.id {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(title)
    }
}

/// The artist's newest release, pulled out of the shelves so it is the first
/// thing offered after the top songs.
struct ArtistLatestReleaseCard: View {
    let album: Album
    let accentColor: Color

    var body: some View {
        NavigationLink(value: album) {
            HStack(spacing: 16) {
                CoverArtView(coverArtID: album.coverArt, requestSize: 300, size: 88)

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "latest_release"))
                        .font(.caption.bold())
                        .foregroundStyle(accentColor)
                    Text(album.name)
                        .font(.headline)
                        .lineLimit(2)
                    if !album.displayYear.isEmpty {
                        Text(album.displayYear)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }
}

/// External pages for the artist, as chips under the biography.
struct ArtistLinksRow: View {
    let lastFmURL: URL?
    let musicBrainzURL: URL?

    var body: some View {
        if lastFmURL != nil || musicBrainzURL != nil {
            HStack(spacing: 10) {
                if let lastFmURL {
                    chip(String(localized: "last_fm"), url: lastFmURL)
                }
                if let musicBrainzURL {
                    chip(String(localized: "musicbrainz"), url: musicBrainzURL)
                }
            }
        }
    }

    private func chip(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right").font(.caption2)
                Text(title)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
