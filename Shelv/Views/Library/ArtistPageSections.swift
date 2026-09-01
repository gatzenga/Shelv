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

    /// Title of a grid shelf. `.all` carries the whole discography there, so it
    /// takes the discography heading rather than the picker's "All".
    var shelfTitle: String {
        self == .all ? String(localized: "discography") : label
    }
}

/// Album / singles filter of the discography section. Only shown when the
/// artist has both kinds of release.
struct ArtistReleaseGroupPicker: View {
    @Binding var selection: ArtistReleaseGroup
    let groups: [ArtistReleaseGroup]

    var body: some View {
        Picker(String(localized: "discography"), selection: $selection) {
            ForEach(groups, id: \.rawValue) { group in
                Text(group.label).tag(group)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Related artists, as the server reports them. Circular covers match the
/// artist rows used everywhere else in the library.
struct ArtistSimilarArtistsRow: View {
    let artists: [Artist]

    private let itemWidth: CGFloat = 104

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(artists) { artist in
                    NavigationLink(destination: ArtistDetailView(artist: artist)) {
                        VStack(spacing: 8) {
                            AlbumArtView(coverArtId: artist.coverArt, size: 300, isCircle: true)
                                .frame(width: itemWidth, height: itemWidth)
                            Text(artist.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: itemWidth)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}

/// A horizontal shelf of releases, the way the rest of Discover presents
/// albums. Splitting albums from singles reads better than one long grid with
/// a filter on top of it. The title opens the full, sortable list, since a
/// shelf alone doesn't scale to an artist with a large discography.
struct ArtistReleaseShelf: View {
    let title: String
    let albums: [Album]
    let personalization: PersonalizationSwipeConfiguration
    @Binding var sortRaw: String
    @Binding var directionRaw: String
    let isOffline: Bool
    let accentColor: Color

    private let itemWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(destination: ArtistAllAlbumsView(
                title: title,
                albums: albums,
                sortRaw: $sortRaw,
                directionRaw: $directionRaw,
                isOffline: isOffline,
                accentColor: accentColor
            )) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.title3).bold()
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(destination: AlbumDetailView(album: album)) {
                            AlbumCardView(
                                album: album,
                                personalization: personalization,
                                showArtist: false,
                                showYear: true
                            )
                            .equatable()
                            .frame(width: itemWidth)
                        }
                        .buttonStyle(.plain)
                        .albumContextMenu(album, showPreview: false)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// The full, sortable list behind a release shelf's title. Plain navigation
/// and sorting only: no swipe actions or context menu, the album's own
/// detail page and the shelf card already cover those. The list/grid choice
/// that used to live on the artist page itself lives here now instead: this
/// is the one place left where showing every release as a compact row versus
/// a full-size cover actually matters.
struct ArtistAllAlbumsView: View {
    let title: String
    let albums: [Album]
    @Binding var sortRaw: String
    @Binding var directionRaw: String
    let isOffline: Bool
    let accentColor: Color

    @AppStorage("artistDetailAlbumIsGrid") private var isGrid = true
    @Environment(\.personalizationSwipeConfiguration) private var personalization
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    private var sortedAlbums: [Album] {
        ArtistAlbumPlaybackOrder.sorted(
            albums,
            preference: ArtistAlbumSortPreference(sortRaw: sortRaw, directionRaw: directionRaw)
        )
    }

    var body: some View {
        Group {
            if isGrid {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(sortedAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(
                                    album: album,
                                    personalization: personalization,
                                    showArtist: false,
                                    showYear: true
                                )
                                .equatable()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            } else {
                List {
                    ForEach(Array(sortedAlbums.enumerated()), id: \.element.id) { index, album in
                        NavigationLink(destination: AlbumDetailView(album: album)) {
                            HStack(spacing: 12) {
                                AlbumArtView(coverArtId: album.coverArt, size: 120, cornerRadius: 8)
                                    .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name)
                                        .font(.body)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    if let year = album.year {
                                        Text(String(year))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isGrid.toggle()
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySortMenu(
                    segment: .albums,
                    albumSortRaw: $sortRaw,
                    albumDirectionRaw: $directionRaw,
                    artistSortRaw: .constant(""),
                    artistDirectionRaw: .constant(""),
                    isOffline: isOffline,
                    accentColor: accentColor,
                    onAlbumSortChanged: { _ in }
                )
            }
        }
    }
}

/// The artist's newest release, pulled out of the shelves so it is the first
/// thing offered after the top songs.
struct ArtistLatestReleaseCard: View {
    let album: Album
    let accentColor: Color

    var body: some View {
        NavigationLink(destination: AlbumDetailView(album: album)) {
            HStack(spacing: 16) {
                AlbumArtView(coverArtId: album.coverArt, size: 300)
                    .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "latest_release"))
                        .font(.caption).bold()
                        .foregroundStyle(accentColor)
                    Text(album.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !album.displayYear.isEmpty {
                        Text(album.displayYear)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .padding(.horizontal)
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
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
