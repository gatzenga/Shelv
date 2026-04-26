import CarPlay

@MainActor
enum CarPlayNavigation {

    // MARK: - Safe Push

    static func safePush(_ template: CPTemplate, on ic: CPInterfaceController) {
        // Nicht pushen wenn Stack zu tief
        guard ic.templates.count < 4 else { return }
        // Nicht pushen wenn bereits ein Template desselben Typs oben liegt
        guard ic.topTemplate?.classForCoder != template.classForCoder else { return }
        ic.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Album

    static func openAlbum(_ album: Album, from ic: CPInterfaceController) {
        Task { @MainActor in
            // Template sofort erstellen und pushen — KEIN späteres pop/push (verhindert hierarchy-depth-crash)
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
            let real = albumDetailTemplate(album: album, songs: songs, ic: ic)
            template.updateSections(real.sections)
        }
    }

    static func albumDetailTemplate(album: Album, songs: [Song], ic: CPInterfaceController) -> CPListTemplate {
        func makeActionsSection() -> CPListSection {
            let enableFavorites = UserDefaults.standard.bool(forKey: "enableFavorites")
            let starred = LibraryStore.shared.isAlbumStarred(album)

            var actions: [(icon: String, label: String, handler: () -> Void)] = [
                ("play.fill",   tr("Play",         "Abspielen"),         { AudioPlayerService.shared.play(songs: songs, startIndex: 0) }),
                ("shuffle",     tr("Shuffle",      "Zufällig"),          { AudioPlayerService.shared.playShuffled(songs: songs) }),
                ("text.insert", tr("Play Next",    "Als Nächstes"),      { AudioPlayerService.shared.addPlayNext(songs) }),
                ("text.append", tr("Add to Queue", "Zur Warteschlange"), { AudioPlayerService.shared.addToQueue(songs) }),
            ]
            if enableFavorites {
                let icon = starred ? "heart.fill" : "heart"
                let label = starred ? tr("Unfavorite", "Favorit entfernen") : tr("Favorite", "Favorit")
                actions.append((icon, label, {
                    Task {
                        await LibraryStore.shared.toggleStarAlbum(album)
                        NotificationCenter.default.post(name: .carPlayStarredChanged, object: nil)
                    }
                }))
            }

            var items = makeActionItems(actions)
            if let artistId = album.artistId {
                let candidate = LibraryStore.shared.artists.first { $0.id == artistId }
                    ?? DownloadStore.shared.artists.first { $0.artistId == artistId }?.asArtist()
                if let artist = candidate {
                    let row = CPListItem(text: tr("View Artist", "Zum Künstler"), detailText: artist.name)
                    row.accessoryType = .disclosureIndicator
                    row.handler = { _, c in openArtist(artist, from: ic); c() }
                    items.append(row)
                }
            }
            return CPListSection(items: items, header: album.name, sectionIndexTitle: nil)
        }

        let songItems = songs.enumerated().map { idx, song in
            songListItem(song, index: idx) { _, c in
                AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
            }
        }
        let songsSection = CPListSection(items: songItems, header: tr("Songs", "Titel"), sectionIndexTitle: nil)
        let template = CPListTemplate(title: album.name, sections: [makeActionsSection(), songsSection])

        // Reaktiv: enableFavorites-Toggle
        Task { @MainActor [weak template] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }
        // Reaktiv: Favorit-Status nach Toggle
        Task { @MainActor [weak template] in
            for await _ in NotificationCenter.default.notifications(named: .carPlayStarredChanged) {
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }

        return template
    }

    // MARK: - Artist

    static func openArtist(_ artist: Artist, from ic: CPInterfaceController) {
        Task { @MainActor in
            // Template sofort erstellen und pushen — KEIN späteres pop/push
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
            let real = artistDetailTemplate(artist: artist, albums: albums, ic: ic)
            template.updateSections(real.sections)
        }
    }

    private static func downloadedAlbums(for artist: Artist) -> [Album] {
        let match = DownloadStore.shared.artists.first {
            $0.artistId == artist.id || $0.name == artist.name
        }
        return match?.albums.map { $0.asAlbum() } ?? []
    }

    static func artistDetailTemplate(artist: Artist, albums: [Album], ic: CPInterfaceController) -> CPListTemplate {
        func makeActionsSection() -> CPListSection {
            let enableFavorites = UserDefaults.standard.bool(forKey: "enableFavorites")
            let starred = LibraryStore.shared.isArtistStarred(artist)

            func playAction(_ op: @escaping ([Song]) -> Void) -> () -> Void {
                return {
                    Task { @MainActor in
                        let songs = await artistSongs(artist)
                        guard !songs.isEmpty else { return }
                        op(songs)
                    }
                }
            }

            var actions: [(icon: String, label: String, handler: () -> Void)] = [
                ("play.fill",   tr("Play",         "Abspielen"),         playAction { AudioPlayerService.shared.play(songs: $0, startIndex: 0) }),
                ("shuffle",     tr("Shuffle",      "Zufällig"),          playAction { AudioPlayerService.shared.playShuffled(songs: $0) }),
                ("text.insert", tr("Play Next",    "Als Nächstes"),      playAction { AudioPlayerService.shared.addPlayNext($0) }),
                ("text.append", tr("Add to Queue", "Zur Warteschlange"), playAction { AudioPlayerService.shared.addToQueue($0) }),
            ]
            if enableFavorites {
                let icon = starred ? "heart.fill" : "heart"
                let label = starred ? tr("Unfavorite", "Favorit entfernen") : tr("Favorite", "Favorit")
                actions.append((icon, label, {
                    Task {
                        await LibraryStore.shared.toggleStarArtist(artist)
                        NotificationCenter.default.post(name: .carPlayStarredChanged, object: nil)
                    }
                }))
            }

            return CPListSection(items: makeActionItems(actions), header: artist.name, sectionIndexTitle: nil)
        }

        func albumItems(_ map: [String: UIImage]) -> [CPListItem] {
            albums.map { album -> CPListItem in
                let item = albumListItem(album) { _, c in openAlbum(album, from: ic); c() }
                if let id = album.coverArt, let img = map[id] { item.setImage(img) }
                return item
            }
        }
        let albumsSection = CPListSection(items: albumItems([:]), header: tr("Albums", "Alben"), sectionIndexTitle: nil)
        let template = CPListTemplate(title: artist.name, sections: [makeActionsSection(), albumsSection])

        // Cover-Art inkrementell laden
        Task { [weak template] in
            guard let template else { return }
            await applyCoversAsync(template: template, coverArtIds: albums.map { $0.coverArt }) { map in
                guard template.sections.count >= 2 else { return template.sections }
                let updated = CPListSection(items: albumItems(map), header: tr("Albums", "Alben"), sectionIndexTitle: nil)
                return [template.sections[0], updated]
            }
        }

        // Reaktiv: enableFavorites-Toggle
        Task { @MainActor [weak template] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }
        // Reaktiv: Favorit-Status nach Toggle
        Task { @MainActor [weak template] in
            for await _ in NotificationCenter.default.notifications(named: .carPlayStarredChanged) {
                guard let t = template else { return }
                let snap = t.sections
                guard snap.count >= 2 else { return }
                t.updateSections([makeActionsSection(), snap[1]])
            }
        }

        return template
    }

    // MARK: - Playlist

    static func openPlaylist(_ playlist: Playlist, from ic: CPInterfaceController) {
        Task { @MainActor in
            // Template sofort erstellen und pushen — KEIN späteres pop/push
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
            let real = playlistDetailTemplate(playlist: playlist, songs: songs, ic: ic)
            template.updateSections(real.sections)
        }
    }

    static func playlistDetailTemplate(playlist: Playlist, songs: [Song], ic: CPInterfaceController) -> CPListTemplate {
        let actions: [(icon: String, label: String, handler: () -> Void)] = [
            ("play.fill",   tr("Play",         "Abspielen"),         { AudioPlayerService.shared.play(songs: songs, startIndex: 0) }),
            ("shuffle",     tr("Shuffle",      "Zufällig"),          { AudioPlayerService.shared.playShuffled(songs: songs) }),
            ("text.insert", tr("Play Next",    "Als Nächstes"),      { AudioPlayerService.shared.addPlayNext(songs) }),
            ("text.append", tr("Add to Queue", "Zur Warteschlange"), { AudioPlayerService.shared.addToQueue(songs) }),
        ]
        let actionsSection = CPListSection(items: makeActionItems(actions), header: playlist.name, sectionIndexTitle: nil)

        func songItems(_ map: [String: UIImage]) -> [CPListItem] {
            songs.enumerated().map { idx, song -> CPListItem in
                let item = songListItem(song, index: idx, showCover: true) { _, c in
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
                }
                if let id = song.coverArt, let img = map[id] { item.setImage(img) }
                return item
            }
        }
        let songsSection = CPListSection(items: songItems([:]), header: tr("Songs", "Titel"), sectionIndexTitle: nil)
        let template = CPListTemplate(title: playlist.name, sections: [actionsSection, songsSection])

        Task { [weak template] in
            guard let template else { return }
            await applyCoversAsync(template: template, coverArtIds: songs.map { $0.coverArt }) { map in
                guard template.sections.count >= 2 else { return template.sections }
                let updated = CPListSection(items: songItems(map), header: tr("Songs", "Titel"), sectionIndexTitle: nil)
                return [template.sections[0], updated]
            }
        }

        return template
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

    /// Baut alle Aktionen als beschriftete Zeilen mit Leading-Icon in Akzentfarbe.
    /// Konsistent über alle CarPlay-Bildschirmgrössen, keine versteckten Truncations.
    static func makeActionItems(_ actions: [(icon: String, label: String, handler: () -> Void)]) -> [any CPListTemplateItem] {
        actions.map { entry in
            actionListItem(title: entry.label, systemImage: entry.icon) { _, c in
                entry.handler(); c()
            }
        }
    }
}
