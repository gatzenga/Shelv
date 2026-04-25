import CarPlay

@MainActor
enum CarPlayNavigation {

    // MARK: - Album

    static func openAlbum(_ album: Album, from ic: CPInterfaceController) {
        Task {
            let songs: [Song]
            if OfflineModeService.shared.isOffline {
                songs = DownloadStore.shared.albums
                    .first { $0.albumId == album.id }?.songs.map { $0.asSong() } ?? []
            } else {
                songs = (try? await LibraryStore.shared.fetchAlbumSongs(album)) ?? []
            }
            let t = albumDetailTemplate(album: album, songs: songs, ic: ic)
            ic.pushTemplate(t, animated: true, completion: nil)
        }
    }

    static func albumDetailTemplate(album: Album, songs: [Song], ic: CPInterfaceController) -> CPListTemplate {
        let enableFavorites = UserDefaults.standard.bool(forKey: "enableFavorites")
        let starred = LibraryStore.shared.isAlbumStarred(album)

        var actions: [CPListItem] = [
            actionListItem(title: tr("Play", "Abspielen"), systemImage: "play.fill") { _, c in
                AudioPlayerService.shared.play(songs: songs, startIndex: 0); c()
            },
            actionListItem(title: tr("Shuffle", "Zufällig"), systemImage: "shuffle") { _, c in
                AudioPlayerService.shared.playShuffled(songs: songs); c()
            },
            actionListItem(title: tr("Play Next", "Als nächstes"), systemImage: "text.insert") { _, c in
                AudioPlayerService.shared.addPlayNext(songs); c()
            },
            actionListItem(title: tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.append") { _, c in
                AudioPlayerService.shared.addToQueue(songs); c()
            },
        ]
        if enableFavorites {
            let title = starred ? tr("Unfavorite", "Favorit entfernen") : tr("Favorite", "Favorit")
            actions.append(actionListItem(title: title, systemImage: starred ? "heart.fill" : "heart") { _, c in
                Task { await LibraryStore.shared.toggleStarAlbum(album) }; c()
            })
        }
        if let artistId = album.artistId {
            let candidate = LibraryStore.shared.artists.first { $0.id == artistId }
                ?? DownloadStore.shared.artists.first { $0.artistId == artistId }?.asArtist()
            if let artist = candidate {
                let row = CPListItem(text: tr("View Artist", "Zum Künstler"), detailText: artist.name)
                row.accessoryType = .disclosureIndicator
                row.handler = { _, c in openArtist(artist, from: ic); c() }
                actions.append(row)
            }
        }

        let actionsSection = CPListSection(items: actions, header: album.name, sectionIndexTitle: nil)

        var songItems = songs.enumerated().map { idx, song in
            songListItem(song, index: idx) { _, c in
                AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
            }
        }
        let songsSection = CPListSection(items: songItems, header: tr("Songs", "Titel"), sectionIndexTitle: nil)
        let template = CPListTemplate(title: album.name, sections: [actionsSection, songsSection])

        Task {
            let coverArtId = album.coverArt ?? songs.first?.coverArt
            guard let id = coverArtId else { return }
            let images = await batchLoadCovers([(item: CPListItem(text: "", detailText: nil), coverArtId: id)])
            guard let img = images[id] else { return }
            songItems = songs.enumerated().map { idx, song in
                let item = songListItem(song, index: idx) { _, c in
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
                }
                item.setImage(img)
                return item
            }
            let updated = CPListSection(items: songItems, header: tr("Songs", "Titel"), sectionIndexTitle: nil)
            guard template.sections.count >= 2 else { return }
            template.updateSections([template.sections[0], updated])
        }

        return template
    }

    // MARK: - Artist

    static func openArtist(_ artist: Artist, from ic: CPInterfaceController) {
        Task {
            let albums: [Album]
            if OfflineModeService.shared.isOffline {
                albums = DownloadStore.shared.artists
                    .first { $0.artistId == artist.id }?.albums.map { $0.asAlbum() } ?? []
            } else {
                albums = (try? await SubsonicAPIService.shared.getArtist(id: artist.id))?.album ?? []
            }
            let t = artistDetailTemplate(artist: artist, albums: albums, ic: ic)
            ic.pushTemplate(t, animated: true, completion: nil)
        }
    }

    static func artistDetailTemplate(artist: Artist, albums: [Album], ic: CPInterfaceController) -> CPListTemplate {
        let enableFavorites = UserDefaults.standard.bool(forKey: "enableFavorites")
        let starred = LibraryStore.shared.isArtistStarred(artist)

        var actions: [CPListItem] = [
            actionListItem(title: tr("Play All", "Alles abspielen"), systemImage: "play.fill") { _, c in
                Task { @MainActor in
                    let songs = await artistSongs(artist)
                    guard !songs.isEmpty else { return }
                    AudioPlayerService.shared.play(songs: songs, startIndex: 0)
                }
                c()
            },
            actionListItem(title: tr("Shuffle All", "Zufällig abspielen"), systemImage: "shuffle") { _, c in
                Task { @MainActor in
                    let songs = await artistSongs(artist)
                    guard !songs.isEmpty else { return }
                    AudioPlayerService.shared.playShuffled(songs: songs)
                }
                c()
            },
            actionListItem(title: tr("Play Next", "Als nächstes"), systemImage: "text.insert") { _, c in
                Task { @MainActor in
                    let songs = await artistSongs(artist)
                    guard !songs.isEmpty else { return }
                    AudioPlayerService.shared.addPlayNext(songs)
                }
                c()
            },
            actionListItem(title: tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.append") { _, c in
                Task { @MainActor in
                    let songs = await artistSongs(artist)
                    guard !songs.isEmpty else { return }
                    AudioPlayerService.shared.addToQueue(songs)
                }
                c()
            },
        ]
        if enableFavorites {
            let title = starred ? tr("Unfavorite", "Favorit entfernen") : tr("Favorite", "Favorit")
            actions.append(actionListItem(title: title, systemImage: starred ? "heart.fill" : "heart") { _, c in
                Task { await LibraryStore.shared.toggleStarArtist(artist) }; c()
            })
        }

        let actionsSection = CPListSection(items: actions, header: artist.name, sectionIndexTitle: nil)

        var albumItems = albums.map { album in
            albumListItem(album) { _, c in openAlbum(album, from: ic); c() }
        }
        let albumsSection = CPListSection(items: albumItems, header: tr("Albums", "Alben"), sectionIndexTitle: nil)
        let template = CPListTemplate(title: artist.name, sections: [actionsSection, albumsSection])

        Task {
            let imageMap = await batchLoadCovers(albums.map { (item: CPListItem(text: "", detailText: nil), coverArtId: $0.coverArt) })
            guard !imageMap.isEmpty else { return }
            albumItems = albums.map { album -> CPListItem in
                let item = albumListItem(album) { _, c in openAlbum(album, from: ic); c() }
                if let id = album.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            let updated = CPListSection(items: albumItems, header: tr("Albums", "Alben"), sectionIndexTitle: nil)
            guard template.sections.count >= 2 else { return }
            template.updateSections([template.sections[0], updated])
        }

        return template
    }

    // MARK: - Playlist

    static func openPlaylist(_ playlist: Playlist, from ic: CPInterfaceController) {
        Task {
            let allSongs = (await LibraryStore.shared.loadPlaylistDetail(id: playlist.id))?.songs ?? []
            let songs: [Song]
            if OfflineModeService.shared.isOffline {
                songs = allSongs.filter { DownloadStore.shared.isDownloaded(songId: $0.id) }
            } else {
                songs = allSongs
            }
            let t = playlistDetailTemplate(playlist: playlist, songs: songs, ic: ic)
            ic.pushTemplate(t, animated: true, completion: nil)
        }
    }

    static func playlistDetailTemplate(playlist: Playlist, songs: [Song], ic: CPInterfaceController) -> CPListTemplate {
        let actions: [CPListItem] = [
            actionListItem(title: tr("Play", "Abspielen"), systemImage: "play.fill") { _, c in
                AudioPlayerService.shared.play(songs: songs, startIndex: 0); c()
            },
            actionListItem(title: tr("Shuffle", "Zufällig"), systemImage: "shuffle") { _, c in
                AudioPlayerService.shared.playShuffled(songs: songs); c()
            },
            actionListItem(title: tr("Play Next", "Als nächstes"), systemImage: "text.insert") { _, c in
                AudioPlayerService.shared.addPlayNext(songs); c()
            },
            actionListItem(title: tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.append") { _, c in
                AudioPlayerService.shared.addToQueue(songs); c()
            },
        ]
        let actionsSection = CPListSection(items: actions, header: playlist.name, sectionIndexTitle: nil)

        var songItems = songs.enumerated().map { idx, song in
            songListItem(song, index: idx) { _, c in
                AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
            }
        }
        let songsSection = CPListSection(items: songItems, header: tr("Songs", "Titel"), sectionIndexTitle: nil)
        let template = CPListTemplate(title: playlist.name, sections: [actionsSection, songsSection])

        Task {
            let pairs = songs.map { (item: CPListItem(text: "", detailText: nil), coverArtId: $0.coverArt) }
            let imageMap = await batchLoadCovers(pairs)
            guard !imageMap.isEmpty else { return }
            songItems = songs.enumerated().map { idx, song -> CPListItem in
                let item = songListItem(song, index: idx) { _, c in
                    AudioPlayerService.shared.play(songs: songs, startIndex: idx); c()
                }
                if let id = song.coverArt, let img = imageMap[id] { item.setImage(img) }
                return item
            }
            let updated = CPListSection(items: songItems, header: tr("Songs", "Titel"), sectionIndexTitle: nil)
            guard template.sections.count >= 2 else { return }
            template.updateSections([template.sections[0], updated])
        }

        return template
    }

    // MARK: - Private

    private static func artistSongs(_ artist: Artist) async -> [Song] {
        if OfflineModeService.shared.isOffline {
            return DownloadStore.shared.artists
                .first { $0.artistId == artist.id }?
                .albums.flatMap { $0.songs.map { $0.asSong() } } ?? []
        }
        return await LibraryStore.shared.fetchAllSongs(for: artist)
    }
}
