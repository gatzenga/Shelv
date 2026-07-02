import CarPlay
import Combine

private final class CarPlayTemplateTaskBag {
    var tasks: [Task<Void, Never>]

    init(tasks: [Task<Void, Never>]) {
        self.tasks = tasks
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    deinit {
        cancel()
    }
}

@MainActor
private enum CarPlayTemplateTaskRegistry {
    private static var bags: [ObjectIdentifier: CarPlayTemplateTaskBag] = [:]

    static func setTasks(_ tasks: [Task<Void, Never>], for template: CPListTemplate, in ic: CPInterfaceController) {
        let id = ObjectIdentifier(template)
        bags[id]?.cancel()

        let bag = CarPlayTemplateTaskBag(tasks: tasks)
        bag.tasks.append(Task { @MainActor [weak template, weak ic] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let template, let ic else {
                    Self.cancel(id)
                    return
                }
                guard ic.templates.contains(where: { $0 === template }) else {
                    Self.cancel(id)
                    return
                }
            }
        })
        bags[id] = bag
    }

    private static func cancel(_ id: ObjectIdentifier) {
        let bag = bags.removeValue(forKey: id)
        bag?.cancel()
    }

    static func cancelAll() {
        let allBags = bags.values
        bags.removeAll()
        allBags.forEach { $0.cancel() }
    }
}

@MainActor
enum CarPlayNavigation {

    static func cancelTemplateTasks() {
        CarPlayTemplateTaskRegistry.cancelAll()
    }

    // MARK: - Safe Push

    static func safePush(_ template: CPTemplate, on ic: CPInterfaceController) {
        guard ic.topTemplate !== template else { return }
        // Apple's CarPlay-Hierarchy-Limit ist 5 inkl. Root. Wenn Audio läuft, belegt
        // das automatisch sichtbare CPNowPlayingTemplate einen virtuellen Slot, also
        // effektiv 4. Statt den Push stillschweigend zu droppen (User klickt, nichts
        // passiert) räumen wir den Stack auf den Tab-Root zurück und pushen frisch.
        let player = AudioPlayerService.shared
        let hasActiveNowPlaying = player.currentSong != nil || player.currentRadioStation != nil
        let cap = hasActiveNowPlaying ? 4 : 5
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
                    CPListItem(text: String(localized: "loading"), detailText: nil)
                ], header: nil, sectionIndexTitle: nil)]
            )
            safePush(template, on: ic)

            let songs: [Song]
            if OfflineModeService.shared.isOffline {
                songs = DownloadStore.shared.albums
                    .first { $0.albumId == album.id }?.songs.map { $0.asSong() } ?? []
            } else {
                let fetched = (try? await LibraryStore.shared.fetchAlbumSongs(album)) ?? []
                if fetched.isEmpty {
                    songs = DownloadStore.shared.albums
                        .first { $0.albumId == album.id }?.songs.map { $0.asSong() } ?? []
                } else {
                    songs = fetched
                }
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
            let enableFavorites = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
                && !OfflineModeService.shared.isOffline
            let enableInstantMix = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
                && !OfflineModeService.shared.isOffline
            let starred = LibraryStore.shared.isAlbumStarred(album)

            var actions: [(icon: String, label: String, handler: () -> Void)] = [
                (icon: "play.fill", label: String(localized: "play"), handler: {
                    AudioPlayerService.shared.play(songs: songs, startIndex: 0)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
                (icon: "shuffle", label: String(localized: "shuffle"), handler: {
                    AudioPlayerService.shared.playShuffled(songs: songs)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
            ]
            if enableInstantMix {
                actions.append((icon: "sparkles", label: String(localized: "instant_mix"), handler: {
                    InstantMixService.playAlbumMix(for: album)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }))
            }
            actions.append(contentsOf: [
                (icon: "text.insert", label: String(localized: "play_next"), handler: {
                    AudioPlayerService.shared.addPlayNext(songs)
                    rebuildActionsAsync()
                }),
                (icon: "text.append", label: String(localized: "add_to_queue"), handler: {
                    AudioPlayerService.shared.addToQueue(songs)
                    rebuildActionsAsync()
                }),
            ])
            if enableFavorites {
                let icon = starred ? "heart.fill" : "heart"
                let label = starred ? String(localized: "unfavorite") : String(localized: "favorite")
                actions.append((icon: icon, label: label, handler: {
                    Task { await LibraryStore.shared.toggleStarAlbum(album) }
                }))
            }

            var items = makeActionItems(actions)
            if let artistId = album.artistId {
                let candidate = LibraryStore.shared.artists.first { $0.id == artistId }
                    ?? DownloadStore.shared.artists.first { $0.artistId == artistId }?.asArtist()
                if let artist = candidate {
                    let row = CPListItem(text: String(localized: "view_artist"), detailText: artist.name)
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
            return CPListSection(items: items, header: String(localized: "songs"), sectionIndexTitle: nil)
        }
        template.updateSections([makeActionsSection(), makeSongsSection()])

        let tasks = [
            Task { @MainActor [weak template] in
                var lastEnabled = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
                var lastInstantMix = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
                var lastTheme   = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                    let currentEnabled = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
                    let currentInstantMix = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
                    let currentTheme   = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                    guard currentEnabled != lastEnabled
                            || currentInstantMix != lastInstantMix
                            || currentTheme != lastTheme
                    else { continue }
                    lastEnabled = currentEnabled
                    lastInstantMix = currentInstantMix
                    lastTheme   = currentTheme
                    guard let t = template else { return }
                    let snap = t.sections
                    guard snap.count >= 2 else { return }
                    t.updateSections([makeActionsSection(), snap[1]])
                }
            },
            Task { @MainActor [weak template] in
                for await _ in LibraryStore.shared.$starredAlbums.dropFirst(1).values {
                    guard let t = template else { return }
                    let snap = t.sections
                    guard snap.count >= 2 else { return }
                    t.updateSections([makeActionsSection(), snap[1]])
                }
            },
            Task { @MainActor [weak template] in
                for await _ in OfflineModeService.shared.$isOffline.dropFirst(1).values {
                    guard let t = template else { return }
                    let snap = t.sections
                    guard snap.count >= 2 else { return }
                    t.updateSections([makeActionsSection(), snap[1]])
                }
            }
        ]
        CarPlayTemplateTaskRegistry.setTasks(tasks, for: template, in: ic)
    }

    // MARK: - Artist

    static func openArtist(_ artist: Artist, from ic: CPInterfaceController) {
        Task { @MainActor in
            let template = CPListTemplate(
                title: artist.name,
                sections: [CPListSection(items: [
                    CPListItem(text: String(localized: "loading"), detailText: nil)
                ], header: nil, sectionIndexTitle: nil)]
            )
            safePush(template, on: ic)

            let albums: [Album]
            if OfflineModeService.shared.isOffline {
                albums = downloadedAlbums(for: artist)
            } else {
                let fetched = (try? await SubsonicAPIService.shared.getArtist(id: artist.id))?.album ?? []
                albums = fetched.isEmpty ? downloadedAlbums(for: artist) : fetched
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
            let enableFavorites = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
                && !OfflineModeService.shared.isOffline
            let enableInstantMix = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
                && !OfflineModeService.shared.isOffline
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
                (icon: "play.fill", label: String(localized: "play"), handler: playAction({ AudioPlayerService.shared.play(songs: $0, startIndex: 0) }, navigateToPlayer: true)),
                (icon: "shuffle", label: String(localized: "shuffle"), handler: playAction({ AudioPlayerService.shared.playShuffled(songs: $0) }, navigateToPlayer: true)),
            ]
            if enableInstantMix {
                actions.append((icon: "sparkles", label: String(localized: "instant_mix"), handler: {
                    InstantMixService.playArtistMix(for: artist)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }))
            }
            actions.append(contentsOf: [
                (icon: "text.insert", label: String(localized: "play_next"), handler: playAction({ AudioPlayerService.shared.addPlayNext($0) })),
                (icon: "text.append", label: String(localized: "add_to_queue"), handler: playAction({ AudioPlayerService.shared.addToQueue($0) })),
            ])
            if enableFavorites {
                let icon = starred ? "heart.fill" : "heart"
                let label = starred ? String(localized: "unfavorite") : String(localized: "favorite")
                actions.append((icon: icon, label: label, handler: {
                    Task { await LibraryStore.shared.toggleStarArtist(artist) }
                }))
            }

            return CPListSection(items: makeActionItems(actions), header: artist.name, sectionIndexTitle: nil)
        }

        func makeAlbumsSection() -> (section: CPListSection, coverMap: [String: [CPListItem]]) {
            var coverMap: [String: [CPListItem]] = [:]
            let sortedAlbums = albums.sorted {
                stripArticle($0.name).localizedStandardCompare(stripArticle($1.name)) == .orderedAscending
            }
            let items = sortedAlbums.map { album -> CPListItem in
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
            return (CPListSection(items: items, header: String(localized: "albums"), sectionIndexTitle: nil), coverMap)
        }

        let (albumsSection, initialCoverMap) = makeAlbumsSection()
        template.updateSections([makeActionsSection(), albumsSection])

        let tasks = [
            Task { @MainActor in
                await streamCovers(into: initialCoverMap)
            },
            Task { @MainActor [weak template] in
                var lastEnabled = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
                var lastInstantMix = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
                var lastTheme   = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                    let currentEnabled = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
                    let currentInstantMix = UserDefaults.standard.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
                    let currentTheme   = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                    guard currentEnabled != lastEnabled
                            || currentInstantMix != lastInstantMix
                            || currentTheme != lastTheme
                    else { continue }
                    lastEnabled = currentEnabled
                    lastInstantMix = currentInstantMix
                    lastTheme   = currentTheme
                    guard let t = template else { return }
                    let snap = t.sections
                    guard snap.count >= 2 else { return }
                    t.updateSections([makeActionsSection(), snap[1]])
                }
            },
            Task { @MainActor [weak template] in
                for await _ in LibraryStore.shared.$starredArtists.dropFirst(1).values {
                    guard let t = template else { return }
                    let snap = t.sections
                    guard snap.count >= 2 else { return }
                    t.updateSections([makeActionsSection(), snap[1]])
                }
            },
            Task { @MainActor [weak template] in
                for await _ in OfflineModeService.shared.$isOffline.dropFirst(1).values {
                    guard let t = template else { return }
                    let snap = t.sections
                    guard snap.count >= 2 else { return }
                    t.updateSections([makeActionsSection(), snap[1]])
                }
            }
        ]
        CarPlayTemplateTaskRegistry.setTasks(tasks, for: template, in: ic)
    }

    // MARK: - Playlist

    static func openPlaylist(_ playlist: Playlist, from ic: CPInterfaceController) {
        Task { @MainActor in
            let template = CPListTemplate(
                title: playlist.name,
                sections: [CPListSection(items: [
                    CPListItem(text: String(localized: "loading"), detailText: nil)
                ], header: nil, sectionIndexTitle: nil)]
            )
            safePush(template, on: ic)

            let songs: [Song]
            if OfflineModeService.shared.isOffline {
                let ids = DownloadStore.shared.playlistSongIds[playlist.id] ?? []
                let downloadedSongs = ids.compactMap { id in
                    DownloadStore.shared.songs.first { $0.songId == id }?.asSong()
                }
                if downloadedSongs.isEmpty {
                    songs = ((await LibraryStore.shared.loadPlaylistDetail(id: playlist.id))?.songs ?? [])
                        .filter { DownloadStore.shared.isDownloaded(songId: $0.id) }
                } else {
                    songs = downloadedSongs
                }
            } else {
                if let detail = await LibraryStore.shared.loadPlaylistDetail(id: playlist.id) {
                    songs = detail.songs ?? []
                } else if DownloadStore.shared.offlinePlaylistIds.contains(playlist.id) {
                    let ids = DownloadStore.shared.playlistSongIds[playlist.id] ?? []
                    songs = ids.compactMap { id in
                        DownloadStore.shared.songs.first { $0.songId == id }?.asSong()
                    }
                } else {
                    songs = []
                }
            }
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
                ("play.fill",   String(localized: "play"), {
                    AudioPlayerService.shared.play(songs: songs, startIndex: 0)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
                ("shuffle",     String(localized: "shuffle"), {
                    AudioPlayerService.shared.playShuffled(songs: songs)
                    presentNowPlaying(on: ic)
                    rebuildActionsAsync()
                }),
                ("text.insert", String(localized: "play_next"), {
                    AudioPlayerService.shared.addPlayNext(songs)
                    rebuildActionsAsync()
                }),
                ("text.append", String(localized: "add_to_queue"), {
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
            return (CPListSection(items: items, header: String(localized: "songs"), sectionIndexTitle: nil), coverMap)
        }

        let (songsSection, initialCoverMap) = makeSongsSection()
        template.updateSections([makeActionsSection(), songsSection])

        let tasks = [
            Task { @MainActor in
                await streamCovers(into: initialCoverMap)
            },
            Task { @MainActor [weak template] in
                var lastTheme = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                    let currentTheme = UserDefaults.standard.string(forKey: "themeColor") ?? "violet"
                    guard currentTheme != lastTheme else { continue }
                    lastTheme = currentTheme
                    guard let t = template else { return }
                    let snap = t.sections
                    guard snap.count >= 2 else { return }
                    t.updateSections([makeActionsSection(), snap[1]])
                }
            }
        ]
        CarPlayTemplateTaskRegistry.setTasks(tasks, for: template, in: ic)
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
