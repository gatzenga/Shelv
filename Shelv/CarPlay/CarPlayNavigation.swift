import CarPlay
import Combine

@MainActor
enum CarPlayNavigation {

    // MARK: - Safe Push

    static func safePush(_ template: CPTemplate, on ic: CPInterfaceController) {
        guard ic.topTemplate !== template else { return }
        // Apple's CarPlay-Hierarchy-Limit ist 5 inkl. Root. Wenn Audio läuft, belegt
        // das automatisch sichtbare CPNowPlayingTemplate einen virtuellen Slot, also
        // effektiv 4. Statt den Push stillschweigend zu droppen (User klickt, nichts
        // passiert) räumen wir den Stack auf den Tab-Root zurück und pushen frisch.
        let isPlaying = AudioPlayerService.shared.currentSong != nil
        let cap = isPlaying ? 4 : 5
        if ic.templates.count >= cap {
            Task { @MainActor in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    ic.popToRootTemplate(animated: false) { _, _ in cont.resume() }
                }
                ic.pushTemplate(template, animated: true, completion: nil)
            }
            return
        }
        ic.pushTemplate(template, animated: true, completion: nil)
    }

    /// Apple's Audio-App-Pattern: Nach Play / Shuffle / Track-Tap automatisch zum
    /// CPNowPlayingTemplate wechseln. Belässt die vorherigen Templates im Stack,
    /// damit der User mit „Back" wieder auf der Album/Artist/Playlist-Detail-Seite
    /// landet (Standardverhalten anderer Audio-Apps).
    static func presentNowPlaying(on ic: CPInterfaceController) {
        let np = CPNowPlayingTemplate.shared
        if ic.topTemplate === np { return }
        Task { @MainActor in
            if ic.templates.contains(where: { $0 === np }) {
                ic.pop(to: np, animated: true, completion: nil)
                return
            }
            // Erst bei 5 existierenden Templates poppen — Apple's Limit ist 5, also
            // bleibt ein Stack der Tiefe 4 (z.B. Tab→Artists→Artist→Album) erhalten
            // und NowPlaying wird als 5. Template gepusht.
            if ic.templates.count >= 5 {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    ic.popToRootTemplate(animated: false) { _, _ in cont.resume() }
                }
            }
            ic.pushTemplate(np, animated: true, completion: nil)
        }
    }

    // MARK: - Album

    static func openAlbum(_ album: Album, from ic: CPInterfaceController) {
        Task { @MainActor in
            let template = CPListTemplate(
                title: album.name,
                sections: [CPListSection(items: [
                    CPListItem(text: tr("Loading…", "Wird geladen…"), detailText: nil)
                ], header: nil, sectionIndexTitle: nil)]
            )
            safePush(template, on: ic)

            let songs: [Song]
            if OfflineModeService.shared.isOffline {
                songs = DownloadStore.shared.albums
                    .first { $0.albumId == album.id }?.songs.map { $0.asSong() } ?? []
            } else {
                songs = (try? await LibraryStore.shared.fetchAlbumSongs(album)) ?? []
            }
            configureAlbumDetail(template, album: album, songs: songs, ic: ic)
        }
    }

    static func configureAlbumDetail(_ template: CPListTemplate, album: Album, songs: [Song], ic: CPInterfaceController) {
        func rebuildActionsAsync() {
            Task { @MainActor [weak template] in
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }

        func makeActionsSection() -> CPListSection {
            let enableFavorites = UserDefaults.standard.bool(forKey: "enableFavorites")
            let starred = LibraryStore.shared.isAlbumStarred(album)

            var actions: [(icon: String, label: String, handler: () -> Void)] = [
                ("play.fill",   tr("Play",    "Abspielen"), {
                    AudioPlayerService.shared.play(songs: songs, startIndex: 0)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
                ("shuffle",     tr("Shuffle", "Zufällig"), {
                    AudioPlayerService.shared.playShuffled(songs: songs)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
                ("text.insert", tr("Play Next",    "Als Nächstes"), {
                    AudioPlayerService.shared.addPlayNext(songs)
                    rebuildActionsAsync()
                }),
                ("text.append", tr("Add to Queue", "Zur Warteschlange"), {
                    AudioPlayerService.shared.addToQueue(songs)
                    rebuildActionsAsync()
                }),
            ]
            if enableFavorites {
                let icon = starred ? "heart.fill" : "heart"
                let label = starred ? tr("Unfavorite", "Favorit entfernen") : tr("Favorite", "Favorit")
                actions.append((icon, label, {
                    Task { await LibraryStore.shared.toggleStarAlbum(album) }
                }))
            }

            var items = makeActionItems(actions)
            if let artistId = album.artistId {
                let candidate = LibraryStore.shared.artists.first { $0.id == artistId }
                    ?? DownloadStore.shared.artists.first { $0.artistId == artistId }?.asArtist()
                if let artist = candidate {
                    let row = CPListItem(text: tr("View Artist", "Zum Künstler"), detailText: artist.name)
                    row.accessoryType = .disclosureIndicator
                    row.handler = { _, c in c(); openArtist(artist, from: ic) }
                    items.append(row)
                }
            }
            return CPListSection(items: items, header: album.name, sectionIndexTitle: nil)
        }

        func makeSongsSection() -> CPListSection {
            let items = songs.enumerated().map { idx, song in
                songListItem(song, index: idx) { [weak template] _, c in
                    c()
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx)
                    presentNowPlaying(on: ic)
                    Task { @MainActor [weak template] in
                        guard let t = template else { return }
                        let snap = t.sections
                        guard snap.count >= 2 else { return }
                        t.updateSections([snap[0], makeSongsSection()])
                    }
                }
            }
            return CPListSection(items: items, header: tr("Songs", "Titel"), sectionIndexTitle: nil)
        }
        template.updateSections([makeActionsSection(), makeSongsSection()])

        Task { @MainActor [weak template] in
            var lastEnabled = UserDefaults.standard.bool(forKey: "enableFavorites")
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                let current = UserDefaults.standard.bool(forKey: "enableFavorites")
                guard current != lastEnabled else { continue }
                lastEnabled = current
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }
        Task { @MainActor [weak template] in
            for await _ in LibraryStore.shared.$starredAlbums.dropFirst(1).values {
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }
    }

    // MARK: - Artist

    static func openArtist(_ artist: Artist, from ic: CPInterfaceController) {
        Task { @MainActor in
            let template = CPListTemplate(
                title: artist.name,
                sections: [CPListSection(items: [
                    CPListItem(text: tr("Loading…", "Wird geladen…"), detailText: nil)
                ], header: nil, sectionIndexTitle: nil)]
            )
            safePush(template, on: ic)

            let albums: [Album]
            if OfflineModeService.shared.isOffline {
                albums = downloadedAlbums(for: artist)
            } else {
                albums = (try? await SubsonicAPIService.shared.getArtist(id: artist.id))?.album ?? []
            }
            configureArtistDetail(template, artist: artist, albums: albums, ic: ic)
        }
    }

    private static func downloadedAlbums(for artist: Artist) -> [Album] {
        let match = DownloadStore.shared.artists.first {
            $0.artistId == artist.id || $0.name == artist.name
        }
        return match?.albums.map { $0.asAlbum() } ?? []
    }

    static func configureArtistDetail(_ template: CPListTemplate, artist: Artist, albums: [Album], ic: CPInterfaceController) {
        func rebuildActionsAsync() {
            Task { @MainActor [weak template] in
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }

        func makeActionsSection() -> CPListSection {
            let enableFavorites = UserDefaults.standard.bool(forKey: "enableFavorites")
            let starred = LibraryStore.shared.isArtistStarred(artist)

            func playAction(_ op: @escaping ([Song]) -> Void, navigateToPlayer: Bool = false) -> () -> Void {
                return {
                    Task { @MainActor in
                        let songs = await artistSongs(artist)
                        guard !songs.isEmpty else { return }
                        op(songs)
                        if navigateToPlayer { presentNowPlaying(on: ic) }
                    }
                    rebuildActionsAsync()
                }
            }

            var actions: [(icon: String, label: String, handler: () -> Void)] = [
                ("play.fill",   tr("Play",         "Abspielen"),         playAction({ AudioPlayerService.shared.play(songs: $0, startIndex: 0) }, navigateToPlayer: true)),
                ("shuffle",     tr("Shuffle",      "Zufällig"),          playAction({ AudioPlayerService.shared.playShuffled(songs: $0) }, navigateToPlayer: true)),
                ("text.insert", tr("Play Next",    "Als Nächstes"),      playAction({ AudioPlayerService.shared.addPlayNext($0) })),
                ("text.append", tr("Add to Queue", "Zur Warteschlange"), playAction({ AudioPlayerService.shared.addToQueue($0) })),
            ]
            if enableFavorites {
                let icon = starred ? "heart.fill" : "heart"
                let label = starred ? tr("Unfavorite", "Favorit entfernen") : tr("Favorite", "Favorit")
                actions.append((icon, label, {
                    Task { await LibraryStore.shared.toggleStarArtist(artist) }
                }))
            }

            return CPListSection(items: makeActionItems(actions), header: artist.name, sectionIndexTitle: nil)
        }

        func makeAlbumsSection() -> (section: CPListSection, coverMap: [String: [CPListItem]]) {
            var coverMap: [String: [CPListItem]] = [:]
            let items = albums.map { album -> CPListItem in
                let item = albumListItem(album) { [weak template] _, c in
                    c()
                    openAlbum(album, from: ic)
                    Task { @MainActor [weak template] in
                        guard let t = template else { return }
                        let snap = t.sections
                        guard snap.count >= 2 else { return }
                        let (freshSection, freshMap) = makeAlbumsSection()
                        prefillCoversFromCache(freshMap)
                        t.updateSections([snap[0], freshSection])
                        await streamCovers(into: freshMap)
                    }
                }
                if let id = album.coverArt { coverMap[id, default: []].append(item) }
                return item
            }
            return (CPListSection(items: items, header: tr("Albums", "Alben"), sectionIndexTitle: nil), coverMap)
        }

        let (albumsSection, initialCoverMap) = makeAlbumsSection()
        template.updateSections([makeActionsSection(), albumsSection])

        Task {
            await streamCovers(into: initialCoverMap)
        }

        Task { @MainActor [weak template] in
            var lastEnabled = UserDefaults.standard.bool(forKey: "enableFavorites")
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                let current = UserDefaults.standard.bool(forKey: "enableFavorites")
                guard current != lastEnabled else { continue }
                lastEnabled = current
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }
        Task { @MainActor [weak template] in
            for await _ in LibraryStore.shared.$starredArtists.dropFirst(1).values {
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }
    }

    // MARK: - Playlist

    static func openPlaylist(_ playlist: Playlist, from ic: CPInterfaceController) {
        Task { @MainActor in
            let template = CPListTemplate(
                title: playlist.name,
                sections: [CPListSection(items: [
                    CPListItem(text: tr("Loading…", "Wird geladen…"), detailText: nil)
                ], header: nil, sectionIndexTitle: nil)]
            )
            safePush(template, on: ic)

            let allSongs = (await LibraryStore.shared.loadPlaylistDetail(id: playlist.id))?.songs ?? []
            let songs: [Song] = OfflineModeService.shared.isOffline
                ? allSongs.filter { DownloadStore.shared.isDownloaded(songId: $0.id) }
                : allSongs
            configurePlaylistDetail(template, playlist: playlist, songs: songs, ic: ic)
        }
    }

    static func configurePlaylistDetail(_ template: CPListTemplate, playlist: Playlist, songs: [Song], ic: CPInterfaceController) {
        func rebuildActionsAsync() {
            Task { @MainActor [weak template] in
                guard let t = template else { return }
                guard t.sections.count >= 2 else { return }
                t.updateSections([makeActionsSection(), t.sections[1]])
            }
        }

        func makeActionsSection() -> CPListSection {
            let actions: [(icon: String, label: String, handler: () -> Void)] = [
                ("play.fill",   tr("Play",    "Abspielen"), {
                    AudioPlayerService.shared.play(songs: songs, startIndex: 0)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
                ("shuffle",     tr("Shuffle", "Zufällig"), {
                    AudioPlayerService.shared.playShuffled(songs: songs)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
                ("text.insert", tr("Play Next",    "Als Nächstes"), {
                    AudioPlayerService.shared.addPlayNext(songs)
                    rebuildActionsAsync()
                }),
                ("text.append", tr("Add to Queue", "Zur Warteschlange"), {
                    AudioPlayerService.shared.addToQueue(songs)
                    rebuildActionsAsync()
                }),
            ]
            return CPListSection(items: makeActionItems(actions), header: playlist.name, sectionIndexTitle: nil)
        }

        func makeSongsSection() -> (section: CPListSection, coverMap: [String: [CPListItem]]) {
            var coverMap: [String: [CPListItem]] = [:]
            let items: [CPListItem] = songs.enumerated().map { idx, song in
                let item = songListItem(song, index: idx, showCover: true) { [weak template] _, c in
                    c()
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx)
                    presentNowPlaying(on: ic)
                    Task { @MainActor [weak template] in
                        guard let t = template else { return }
                        guard t.sections.count >= 2 else { return }
                        let (freshSection, freshMap) = makeSongsSection()
                        prefillCoversFromCache(freshMap)
                        t.updateSections([t.sections[0], freshSection])
                        await streamCovers(into: freshMap)
                    }
                }
                if let id = song.coverArt { coverMap[id, default: []].append(item) }
                return item
            }
            return (CPListSection(items: items, header: tr("Songs", "Titel"), sectionIndexTitle: nil), coverMap)
        }

        let (songsSection, initialCoverMap) = makeSongsSection()
        template.updateSections([makeActionsSection(), songsSection])

        Task {
            await streamCovers(into: initialCoverMap)
        }
    }

    // MARK: - Private

    private static func artistSongs(_ artist: Artist) async -> [Song] {
        if OfflineModeService.shared.isOffline {
            let match = DownloadStore.shared.artists.first {
                $0.artistId == artist.id || $0.name == artist.name
            }
            return match?.albums.flatMap { $0.songs.map { $0.asSong() } } ?? []
        }
        return await LibraryStore.shared.fetchAllSongs(for: artist)
    }

    static func makeActionItems(_ actions: [(icon: String, label: String, handler: () -> Void)]) -> [any CPListTemplateItem] {
        actions.map { entry in
            actionListItem(title: entry.label, systemImage: entry.icon) { _, c in
                entry.handler()
                c()
            }
        }
    }
}
