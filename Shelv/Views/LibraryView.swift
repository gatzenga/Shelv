import SwiftUI

enum AlbumSortOption: String, CaseIterable {
    case alphabetical = "alphabeticalByName"
    case frequent     = "frequent"
    case newest       = "newest"

    var label: String {
        switch self {
        case .alphabetical: return tr("Name (A–Z)", "Name (A–Z)")
        case .frequent:     return tr("Most Played", "Meist gespielt")
        case .newest:       return tr("Recently Added", "Kürzlich hinzugefügt")
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var player: AudioPlayerService
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var showAlbums = true
    @State private var sortOption: AlbumSortOption = .alphabetical
    @AppStorage("albumViewIsGrid") private var albumIsGrid = true
    @AppStorage("artistViewIsGrid") private var artistIsGrid = false
    @State private var albumScrollID: String?
    @State private var artistScrollID: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    private var albumGroups: [(letter: String, items: [Album])] {
        groupByFirstLetter(libraryStore.albums, name: \.name)
    }

    private var artistGroups: [(letter: String, items: [Artist])] {
        groupByFirstLetter(libraryStore.artists, name: \.name)
    }

    private static let sortArticles: [String] = [
        "the ", "an ", "a ",
        "der ", "die ", "das ", "dem ", "den ", "des ",
        "eine ", "einer ", "einem ", "einen ", "ein ",
        "les ", "le ", "la ", "l\u{2019}", "l'",
        "une ", "des ", "un ",
        "los ", "las ", "el ", "una ", "un ",
        "gli ", "uno ", "una ", "il ", "lo ", "un ",
        "umas ", "uma ", "uns ", "um ", "os ", "as ",
        "het ", "een ", "de ",
    ]

    private func sortKey(for name: String) -> String {
        let lower = name.lowercased()
        for article in Self.sortArticles {
            if lower.hasPrefix(article) {
                return String(name.dropFirst(article.count))
            }
        }
        return name
    }

    private func groupByFirstLetter<T>(_ items: [T], name: KeyPath<T, String>) -> [(letter: String, items: [T])] {
        var dict: [String: [T]] = [:]
        for item in items {
            let key = sortKey(for: item[keyPath: name])
            let raw = String(key.prefix(1))
            let base = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
            let letter = (base.first?.isLetter == true) ? String(base.prefix(1)) : "#"
            dict[letter, default: []].append(item)
        }
        let letters = dict.keys.sorted {
            if $0 == "#" { return true }
            if $1 == "#" { return false }
            return $0 < $1
        }
        return letters.map { ($0, dict[$0]!) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $showAlbums) {
                    Text(tr("Albums", "Alben")).tag(true)
                    Text(tr("Artists", "Künstler")).tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                if (showAlbums ? libraryStore.isLoadingAlbums : libraryStore.isLoadingArtists) &&
                    (showAlbums ? libraryStore.albums.isEmpty : libraryStore.artists.isEmpty) {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if showAlbums {
                    indexedScrollView(
                        letters: albumGroups.map(\.letter),
                        idPrefix: "alb",
                        scrollID: $albumScrollID
                    ) {
                        albumContent
                    }
                } else {
                    indexedScrollView(
                        letters: artistGroups.map(\.letter),
                        idPrefix: "art",
                        scrollID: $artistScrollID
                    ) {
                        artistContent
                    }
                }
            }
            .navigationTitle(tr("Library", "Bibliothek"))
            .toolbar {
                if showAlbums {
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    viewToggleButton
                }
            }
            .task {
                if showAlbums && libraryStore.albums.isEmpty {
                    await libraryStore.loadAlbums()
                } else if !showAlbums && libraryStore.artists.isEmpty {
                    await libraryStore.loadArtists()
                }
            }
            .onChange(of: showAlbums) { _, isAlbums in
                Task {
                    if isAlbums && libraryStore.albums.isEmpty {
                        await libraryStore.loadAlbums()
                    } else if !isAlbums && libraryStore.artists.isEmpty {
                        await libraryStore.loadArtists()
                    }
                }
            }
            .refreshable {
                if showAlbums {
                    await libraryStore.loadAlbums(sortBy: sortOption.rawValue)
                } else {
                    await libraryStore.loadArtists()
                }
            }
        }
    }

    private func indexedScrollView<Content: View>(
        letters: [String],
        idPrefix: String,
        scrollID: Binding<String?>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .padding(.trailing, letters.isEmpty ? 0 : 16)
        }
        .scrollPosition(id: scrollID)
        .scrollIndicators(.hidden)
        .overlay(alignment: .trailing) {
            if !letters.isEmpty {
                AlphabetIndexBar(letters: letters) { letter in
                    scrollID.wrappedValue = "\(idPrefix)-\(letter)"
                }
                .frame(width: 14)
                .padding(.vertical, 16)
                .padding(.trailing, 2)
            }
        }
    }

    @ViewBuilder
    private var albumContent: some View {
        if albumIsGrid {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(albumGroups, id: \.letter) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(group.items) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumCardView(album: album, showArtist: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 14)
                    } header: {
                        letterHeader(group.letter, id: "alb-\(group.letter)")
                    }
                }
                bottomSpacer
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(albumGroups, id: \.letter) { group in
                    Section {
                        ForEach(group.items) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                albumListRow(album)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 76)
                        }
                    } header: {
                        letterHeader(group.letter, id: "alb-\(group.letter)")
                    }
                }
                bottomSpacer
            }
        }
    }

    private func albumListRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: album.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let artist = album.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary)
                    }
                    if let year = album.year {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(String(year)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var artistContent: some View {
        if artistIsGrid {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(artistGroups, id: \.letter) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(group.items) { artist in
                                NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                    artistGridCell(artist)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 14)
                    } header: {
                        letterHeader(group.letter, id: "art-\(group.letter)")
                    }
                }
                bottomSpacer
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(artistGroups, id: \.letter) { group in
                    Section {
                        ForEach(group.items) { artist in
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                artistListRow(artist)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 76)
                        }
                    } header: {
                        letterHeader(group.letter, id: "art-\(group.letter)")
                    }
                }
                bottomSpacer
            }
        }
    }

    private func artistGridCell(_ artist: Artist) -> some View {
        VStack(spacing: 8) {
            AlbumArtView(coverArtId: artist.coverArt, size: 300, cornerRadius: 999)
                .aspectRatio(1, contentMode: .fit)
            Text(artist.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func artistListRow(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArt, size: 150, cornerRadius: 999)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let count = artist.albumCount {
                    Text("\(count) \(tr("Albums", "Alben"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }

    private var viewToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if showAlbums { albumIsGrid.toggle() }
                else { artistIsGrid.toggle() }
            }
        } label: {
            Image(systemName: (showAlbums ? albumIsGrid : artistIsGrid)
                  ? "list.bullet"
                  : "square.grid.2x2")
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AlbumSortOption.allCases, id: \.rawValue) { option in
                Button {
                    sortOption = option
                    Task { await libraryStore.loadAlbums(sortBy: option.rawValue) }
                } label: {
                    Label(option.label, systemImage: sortOption == option ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private func letterHeader(_ letter: String, id: String) -> some View {
        Text(letter)
            .font(.title2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Color(UIColor.systemBackground),              location: 0.0),
                        .init(color: Color(UIColor.systemBackground),              location: 0.65),
                        .init(color: Color(UIColor.systemBackground).opacity(0),   location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .id(id)
    }

    private var bottomSpacer: some View {
        Color.clear.frame(height: player.currentSong != nil ? 90 : 16)
    }
}
