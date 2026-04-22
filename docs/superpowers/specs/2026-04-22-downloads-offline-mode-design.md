# Downloads & Offline-Modus — Design

**Datum:** 2026-04-22
**Status:** Approved
**Targets:** iOS, macOS

---

## Ziel

Nutzer können Songs, Alben oder ganze Künstler lokal ablegen und im Offline-Modus ohne Server-Verbindung abspielen. Im Online-Modus sind Downloads ein zusätzlicher Status (Indikator-Icon), keine separate Sektion. Im Offline-Modus reduziert sich die App auf das, was lokal verfügbar ist.

---

## Datenmodell

### Neue SQLite-DB

`shelv_downloads.sqlite` in `Library/Application Support/`, via GRDB. **Separat** von `PlayLog`, weil andere Lifecycle (User-getriebenes Persistieren vs. Sync-Queue).

```sql
CREATE TABLE downloads (
  song_id TEXT NOT NULL,
  server_id TEXT NOT NULL,
  album_id TEXT NOT NULL,
  artist_id TEXT,
  title TEXT NOT NULL,
  album_title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  track INTEGER,
  disc INTEGER,
  duration INTEGER,
  bytes INTEGER NOT NULL,
  cover_art_id TEXT,
  is_favorite INTEGER NOT NULL DEFAULT 0,
  file_path TEXT NOT NULL,
  file_extension TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  PRIMARY KEY (song_id, server_id)
);

CREATE INDEX idx_downloads_album ON downloads(server_id, album_id);
CREATE INDEX idx_downloads_artist ON downloads(server_id, artist_id);
CREATE INDEX idx_downloads_favorite ON downloads(server_id, is_favorite);

CREATE TABLE missing_song_strikes (
  song_id TEXT NOT NULL,
  server_id TEXT NOT NULL,
  strike_count INTEGER NOT NULL,
  last_strike_at INTEGER NOT NULL,
  PRIMARY KEY (song_id, server_id)
);
```

`is_favorite` wird beim Download mitgeschrieben und bei jedem erfolgreichen Library-Refresh aktualisiert. Im Offline-Modus sind Favoriten-Toggle-Buttons komplett ausgeblendet — keine Pending-Queue nötig.

### Storage-Pfade

```
Library/Application Support/shelv_downloads/<serverUUID>/
  ├── <songId>.<ext>          # Originaldatei (mp3/flac/m4a etc.)
  └── <songId>_cover.jpg      # Cover Art in Player-Größe (600 px)
```

Application Support: kein iCloud-Backup, überlebt App-Updates, kein OS-Cleanup.

---

## Services

### DownloadService (actor, .shared)

Singleton-Actor verantwortlich für Download-Pipeline.

```swift
actor DownloadService {
    static let shared: DownloadService

    func enqueue(songs: [Song], serverId: String) async
    func enqueueAlbum(_ album: Album, serverId: String) async
    func enqueueArtist(_ artist: Artist, serverId: String) async
    func enqueueBulkDownload(serverId: String, maxBytes: Int64) async -> BulkDownloadPlan

    func cancel(songId: String, serverId: String) async
    func delete(songId: String, serverId: String) async throws
    func deleteAlbum(_ albumId: String, serverId: String) async throws
    func deleteArtist(_ artistId: String, serverId: String) async throws
    func deleteAllForServer(_ serverId: String) async throws
    func deleteAll() async throws

    func state(songId: String, serverId: String) -> DownloadState
    func progress(songId: String, serverId: String) -> Double?

    nonisolated var progressUpdates: AnyPublisher<[String: Double], Never>
}

enum DownloadState {
    case none
    case queued
    case downloading(progress: Double)
    case completed
    case failed(Error)
}
```

**URLSession-Konfiguration:** `URLSessionConfiguration.background(withIdentifier: "ch.vkugler.Shelv.downloads.<serverId>")`. Pro Server eine eigene Session, damit Server-Wechsel die Sessions sauber isolieren kann.

**Concurrency:** Max 3 gleichzeitige Downloads. Größere Queues werden FIFO abgearbeitet.

**Retry:** 3 Versuche pro Song mit exponential backoff (2s → 4s → 8s). Nach drittem Fehlschlag → State `.failed`, kein Auto-Retry. User kann manuell neu downloaden.

**Cover-Download:** Direkt nach erfolgreichem Audio-Download wird das Cover (600 px) gefetched und in `<songId>_cover.jpg` abgelegt. Fehlschlag des Cover-Downloads ist kein Fehler des Songs.

**App-Start-Recovery:** Beim App-Start prüft DownloadService alle Songs mit State `.queued` oder `.downloading` und resumiert sie (URLSession.background bringt typischerweise eigene Recovery; ergänzend werden incomplete Files anhand der DB neu geplant).

### DownloadStore (@MainActor, @EnvironmentObject)

UI-facing Store, reaktiv auf DownloadService-Updates.

```swift
@MainActor
final class DownloadStore: ObservableObject {
    @Published var downloads: [DownloadedSong] = []
    @Published var downloadedAlbums: [DownloadedAlbum] = []
    @Published var downloadedArtists: [DownloadedArtist] = []
    @Published var favoriteDownloads: [DownloadedSong] = []
    @Published var inFlightProgress: [String: Double] = [:]
    @Published var totalBytes: Int64 = 0

    func isDownloaded(songId: String) -> Bool
    func downloadState(songId: String) -> DownloadState
    func localURL(for songId: String) -> URL?
    func coverURL(for songId: String) -> URL?

    func reload() async
}
```

Reagiert auf `serverStore.activeServerID` — bei Wechsel wird komplett neu geladen (analog `LibraryStore.resetInMemory()`).

### OfflineModeService

```swift
@MainActor
final class OfflineModeService: ObservableObject {
    @AppStorage("offlineModeEnabled") var isOffline: Bool = false
    @AppStorage("enableDownloads") var downloadsFeatureEnabled: Bool = false

    @Published var serverErrorBannerVisible: Bool = false

    func notifyServerError()
    func enterOfflineMode()
    func exitOfflineMode()
}
```

**Banner-Trigger:** Bei jedem Subsonic-API-Fehler ruft der Caller `OfflineModeService.shared.notifyServerError()` auf. Banner zeigt: „Server nicht erreichbar — Offline-Modus aktivieren?" mit zwei Buttons (Ja / Später).

### Erweiterung: SubsonicAPIService

```swift
func downloadSongData(songId: String, server: SubsonicServer, password: String) async throws -> URL
```

Nutzt Subsonic `download` Endpoint (Original-Format, kein Transcoding). Liefert temporäre URL die der DownloadService in den finalen Pfad verschiebt.

### Erweiterung: LibraryStore

In `loadAlbums` und `loadArtists`:

```swift
// Nach erfolgreichem Library-Refresh:
let serverSongIds = Set(allSongsFromServer.map(\.id))
let downloadedIds = await DownloadService.shared.allDownloadedSongIds(serverId)
let missingNow = downloadedIds.subtracting(serverSongIds)

for id in missingNow {
    let strikes = await downloadDB.incrementStrike(songId: id, serverId: serverId)
    if strikes >= 2 {
        try? await DownloadService.shared.delete(songId: id, serverId: serverId)
    }
}

// Reset strikes für gefundene Songs:
let foundAgain = downloadedIds.intersection(serverSongIds)
await downloadDB.resetStrikes(songIds: Array(foundAgain), serverId: serverId)

// is_favorite mitsynchronisieren:
await downloadDB.syncFavoriteStatus(serverId: serverId, starredIds: starredSongIds)
```

Strike-Logik: Ein Song muss 2 aufeinanderfolgende Library-Refreshes lang fehlen, bevor er gelöscht wird. Schützt gegen einzelne Navidrome-Fehlantworten (Lehre aus Recap-Cleanup-Bug).

### Erweiterung: ServerStore

```swift
func delete(server: SubsonicServer) {
    // ... existing code (Keychain, list, PlayLog reset)
    Task { try? await DownloadService.shared.deleteAllForServer(server.id) }
}
```

---

## AudioPlayerService-Integration

In `play(song:)` und allen Stellen die eine Stream-URL holen:

```swift
let url = downloadStore.localURL(for: song.id)
       ?? api.streamURL(for: song.id, server: activeServer, password: pw)
```

`CrossfadeEngine` schluckt `file://` URLs nativ — kein Engine-Change nötig.

**Im Offline-Modus:**
- `play(song:)` mit nicht-heruntergeladenem Song → No-Op + Toast „Nicht offline verfügbar"
- `addToQueue` / `addToPlayNext` filtern nicht-heruntergeladene Songs raus
- `playShuffled` filtert vorher

---

## Bulk-Download-Algorithmus

```swift
func enqueueBulkDownload(serverId: String, maxBytes: Int64) async -> BulkDownloadPlan {
    var planned: [Song] = []
    var skipped: [Song] = []
    var totalBytes: Int64 = 0

    let alreadyDownloaded = Set(await downloadDB.allSongIds(serverId))

    // 1. Most-Played (all-time aus play_log, DESC nach play_count)
    // 2. Recently-Played (aus play_log, played_at DESC, dedup gegen 1)
    // 3. Favoriten (nur wenn enableFavorites = true)
    // 4. Rest alphabetisch nach Album, dann Track

    let candidates = await orderedCandidates(serverId: serverId)

    for song in candidates {
        if alreadyDownloaded.contains(song.id) { continue }
        let estimatedBytes = song.size ?? estimateSongSize(song)
        if totalBytes + estimatedBytes > maxBytes {
            skipped.append(song)
            continue
        }
        planned.append(song)
        totalBytes += estimatedBytes
    }

    return BulkDownloadPlan(planned: planned, skipped: skipped, totalBytes: totalBytes)
}
```

UI-Flow: Button → `BulkDownloadPlan` berechnen → Bestätigungsdialog („X Songs, ~Y GB werden geladen") → bei Bestätigung `enqueue(songs: planned)`.

Hard-Limit: nur für Bulk-Download. Manuelle Einzeldownloads (Context Menu / Swipe) ignorieren das Limit.

---

## UI

### Settings — neue Section „Downloads"

Position: zwischen „Playlists" Toggle und „Crossfade" Section.

Reihenfolge der Items:
1. **Toggle „Downloads aktivieren"** (`@AppStorage("enableDownloads")`)
2. **Toggle „Offline-Modus"** (disabled wenn Downloads off)
3. **Button „Bulk-Download starten"** (mit Bestätigungsdialog, zeigt geplante Songs/Größe)
4. **Stepper „Max Storage"** (1–500 GB, `@AppStorage("maxBulkDownloadStorageGB")`)
5. **Button „Alle Downloads löschen"** (rot, mit Confirmation-Dialog)
6. **Statistik-Section:**
   - Belegt: X.X GB von Y.Y GB frei auf Gerät
   - Songs: N | Alben: M | Künstler: K
   - Top 5 Künstler nach Größe (Liste mit Bar)

### Download-Trigger

**iOS:**
- Context Menu auf Album-/Artist-Card: „Herunterladen" / „Downloads löschen" (kontextabhängig)
- Context Menu auf Song-Row: „Herunterladen" / „Download löschen"
- Swipe-Action `.leading` auf Song-Row: `arrow.down.circle` (Akzentfarbe) — analog zu bestehender Favoriten-Swipe-Logik

**macOS:**
- Rechtsklick-Menü (analog zu „Add to Queue") auf Album, Künstler, Song
- Sidebar-Item-Context-Menu auf Playlist: „Alle Songs herunterladen"

### Indikatoren

- **Aktiv ladender Song:** Progress-Ring rechts (Position wo sonst Track-Dauer steht), Akzentfarbe
- **Fertig geladener Song:** `checkmark.circle.fill` rechts, `.secondary` Farbe, kleiner als der Ring
- **Album-/Artist-Card:** kleines Badge unten rechts (`arrow.down.circle.fill`, gefüllter Akzent-Background) wenn ≥ 1 Song lokal
- **Playlist-Card:** analog Album-Card

### Album/Playlist Detail-View Header

Kontextabhängiger Button im Header (zusätzlich zu Play/Shuffle):

| Status | Buttons |
|---|---|
| Nichts geladen | „Download" |
| Teilweise geladen | „Rest laden" + „Downloads löschen" |
| Komplett geladen | „Downloads löschen" |

### iOS Tab-Bar — Modus-abhängig

| Tab | Online | Offline |
|---|---|---|
| Discover | normal | Empty-State („Du bist offline") + Search-Button (Toolbar) |
| Library / Downloads | „Library" Label | „Downloads" Label, gleicher View-Slot |
| Playlists | normal | sichtbar wenn `enablePlaylists`, nur Playlists mit ≥ 1 lokalen Song, intern reduziert auf lokale Songs |
| Settings | normal | normal |
| Insights (Toolbar in Discover) | sichtbar | ausgeblendet |
| Recap (Toolbar in Discover) | sichtbar | ausgeblendet |
| Recap-Generation (Settings) | normal | Settings-Section sichtbar, „Generate"-Buttons disabled |

### macOS Sidebar — Modus-abhängig

Analog: `Library` Sidebar-Item wird zu `Downloads` im Offline-Modus, mit gleichem Sub-Layout (Albums / Artists / Favorites). Insights und Recap-Items werden ausgeblendet.

### Downloads-View

Identisch zur Library-View aufgebaut: Segmente Albums / Artists / Favorites (mit AlphabetIndexBar). Datenquelle ist `DownloadStore` statt `LibraryStore`.

- **Album-Detail:** zeigt nur die heruntergeladenen Songs (nicht die fehlenden — keine grayed-out Darstellung)
- **Artist-Detail:** zeigt nur Alben mit ≥ 1 lokalen Song; jedes Album zeigt nur lokale Songs
- **Favorites-Segment:** Songs aus `is_favorite = 1`, gruppiert nach Album

### Suche im Offline-Modus

`SearchView` schaltet auf lokale Suche um:
- Datenquelle: `DownloadStore` (alle Songs aus `downloads`-Tabelle)
- Implementierung: einfacher LIKE über `title`, `album_title`, `artist_name` (FTS später optional)
- Keine Server-Calls

### Server-Error-Banner

Neue View `ServerErrorBanner` — wird oberhalb der Tab-Bar eingeblendet wenn `OfflineModeService.serverErrorBannerVisible == true`. Zwei Buttons: „Offline-Modus aktivieren" (löst `enterOfflineMode()` aus) und „Schließen" (versteckt Banner).

---

## Server-Wechsel & Server-Delete

- `DownloadStore` reagiert auf `serverStore.activeServerID` und lädt nur Downloads des aktiven Servers
- `ServerStore.delete(server:)` zusätzlich:
  - `DownloadService.deleteAllForServer(serverId)` — File-System + DB-Einträge entfernen
  - Background-Session für diesen Server invalidieren (Cancel + new identifier)

---

## CLAUDE.md-Update

Neue Section nach „Server-Wechsel":

> **Server-Isolation:** Alles ist pro Server-UUID strikt getrennt — Library-Cache, Downloads, PlayLog, Recap-Registry, iCloud-CloudKit-Records, Listenings. Beim Server-Wechsel werden In-Memory-Stores resettet und nur Daten des aktiven Servers angezeigt. Beim Server-Delete werden alle lokalen Daten dieses Servers entfernt; iCloud bleibt unangetastet (Re-Login holt Stand zurück).

Plus neue Section „Downloads & Offline-Modus" mit Service-Übersicht und Storage-Pfaden.

---

## Was sich nicht ändert

- **CrossfadeEngine** — schluckt `file://` URLs nativ
- **ImageCacheService** — bleibt zuständig für Server-fetched Cover; heruntergeladene Cover werden direkt aus `<songId>_cover.jpg` geladen
- **LyricsStore** — bleibt unverändert, lokal-first via SQLite
- **CloudKitSyncService, PlayTracker, scrobble_queue** — laufen offline transparent weiter (lokal-first), kein Code-Change nötig

---

## AppStorage-Keys (neu)

| Key | Typ | Standard |
|---|---|---|
| `enableDownloads` | Bool | `false` |
| `offlineModeEnabled` | Bool | `false` |
| `maxBulkDownloadStorageGB` | Int | `10` |

---

## Edge Cases & Entscheidungen

| Fall | Verhalten |
|---|---|
| Song auf Server gelöscht, lokal vorhanden | Strike-Counter → bei 2× konsistent fehlend silent delete |
| Album-Metadaten ändern sich (neue Tracks) | Bestehende Downloads bleiben; neue Tracks erscheinen als „nicht geladen" |
| Server-Wechsel während Download läuft | Background-Session bleibt aktiv (eigener Identifier pro Server); UI zeigt nur aktive Server-Downloads |
| Speicher voll während Download | Aktueller Song failed, restliche Queue pausiert, Toast „Speicher voll" |
| User wechselt Server, Server B hat Downloads | Nur Downloads von B sichtbar, Downloads von A bleiben auf Disk |
| Bulk-Download mit Limit kleiner als erste Datei | Plan ist leer, Bestätigungsdialog zeigt „Keine Songs passen ins Limit" |
| Offline-Modus + Crossfade aktiv + nächster Song nicht lokal | Crossfade wird nicht ausgelöst (analog zu jetziger Logik bei leerer Queue) |
| User toggled Downloads-Feature aus | Bestehende Downloads bleiben, nur UI ausgeblendet; Re-Aktivierung zeigt sie wieder |
| App-Update / Reinstall | Application Support überlebt; DB-Migration falls Schema-Version steigt |

---

## Out of Scope (V1)

- Transcoded Downloads (max bitrate Setting) — kommt später
- WiFi-only Toggle — User-Verantwortung explizit so entschieden
- Auto-Download von Favoriten — manuelles Pinning reicht für V1
- LRU-Cleanup bei Storage-Druck — Hard-Limit + manuelles Delete reicht
- Pending-Favorite-Queue — Toggle ist offline ausgeblendet, keine Queue nötig
- Lyrics-Caching (LyricsStore ist schon lokal-first)
