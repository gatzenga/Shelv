# tvOS Feature-Angleichung & Bugfixes — Design

**Datum:** 2026-06-13
**Ziel:** Die Apple-TV-App (`Shelv TV/`) auf das Funktionsniveau der iOS-App (`Shelv/`) bringen — gemeldete Bugs beheben und bestehende, aber unvollständige Bereiche angleichen. **Keine Netto-Neu-Features**: nur das angleichen, was beide Plattformen konzeptionell schon haben, aber auf tvOS schwächer funktioniert.

---

## Leitprinzipien

- **Nur Angleichen, nichts Erfinden.** Bereiche, die auf tvOS konzeptionell ganz fehlen, bleiben außen vor (siehe „Out of Scope").
- **Geteilte Logik nutzen.** Fast alle nötigen APIs/Services liegen schon in `ShelvCore/` (Player-Methoden, `PinnedPlaylistStore`, Playlist-CRUD, Sync). tvOS muss sie nur anbinden — keine neue Backend-Logik.
- **tvOS-gerechte Interaktion.** Touch-Gesten (Swipe) werden durch **Long-Press-Kontextmenüs** ersetzt. Listen brauchen fokussierbare Elemente.
- **Konventionen (CLAUDE.md):** `String(localized:)` + `de/en.lproj` für alle Strings; `AppTheme.color(for:)` für Akzent; `CoverArtView`/`AlbumArtView` statt `AsyncImage`; Disk-IO via `Task.detached`.
- **Build-Gate:** Änderungen an `ShelvCore/` → **alle drei Targets** bauen (`Shelv`, `Shelv Mac`, `Shelv TV`). Reine tvOS-Änderungen → nur `Shelv TV`.
- **Commit-Stil:** Nach jedem abgeschlossenen, gebauten Paket ein eigener Commit (`feat(tvOS):` / `fix(tvOS):`), kein Co-Autor.

---

## Out of Scope (bewusst NICHT umsetzen)

- Downloads / Offline-Modus (Apple TV ist quasi immer online, wenig Speicher).
- Alphabet-Index-Bar (iOS-Touch-Konstrukt).
- Cover-Preview per Long-Press (iOS-Geste).
- Komplette Recap-Verwaltung in Settings (Registry/Verify/Markers-Logs) — eigenes Subsystem.
- Database Export/Import (Datei-Dialoge auf tvOS).

---

## Teil A — Bugfixes

### A1 — Play/Pause-Resume reaktiviert die Audio-Session nicht
**Symptom:** Pause funktioniert, erneutes Drücken setzt nicht fort (stiller Player).
**Ursache:** `AudioPlayerService.resume()` (ShelvCore, ~Z. 756) ruft nie `AVAudioSession.setActive(true)` auf. tvOS deaktiviert die Session nach Pause → nachfolgendes `player.play()` läuft ins Leere. Der Interruption-Handler (~Z. 350) macht es bereits korrekt vor.
**Fix:** In `resume()` vor `engine.resume()` `try? AVAudioSession.sharedInstance().setActive(true)` unter `#if os(iOS) || os(tvOS)`.
**Sekundär:** `setupAudioSession()` (~Z. 308-319) `setCategory`-Optionen prüfen (`.allowBluetoothHFP`/`.allowAirPlay` ggf. auf tvOS reduzieren), `catch` lauter loggen.
**Effekt:** Danach togglt die physische Play/Pause-Taste systemweit via `MPRemoteCommandCenter`.
**Optionaler Zusatz (niedrig):** `.onPlayPauseCommand` in Discover/Library, das bei vorhandenem Kontext den Mix/die Liste startet statt nur zu toggeln.
**Dateien:** `ShelvCore/Services/AudioPlayerService.swift` → **alle drei Targets bauen.**

### A2 — Settings-Navigation: kein Zurück + Logs nicht scrollbar
**Symptom:** Im Sync-/DB-Log lässt sich nicht scrollen; Zurück-Taste verlässt die ganze App.
**Ursache:** `LogListView` (`CacheSettingsView.swift:43-59`) rendert reine `Text`-Zeilen ohne fokussierbares Element. Auf tvOS scrollt eine `List` nur über den Fokus; ohne fokussierbares Element fängt der `NavigationStack` die Menu-Taste nicht als Pop ab → App-Exit.
**Fix:** Log-Zeilen `.focusable()` machen (auch den Empty-/`ContentUnavailableView`-Zweig). Deckt Sync-Log **und** DB-Errors ab.
**Dateien:** `Shelv TV/Views/Settings/CacheSettingsView.swift`. Generell alle reinen Text-Listen auf Fokussierbarkeit prüfen.

### A3 — Detail-Listen: zu kurz, Highlight abgeschnitten, Index-Overlap, Album≠Playlist
**Symptom:** AlbumDetail zeigt nur ~9/13 Songs trotz Platz; Now-Playing-/Fokus-Highlight links/rechts beschnitten; in Playlists überlappt der Schnellscroll-Index die Dauer; Playlist zeigt mehr Songs als Album.
**Ursache (gemeinsame Wurzel):** Die Song-`List`s nutzen den Default-Stil ohne Höhenvorgabe. `AlbumDetailView` (`:15`, `:56-75`) steckt die `List` in einen `HStack(.top)` ohne Höhe; Default-Stil zeichnet rechten Section-Index + beschnittenen Highlight. `QueueView` zeigt mit `.listStyle(.plain)` bereits das richtige Muster.
**Fix:** Auf Album- und Playlist-Detail-Listen `.listStyle(.plain)` + `.frame(maxHeight: .infinity)` + `.listRowInsets(...)` (horizontaler Innenabstand, damit Highlight-Rundung sichtbar bleibt). Album vs. Playlist bewusst konsistent (gleicher Stil, gleiche Row-Konfiguration).
**Dateien:** `Shelv TV/Views/Library/AlbumDetailView.swift`, `Shelv TV/Views/Playlists/PlaylistsView.swift`, `Shelv TV/Views/Library/LibraryCards.swift` (SongRow).

### A4 — Scroll-Position springt nicht zurück
**Symptom:** Beim Verlassen + Zurückkehren einer Liste bleibt der Scroll-Offset; man muss manuell hochscrollen.
**Ursache:** `LibraryView` (`:40-49`) nutzt nackte `ScrollView` ohne `scrollPosition`/`ScrollViewReader`. Kein Reset bei Re-Appear.
**Fix:** `scrollPosition(id:)` an State binden + bei Re-Appear/Segmentwechsel auf den ersten Eintrag setzen (bzw. Anchor-View oben + `scrollTo`).
**Dateien:** `Shelv TV/Views/Library/LibraryView.swift` (und analog andere scrollende Hauptlisten, falls betroffen).

### A5 — iCloud-Sync zeigt 0 Plays
**Symptom:** iCloud-Sync aktiv, Sync meldet „Done", aber „Gesamte Plays = 0" trotz >900 Plays; Recaps sortieren sich nicht ein.
**Ursache:** Start-Verkabelung ist korrekt (PlayLogService/PlayTracker/CloudKit/Entitlements vorhanden), aber `CloudKitSyncService.setup()` lädt **keine** Daten — der Download passiert nur in `downloadChanges()` via `syncNow()`, das beim Kaltstart nicht deterministisch läuft. Zusätzlich lädt `DatabaseSettingsView` (`:36`) `totalPlays` nur einmal in `.task`, ohne Live-Refresh.
**Fix:** (1) Im Startup-`.task` nach `CloudKitSyncService.shared.setup()` explizit `await CloudKitSyncService.shared.syncNow()`. (2) In `DatabaseSettingsView` `.onChange(of: syncStatus.lastSyncDate)` + `.onReceive(.recapRegistryUpdated)` → `refresh()`.
**Hinweis:** Hängt mit A1 zusammen — eigene neue Plays entstehen erst, wenn Wiedergabe zuverlässig durchläuft. Voraussetzung: derselbe Navidrome-User wie auf iOS (gleiche `stableId`).
**Dateien:** `Shelv TV/Shelv_TVApp.swift`, `Shelv TV/Views/Settings/DatabaseSettingsView.swift`.

---

## Teil B — Feature-Angleichungen

### B4 — Favorit-Toggle mit State (Grundlage)
*Voraussetzung für die Favorit-Aktionen in B1.* tvOS nutzt fire-and-forget `star()` ohne Unstar/State. iOS hat `isSongStarred`/`isAlbumStarred`/`isArtistStarred` + `toggleStar*` (optimistisch + Rollback) in `Shelv/ViewModels/LibraryStore.swift`.
**Fix:** Diese Toggle-/Status-Helfer in den tvOS-`LibraryStore` spiegeln. Überall wo Songs/Alben/Künstler gelistet sind nutzen.
**Dateien:** `Shelv TV/ViewModels/LibraryStore.swift`.

### B1 — Long-Press-Kontextmenüs überall
Aktionen via `.contextMenu`: **Play, Shuffle, Play Next, Queue, Favorit, Zu Playlist.** Alle Player-Methoden (`addPlayNext`, `addToQueue`, `playShuffled`) sind in ShelvCore vorhanden.
**Orte:** Library Album-/Artist-Cards, Song-Rows (Album-/Playlist-Detail), Playlist-Cards, Such-Ergebnisse.
**Dateien:** `LibraryCards.swift`, `AlbumDetailView.swift`, `PlaylistsView.swift`, `SearchView.swift`.

### B2 — Library: Sortierung + Grid/List
**Sortierung:** Alben (Alphabetical/Most Played/Recently Added/Year + Richtung), Künstler (Alphabetical/Most Played + Richtung). `LibraryStore.loadAlbums(sortBy:)` nimmt den Param schon; Sort-UI + `AlbumSortOption`/`ArtistSortOption` für das tvOS-Target fehlen.
**Grid/List:** Umschaltung separat für Alben/Künstler via `albumViewIsGrid`/`artistViewIsGrid` (AppStorage-Keys existieren). Künstler circular.
**Zusatz:** Künstler-Album-Anzahl lokal zählen (in `ArtistCard`).
**Dateien:** `LibraryView.swift`, `LibraryStore.swift`, `LibraryCards.swift`.

### B3 — Player-Angleichung
- **Seek/Scrubbing** statt read-only Progress (`player.seek(to:)` vorhanden) — tvOS-gerecht (Move-Command auf der Remote / fokussierbarer Slider).
- **Favorit-Button** im Player.
- **Stop-Button** (`player.stop()`).
- **Künstler-/Album-Tap** → Detail-Navigation (NowPlaying hat keinen NavigationStack — Mechanismus im Plan klären, z. B. Tab-Wechsel + Pfad oder eingebetteter Stack).
- **Buffering-Anzeige** via `showBufferingIndicator`.
**Dateien:** `Shelv TV/Views/NowPlaying/NowPlayingView.swift`.

### B5 — Playlists: volle Verwaltung
- **Sortierung:** Alphabetical/Last Modified/Date Created + Richtung.
- **Anpinnen:** `PinnedPlaylistStore` (shared) anbinden; angepinnte oben nach pinRank; Pin im Kontextmenü.
- **Erstellen / Umbenennen / Löschen:** neue tvOS-Eingabe-Sheets; APIs `createPlaylist`/`updatePlaylist`/`deletePlaylist` vorhanden.
- **Comment** im Playlist-Detail-Header anzeigen.
- **Kontextmenü** auf Playlist-Cards (Play/Shuffle/Play Next/Queue/Pin/Delete).
**Dateien:** `Shelv TV/Views/Playlists/PlaylistsView.swift`, neue Sheet-Views.

### B6 — ArtistDetail-Angleichung
Play/Shuffle/Favorit-Buttons; Album-Count im Header; Album-Sortierung (Alphabetical/Frequent/Newest/Year + Richtung) + Grid/List-Toggle (`artistDetailAlbum*`-Keys); Biografie-Box (Show More/Less, `getArtistInfo`).
**Dateien:** `Shelv TV/Views/Library/ArtistDetailView.swift`.

### B7 — AlbumDetail-Angleichung
Disc-Gruppierung (≥2 Discs); „spielt-gerade"-Indikator in der Trackliste; Künstler-Tap → ArtistDetail.
**Dateien:** `Shelv TV/Views/Library/AlbumDetailView.swift`, `LibraryCards.swift`.

### B8 — Kleinkram
- **Insights:** 30-Min-Cache (statt Reload bei jedem `.task`).
- **Recap-Detail:** dedizierte Ansicht mit Rang + Play-Count pro Song (statt generischer PlaylistDetail); Orphan-Warnung (`exclamationmark.triangle.fill`); Period-Icon/„Top X".
- **Search:** Kontextmenü auf Song-Ergebnissen (über B1 abgedeckt); Lyrics-Suche optional.
**Dateien:** `InsightsView.swift`, `RecapView.swift` (+ neue RecapDetail), `SearchView.swift`.

### Neu nötige UI-Komponenten (durch Scope-Entscheid)
- **AddToPlaylist-Auswahl-Sheet** (tvOS) — für „Zu Playlist" in B1/B5.
- **Playlist-Erstellen / -Umbenennen Sheets** — für B5.
*(Reine UI-Hüllen über vorhandene ShelvCore-APIs — keine neue Backend-Logik.)*

---

## Vorgeschlagene Umsetzungs-Reihenfolge

1. **A1** Play/Pause (höchster Schmerz, schaltet Wiedergabe frei) → alle Targets bauen.
2. **A5** iCloud-Sync (bringt die Plays/Recaps herein).
3. **A2, A3, A4** UI-/Navigations-Bugs (gemeinsame Listen-Wurzel).
4. **B4** Favorit-State (Grundlage), dann **B1** Kontextmenüs.
5. **B2** Library Sort/Grid, **B5** Playlists, **B3** Player.
6. **B6, B7** Detail-Views, **B8** Kleinkram + neue Sheets.

Jede Nummer ist ein eigener Commit (oder wenige), nach erfolgreichem Build.

---

## Verifikation

- Nach jedem Paket: betroffene(s) Target(s) bauen (`xcodebuild -scheme "Shelv TV"` bzw. zusätzlich `"Shelv"` + `"Shelv Mac"` bei ShelvCore-Änderungen).
- Manuelle Prüfpunkte im tvOS-Simulator/Gerät: Play/Pause-Toggle, Settings-Zurück, Album zeigt alle Songs, Scroll-Reset, Plays-Zähler > 0 nach Sync, Kontextmenü-Aktionen, Sortierung/Grid-Toggle, Pinnen, Playlist erstellen/löschen.
