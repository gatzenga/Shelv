# Download-Badge & Offline-Recap-Detail – Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Download-Badge in Playlist- und Recap-Rows anzeigen; (2) RecapDetailView offline-fähig machen via LibraryStore-Cache statt direktem API-Call.

**Architecture:** Beide Änderungen sind unabhängig und minimal. Task 1 fügt eine neue `PlaylistDownloadBadge`-Struct hinzu und bindet sie in zwei Views ein. Task 2 tauscht in `RecapDetailView.load()` den direkten `SubsonicAPIService`-Call gegen `LibraryStore.loadPlaylistDetail(id:)` aus und ergänzt die fehlende `libraryStore`-Property.

**Tech Stack:** SwiftUI, Combine, `@ObservedObject`, `@AppStorage`, bestehende Shelv-Services

---

## Betroffene Dateien

| Datei | Änderung |
|---|---|
| `Shelv/Views/Shared/DownloadIndicators.swift` | neue `PlaylistDownloadBadge`-Struct anhängen |
| `Shelv/Views/Playlists/PlaylistsView.swift` | Badge in `playlistRow()` einbauen |
| `Shelv/Views/Recap/RecapView.swift` | Badge in `recapRow()` einbauen |
| `Shelv/Views/Recap/RecapDetailView.swift` | `libraryStore`-Property + `load()` umschreiben |

---

## Task 1: `PlaylistDownloadBadge` erstellen

**Files:**
- Modify: `Shelv/Views/Shared/DownloadIndicators.swift` (Ende der Datei, nach `AlbumDownloadBadge`)

`AlbumDownloadBadge` nutzt `DownloadStatusCache` (leichtgewichtiger Set nur für Album-IDs). Für Playlists gibt es keinen solchen Cache — wir beobachten `DownloadStore.shared` direkt. Da Playlists typischerweise im zweistelligen Bereich liegen, ist das unkritisch.

- [ ] **Schritt 1.1: Ende von `DownloadIndicators.swift` lesen, um den korrekten Einbauort zu bestätigen**

  Letzte Zeilen der Datei ansehen (nach `AlbumDownloadBadge`, ca. Zeile 108).

- [ ] **Schritt 1.2: `PlaylistDownloadBadge` nach `AlbumDownloadBadge` einfügen**

  Nach der schließenden `}` von `AlbumDownloadBadge` (Zeile ~108) einfügen:

  ```swift
  struct PlaylistDownloadBadge: View {
      let playlistId: String
      @ObservedObject private var downloadStore = DownloadStore.shared
      @AppStorage("themeColor") private var themeColorName = "violet"
      @AppStorage("enableDownloads") private var enableDownloads = false

      var body: some View {
          if enableDownloads && downloadStore.offlinePlaylistIds.contains(playlistId) {
              Image(systemName: "arrow.down.circle.fill")
                  .font(.caption)
                  .foregroundStyle(.white)
                  .padding(4)
                  .background(AppTheme.color(for: themeColorName), in: Circle())
                  .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
          }
      }
  }
  ```

  Visuell identisch mit `AlbumDownloadBadge` — gleiche Farbe, gleiche Form, gleiche Größe.

- [ ] **Schritt 1.3: Build prüfen**

  Sicherstellen, dass das Projekt ohne Fehler kompiliert (Xcode oder `xcodebuild`).

---

## Task 2: Badge in `PlaylistsView.playlistRow()` einbauen

**Files:**
- Modify: `Shelv/Views/Playlists/PlaylistsView.swift` — Funktion `playlistRow(_:)` (ca. Zeile 293)

Aktueller Stand der `playlistRow`-Funktion:

```swift
private func playlistRow(_ playlist: Playlist) -> some View {
    HStack(spacing: 12) {
        AlbumArtView(coverArtId: playlist.coverArt, size: 150, cornerRadius: 8)
            .frame(width: 52, height: 52)
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(.primary)
            let count = offlineMode.isOffline
                ? downloadStore.downloadedCount(for: playlist.id)
                : playlist.songCount
            if let count {
                Text("\(count) \(tr("Songs", "Titel"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Spacer()
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
}
```

- [ ] **Schritt 2.1: Badge vor dem Chevron einsetzen**

  Den `Spacer()` + `Image(systemName: "chevron.right")`-Block ersetzen durch:

  ```swift
  Spacer()
  PlaylistDownloadBadge(playlistId: playlist.id)
  Image(systemName: "chevron.right")
      .font(.caption2)
      .foregroundStyle(.tertiary)
  ```

  Das Badge erscheint nur wenn `enableDownloads == true` und die Playlist im `offlinePlaylistIds`-Set ist — interne Guard-Logik liegt in `PlaylistDownloadBadge` selbst.

- [ ] **Schritt 2.2: Build prüfen**

---

## Task 3: Badge in `RecapView.recapRow()` einbauen

**Files:**
- Modify: `Shelv/Views/Recap/RecapView.swift` — Funktion `recapRow(_:)` (ca. Zeile 169)

Aktueller Stand am Ende des HStack in `recapRow`:

```swift
Spacer(minLength: 0)
Image(systemName: "chevron.right")
    .font(.caption.bold())
    .foregroundStyle(.tertiary)
```

- [ ] **Schritt 3.1: Badge vor dem Chevron einsetzen**

  ```swift
  Spacer(minLength: 0)
  PlaylistDownloadBadge(playlistId: entry.playlistId)
  Image(systemName: "chevron.right")
      .font(.caption.bold())
      .foregroundStyle(.tertiary)
  ```

  Kein weiterer `enableDownloads`-Guard nötig — liegt bereits intern in `PlaylistDownloadBadge`.

- [ ] **Schritt 3.2: Build prüfen**

---

## Task 4: `RecapDetailView` offline-fähig machen

**Files:**
- Modify: `Shelv/Views/Recap/RecapDetailView.swift`

### Kontext

`RecapDetailView.load()` ruft aktuell direkt den Subsonic-API-Service auf:

```swift
let playlist = try await SubsonicAPIService.shared.getPlaylist(id: entry.playlistId)
```

Das schlägt im Flugmodus fehl. `LibraryStore.loadPlaylistDetail(id:)` liest offline vom Disk-Cache und updated online den Cache — genau was wir brauchen. Die Methode wirft nicht, sondern gibt `Playlist?` zurück.

Pattern für LibraryStore in RecapView (bereits vorhanden, als Vorbild):
```swift
@ObservedObject var libraryStore = LibraryStore.shared
```

### Schritte

- [ ] **Schritt 4.1: `libraryStore`-Property zu `RecapDetailView` hinzufügen**

  Nach den bestehenden `@State`-Properties (nach `@State private var errorMessage: String?`) einfügen:

  ```swift
  @ObservedObject private var libraryStore = LibraryStore.shared
  ```

  Gleiches Muster wie in `RecapView.swift` (nicht `@EnvironmentObject`, weil `RecapDetailView` über `.sheet` präsentiert wird und dort EnvironmentObjects explizit weitergegeben werden müssten).

- [ ] **Schritt 4.2: `load()`-Funktion umschreiben**

  Aktuelle `load()`-Funktion (ca. Zeile 148–170):

  ```swift
  private func load() async {
      isLoading = true
      defer { isLoading = false }

      do {
          let playlist = try await SubsonicAPIService.shared.getPlaylist(id: entry.playlistId)
          let playlistSongs = playlist.songs ?? []

          let counts = await PlayLogService.shared.topSongs(
              serverId: serverId,
              from: Date(timeIntervalSince1970: entry.periodStart),
              to: Date(timeIntervalSince1970: entry.periodEnd),
              limit: period.type.songLimit
          )
          let countMap = Dictionary(uniqueKeysWithValues: counts.map { ($0.songId, $0.count) })

          songs = playlistSongs.map { song in
              SongWithCount(id: song.id, song: song, playCount: countMap[song.id] ?? 0)
          }
      } catch {
          errorMessage = error.localizedDescription
      }
  }
  ```

  Ersetzen durch:

  ```swift
  private func load() async {
      isLoading = true
      defer { isLoading = false }

      guard let playlist = await libraryStore.loadPlaylistDetail(id: entry.playlistId) else {
          errorMessage = tr("Playlist could not be loaded.", "Playlist konnte nicht geladen werden.")
          return
      }
      let playlistSongs = playlist.songs ?? []

      let counts = await PlayLogService.shared.topSongs(
          serverId: serverId,
          from: Date(timeIntervalSince1970: entry.periodStart),
          to: Date(timeIntervalSince1970: entry.periodEnd),
          limit: period.type.songLimit
      )
      let countMap = Dictionary(uniqueKeysWithValues: counts.map { ($0.songId, $0.count) })

      songs = playlistSongs.map { song in
          SongWithCount(id: song.id, song: song, playCount: countMap[song.id] ?? 0)
      }
  }
  ```

  Änderungen im Detail:
  - `try await SubsonicAPIService.shared.getPlaylist(id:)` → `await libraryStore.loadPlaylistDetail(id:)` mit `guard let`
  - `do/catch` entfällt — `loadPlaylistDetail` wirft nicht
  - Fehlermeldung nutzt `tr()` statt hartkodiertem String
  - `PlayLogService`-Calls bleiben unverändert (Zeilen 156–166 im Original)

- [ ] **Schritt 4.3: Hinweis zu doppelter Fehlermeldung**

  `loadPlaylistDetail` setzt im Online-Fehlerfall intern `libraryStore.errorMessage`. Das propagiert via `ContentView.onChange` als Alert. Gleichzeitig setzt unser `guard`-Zweig die lokale `errorMessage` in `RecapDetailView`. Das ist akzeptabel: der LibraryStore-Alert zeigt den Server-Fehler, unsere lokale Fehlermeldung den View-State. Falls das als doppelt wahrgenommen wird kann in einem separaten Fix `libraryStore.errorMessage = nil` nach dem `guard` gesetzt werden — aber das ist nicht Teil dieses Tasks.

- [ ] **Schritt 4.4: Build prüfen**

- [ ] **Schritt 4.5: Verifikation CarPlay-Pfad (kein Code-Change)**

  Verifizieren, dass `RecapDetailView` nicht im CarPlay-Code-Pfad genutzt wird. Suchen nach `RecapDetailView` in allen CarPlay-Dateien:

  ```bash
  grep -r "RecapDetailView" /Users/vasco/Repositorys/Shelv/Shelv/ --include="*.swift"
  ```

  Erwartetes Ergebnis: nur Treffer in `RecapView.swift` (`.sheet`-Präsentation) und `RecapDetailView.swift` selbst — kein CarPlay-Code.

---

## Akzeptanzkriterien

- [ ] Build clean, keine neuen Warnungen
- [ ] Playlist-Liste: Badge erscheint rechts neben heruntergeladenen Playlists (nur wenn `enableDownloads = true`)
- [ ] Recap-Liste: Badge erscheht rechts neben heruntergeladenen Recap-Playlists (nur wenn `enableDownloads = true`)
- [ ] Badge unsichtbar wenn `enableDownloads = false` oder Playlist nicht heruntergeladen
- [ ] Flugmodus + heruntergeladene Recap-Playlist öffnen: Songs werden angezeigt, kein Fehler
- [ ] Online: Verhalten unverändert (frische Daten + Cache-Update)
- [ ] CarPlay-Code unberührt
