# Local-First Artwork System – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alle heruntergeladenen Songs zeigen Coverbilder aus lokalen Dateien – unabhängig von Online-Status, Cold-Start oder Server-Wechsel; Artist-Images werden beim Download persistiert; iOS und Mac verhalten sich identisch.

**Architecture:** Ein neuer `LocalArtworkIndex`-Singleton (NSLock, wie `LocalDownloadIndex`) hält eine `[artId → localFilePath]`-Map. `AlbumArtView` (iOS) und `CoverArtView` (Mac) schlagen zuerst diesen Index nach, bevor sie Disk-Cache oder Netzwerk verwenden. `DownloadService` lädt beim Song-Download auch das Artist-Bild herunter; `artistCoverArtId` wird in der DB persistiert sodass der Index nach Cold-Start korrekt befüllt werden kann.

**Tech Stack:** SwiftUI, UIKit/AppKit, GRDB, NSCache, NSLock, URLSession background transfer, actor isolation

---

## File Map

| Aktion | Pfad |
|--------|------|
| Create | `Shelv/Shelv/Services/LocalArtworkIndex.swift` |
| Create | `Shelv Desktop/Shelv Desktop/Services/LocalArtworkIndex.swift` |
| Modify | `Shelv/Shelv/Services/DownloadDatabase.swift` — Migration v2 + `artistCoverArtId` Feld |
| Modify | `Shelv Desktop/Shelv Desktop/Services/DownloadDatabase.swift` — gleich |
| Modify | `Shelv/Shelv/Services/DownloadService.swift` — Artist-Download, `artistCoverArtId` im Job |
| Modify | `Shelv Desktop/Shelv Desktop/Services/DownloadService.swift` — gleich |
| Modify | `Shelv/Shelv/Models/DownloadModels.swift` — `artistCoverArtId` in `DownloadedSong` |
| Modify | `Shelv Desktop/Shelv Desktop/Models/DownloadModels.swift` — gleich |
| Modify | `Shelv/Shelv/ViewModels/DownloadStore.swift` — LocalArtworkIndex befüllen |
| Modify | `Shelv Desktop/Shelv Desktop/ViewModels/DownloadStore.swift` — gleich |
| Modify | `Shelv/Shelv/Services/ImageCacheService.swift` — `cache(_:key:)` Method |
| Modify | `Shelv Desktop/Shelv Desktop/Helpers/ImageCache.swift` — `cachedImage(url:)` + `cache(_:url:)` |
| Modify | `Shelv/Shelv/Views/Shared/AlbumArtView.swift` — Local-First Load |
| Modify | `Shelv Desktop/Shelv Desktop/Helpers/ImageCache.swift` — `CoverArtView` Local-First Load |
| Modify | `Shelv/Shelv/Views/Library/AlbumDetailView.swift` — Per-Song Cover in Track-Rows |
| Modify | `Shelv Desktop/Shelv Desktop/Views/AlbumDetailView.swift` — Per-Song Cover in `TrackRow` |
| Modify | `Shelv/Shelv/Views/LibraryView.swift` — @State-Vars → @ObservedObject DownloadStore |
| Modify | `Shelv Desktop/Shelv Desktop/ViewModels/LibraryViewModel.swift` — Offline Artist-Notification |

---

## Task 1: LocalArtworkIndex (iOS + Mac)

**Files:**
- Create: `Shelv/Shelv/Services/LocalArtworkIndex.swift`
- Create: `Shelv Desktop/Shelv Desktop/Services/LocalArtworkIndex.swift`

- [ ] **Step 1: iOS-Datei anlegen**

```swift
// Shelv/Shelv/Services/LocalArtworkIndex.swift
import Foundation

final class LocalArtworkIndex {
    static let shared = LocalArtworkIndex()
    private let lock = NSLock()
    private var index: [String: String] = [:]  // artId → absolute file path

    private init() {}

    func update(paths: [String: String]) {
        lock.lock()
        index = paths
        lock.unlock()
    }

    func set(artId: String, path: String?) {
        lock.lock()
        if let path { index[artId] = path } else { index.removeValue(forKey: artId) }
        lock.unlock()
    }

    func localPath(for artId: String) -> String? {
        lock.lock()
        let p = index[artId]
        lock.unlock()
        guard let p, FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }
}
```

- [ ] **Step 2: Mac-Datei anlegen** (identischer Inhalt, andere Zieldatei)

Datei: `Shelv Desktop/Shelv Desktop/Services/LocalArtworkIndex.swift` — identischer Code wie oben.

- [ ] **Step 3: iOS-Datei zu Xcode-Projekt hinzufügen**

Xcode öffnen → `Shelv.xcodeproj` → In der Dateiliste `Shelv/Services/` auswählen → Rechtsklick → „Add Files to Shelv" → `LocalArtworkIndex.swift` auswählen → Target `Shelv` angehakt → Add. (Mac PBXFileSystemSynchronizedRootGroup erledigt dies automatisch.)

- [ ] **Step 4: Build prüfen**

```bash
# iOS
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"

# Mac
xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" \
  -scheme "Shelv Desktop" -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded` für beide.

---

## Task 2: DB-Schema — `artistCoverArtId` Migration (iOS + Mac)

**Files:**
- Modify: `Shelv/Shelv/Services/DownloadDatabase.swift:6-45` (DownloadRecord) + `:117-156` (openAndMigrate)
- Modify: `Shelv Desktop/Shelv Desktop/Services/DownloadDatabase.swift` — gleich

- [ ] **Step 1: `DownloadRecord` iOS — neues Feld ergänzen**

In `Shelv/Shelv/Services/DownloadDatabase.swift`, nach der Zeile `var coverArtId: String?`:
```swift
    var artistCoverArtId: String?
```

Und in `toDownloadedSong()` den `DownloadedSong`-Konstruktor ergänzen (Task 3 führt das vollständig durch). Vorerst nur das Feld deklarieren — der Compiler wird dann die fehlenden Stellen anzeigen.

- [ ] **Step 2: Migration v2 iOS — Spalte hinzufügen**

In `openAndMigrate(at:)` nach `try m.migrate(p)` — nein, vor dieser Zeile. Nach dem `v1_create`-Block, aber vor `try m.migrate(p)`:

```swift
        m.registerMigration("v2_add_artist_cover") { db in
            try db.alter(table: "downloads") { t in
                t.add(column: "artistCoverArtId", .text)
            }
        }
```

- [ ] **Step 3: `DownloadRecord` Mac + Migration v2 Mac**

Gleiche Änderungen in `Shelv Desktop/Shelv Desktop/Services/DownloadDatabase.swift`:
- `var artistCoverArtId: String?` nach `var coverArtId: String?`
- `v2_add_artist_cover` Migration vor `try m.migrate(p)` einfügen

- [ ] **Step 4: Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: Compiler-Fehler wegen `toDownloadedSong()` — das ist korrekt (Task 3 behebt das).

---

## Task 3: Model-Updates — `DownloadedSong` (iOS + Mac)

**Files:**
- Modify: `Shelv/Shelv/Models/DownloadModels.swift:20-62`
- Modify: `Shelv Desktop/Shelv Desktop/Models/DownloadModels.swift` — gleich

- [ ] **Step 1: `DownloadedSong` iOS — Feld ergänzen**

In `Shelv/Shelv/Models/DownloadModels.swift`, nach `let coverArtId: String?` (Zeile 32):
```swift
    let artistCoverArtId: String?
```

- [ ] **Step 2: `toDownloadedSong()` iOS — Feld übergeben**

In `DownloadDatabase.swift`, `toDownloadedSong()` muss `artistCoverArtId` übergeben. Den Konstruktor-Aufruf updaten:

```swift
    func toDownloadedSong() -> DownloadedSong {
        DownloadedSong(
            songId: songId,
            serverId: serverId,
            albumId: albumId,
            artistId: artistId,
            title: title,
            albumTitle: albumTitle,
            artistName: artistName,
            track: track,
            disc: disc,
            duration: duration,
            bytes: bytes,
            coverArtId: coverArtId,
            artistCoverArtId: artistCoverArtId,
            isFavorite: isFavorite,
            filePath: filePath,
            fileExtension: fileExtension,
            addedAt: Date(timeIntervalSince1970: addedAt)
        )
    }
```

- [ ] **Step 3: `asSong()` iOS prüfen**

`asSong()` in `DownloadedSong` braucht kein `artistCoverArtId` — der `Song`-Struct hat kein solches Feld. Keine Änderung nötig.

- [ ] **Step 4: Mac identisch anpassen**

Gleiche Änderungen in `Shelv Desktop/Shelv Desktop/Models/DownloadModels.swift` und `Shelv Desktop/Shelv Desktop/Services/DownloadDatabase.swift` (toDownloadedSong).

- [ ] **Step 5: Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"

xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" \
  -scheme "Shelv Desktop" -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded` für beide (DownloadStore und AlbumArtView haben noch keine Änderungen).

---

## Task 4: Download-Pipeline — Artist-Image herunterladen (iOS + Mac)

**Files:**
- Modify: `Shelv/Shelv/Services/DownloadService.swift`
- Modify: `Shelv Desktop/Shelv Desktop/Services/DownloadService.swift`

### iOS

- [ ] **Step 1: `DownloadJob` — iOS Felder ergänzen**

In `DownloadService.swift` (iOS), `private struct DownloadJob` nach `let coverArtId: String?`:
```swift
    let artistCoverArtId: String?
    let artistCoverURL: URL?
```

- [ ] **Step 2: `enqueue()` iOS — Artist-Cover auflösen**

In `enqueue(songs:serverId:)`, vor dem `let job = DownloadJob(...)` Block:
```swift
            let artistName = song.artist ?? ""
            let artistCoverArtId: String? = await MainActor.run {
                LibraryStore.shared.artists.first { $0.name == artistName }?.coverArt
            }
            let artistCoverURL: URL? = artistCoverArtId.flatMap {
                api.api.coverArtURL(for: $0, server: api.server, password: api.password, size: 600)
            }
```

In `DownloadJob(...)` die neuen Felder hinzufügen (nach `coverArtId: song.coverArt`):
```swift
                artistCoverArtId: artistCoverArtId,
                artistCoverURL: artistCoverURL,
```

- [ ] **Step 3: Pfad-Helpers iOS — Artist-Artwork-Verzeichnis**

Am Ende des `DownloadService`, nach `coverPath(forFilePath:)`:
```swift
    static func artworkDirectory(serverId: String) -> URL {
        serverDirectory(serverId: serverId).appendingPathComponent("artwork", isDirectory: true)
    }

    static func artistCoverPath(serverId: String, artId: String) -> String {
        artworkDirectory(serverId: serverId).appendingPathComponent("\(artId).jpg").path
    }
```

- [ ] **Step 4: `downloadCoverIfNeeded` → `downloadAssetsIfNeeded` iOS**

Die private Methode umbenennen und Artist-Download ergänzen:
```swift
    private func downloadAssetsIfNeeded(for job: DownloadJob, audioPath: String) async {
        // Song-Cover
        let coverPath = Self.coverPath(forFilePath: audioPath)
        if !FileManager.default.fileExists(atPath: coverPath), let coverURL = job.coverURL {
            if let (data, _) = try? await coverSession.data(from: coverURL) {
                try? data.write(to: URL(fileURLWithPath: coverPath), options: .atomic)
            }
        }
        // Artist-Image
        if let artId = job.artistCoverArtId, let artURL = job.artistCoverURL {
            let artPath = Self.artistCoverPath(serverId: job.serverId, artId: artId)
            if !FileManager.default.fileExists(atPath: artPath) {
                let artDir = Self.artworkDirectory(serverId: job.serverId)
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                if let (data, _) = try? await coverSession.data(from: artURL) {
                    try? data.write(to: URL(fileURLWithPath: artPath), options: .atomic)
                }
            }
        }
    }
```

Den alten `downloadCoverIfNeeded`-Code entfernen.

- [ ] **Step 5: `handleCompletion` iOS — neuen Methodennamen + `artistCoverArtId` in Record**

In `handleCompletion`:
- Aufruf von `downloadCoverIfNeeded` → `downloadAssetsIfNeeded` umbenennen
- `DownloadRecord` ergänzen: nach `coverArtId: job.coverArtId,` einfügen:
```swift
            artistCoverArtId: job.artistCoverArtId,
```

- [ ] **Step 6: Mac — identische Änderungen**

In `Shelv Desktop/Shelv Desktop/Services/DownloadService.swift`:

`DownloadJob` Felder ergänzen (nach `coverArtId: String?`):
```swift
    let artistCoverArtId: String?
    let artistCoverURL: URL?
```

`enqueue()` — Artist-Cover auflösen (Mac verwendet `LibraryViewModel` statt `LibraryStore`):
```swift
            let artistName = song.artist ?? ""
            let artistCoverArtId: String? = await MainActor.run {
                LibraryViewModel.shared.artists.first { $0.name == artistName }?.coverArt
            }
            let artistCoverURL: URL? = artistCoverArtId.flatMap {
                api.coverArtURL(forConfig: cfg, id: $0, size: 600)
            }
```

In `DownloadJob(...)` nach `coverArtId: song.coverArt`:
```swift
                artistCoverArtId: artistCoverArtId,
                artistCoverURL: artistCoverURL,
```

Pfad-Helpers (gleich wie iOS, ans Ende von DownloadService):
```swift
    static func artworkDirectory(serverId: String) -> URL {
        serverDirectory(serverId: serverId).appendingPathComponent("artwork", isDirectory: true)
    }

    static func artistCoverPath(serverId: String, artId: String) -> String {
        artworkDirectory(serverId: serverId).appendingPathComponent("\(artId).jpg").path
    }
```

`downloadCoverIfNeeded` → `downloadAssetsIfNeeded` (gleicher Code wie iOS).

`handleCompletion` — Aufruf umbenennen + `artistCoverArtId: job.artistCoverArtId` in `DownloadRecord`.

- [ ] **Step 7: Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"

xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" \
  -scheme "Shelv Desktop" -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`. (DownloadStore kompiliert noch, weil `artistCoverArtId` optional ist.)

---

## Task 5: DownloadStore — LocalArtworkIndex befüllen (iOS + Mac)

**Files:**
- Modify: `Shelv/Shelv/ViewModels/DownloadStore.swift`
- Modify: `Shelv Desktop/Shelv Desktop/ViewModels/DownloadStore.swift`

- [ ] **Step 1: `reload()` iOS — LocalArtworkIndex befüllen**

In `reload()`, nach der `LocalDownloadIndex`-Zeile (`LocalDownloadIndex.shared.update(paths: paths)`), einfügen:

```swift
        var artPaths: [String: String] = [:]
        for song in mappedSongs {
            if let artId = song.coverArtId {
                let p = DownloadService.coverPath(forFilePath: song.filePath)
                if FileManager.default.fileExists(atPath: p) { artPaths[artId] = p }
            }
            if let artId = song.artistCoverArtId {
                let p = DownloadService.artistCoverPath(serverId: song.serverId, artId: artId)
                if FileManager.default.fileExists(atPath: p) { artPaths[artId] = p }
            }
        }
        LocalArtworkIndex.shared.update(paths: artPaths)
```

- [ ] **Step 2: `insertRecord()` iOS — inkrementeller Index-Update**

In `insertRecord(_:)`, nach `LocalDownloadIndex.shared.setPath(...)`:

```swift
        if let artId = song.coverArtId {
            let p = DownloadService.coverPath(forFilePath: song.filePath)
            if FileManager.default.fileExists(atPath: p) { LocalArtworkIndex.shared.set(artId: artId, path: p) }
        }
        if let artId = song.artistCoverArtId {
            let p = DownloadService.artistCoverPath(serverId: song.serverId, artId: artId)
            if FileManager.default.fileExists(atPath: p) { LocalArtworkIndex.shared.set(artId: artId, path: p) }
        }
```

- [ ] **Step 3: Artist-Cover aus DB verwenden**

In `reload()`, die Artist-Erstellung jetzt zusätzlich `artistCoverArtId` aus dem DB-Record nutzen. Die Zeile:
```swift
let cover = artistCoverByName[artistName] ?? first.coverArtId
```
ändern zu:
```swift
let cover = first.artistCoverArtId ?? artistCoverByName[artistName] ?? first.coverArtId
```

Das `DownloadedArtist.coverArtId` zeigt jetzt bevorzugt auf den Artist-spezifischen Cover-Art-ID (aus der DB, persistent), fällt dann auf die LibraryStore-Notification zurück (für neu heruntergeladene Songs noch ohne DB-Wert) und schließlich auf das Album-Cover.

In `insertRecord()`, die Artist-Erstellung (Zeile `let cover = artistCoverByName[artistName] ?? song.coverArtId`):
```swift
let cover = song.artistCoverArtId ?? artistCoverByName[artistName] ?? song.coverArtId
```

- [ ] **Step 4: Mac identisch anpassen**

Gleiche Änderungen in `Shelv Desktop/Shelv Desktop/ViewModels/DownloadStore.swift`:
- `reload()`: LocalArtworkIndex befüllen (gleicher Code)
- `insertRecord()`: LocalArtworkIndex inkrementell updaten (gleicher Code)
- Artist-Cover-Prio: `first.artistCoverArtId ?? artistCoverByName[artistName] ?? first.coverArtId`

- [ ] **Step 5: Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"

xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" \
  -scheme "Shelv Desktop" -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded` für beide.

- [ ] **Step 6: Commit**

```bash
cd /Users/vasco/Repositorys/Shelv
git add Shelv/Services/LocalArtworkIndex.swift \
        Shelv/Services/DownloadDatabase.swift \
        Shelv/Services/DownloadService.swift \
        Shelv/Models/DownloadModels.swift \
        Shelv/ViewModels/DownloadStore.swift \
        Shelv.xcodeproj/project.pbxproj

cd "/Users/vasco/Repositorys/Shelv Desktop"
git add "Shelv Desktop/Services/LocalArtworkIndex.swift" \
        "Shelv Desktop/Services/DownloadDatabase.swift" \
        "Shelv Desktop/Services/DownloadService.swift" \
        "Shelv Desktop/Models/DownloadModels.swift" \
        "Shelv Desktop/ViewModels/DownloadStore.swift"

git commit -m "feat: persist artist cover art ID in DB and build LocalArtworkIndex on reload"
```

---

## Task 6: ImageCacheService — Cache-Write-Methode (iOS + Mac)

**Files:**
- Modify: `Shelv/Shelv/Services/ImageCacheService.swift`
- Modify: `Shelv Desktop/Shelv Desktop/Helpers/ImageCache.swift`

- [ ] **Step 1: iOS — `cache(_:key:)` Method**

In `ImageCacheService` (iOS), nach `nonisolated func cachedImage(key:)`:
```swift
    nonisolated func cache(_ img: UIImage, key: String) {
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key as NSString, cost: cost)
    }
```

- [ ] **Step 2: Mac — `cachedImage(url:)` + `cache(_:url:)` Methods**

In `ImageCacheService` (Mac), nach der `private init()`:
```swift
    nonisolated func cachedImage(url: URL) -> NSImage? {
        memory.object(forKey: Self.stableCacheKey(for: url) as NSString)
    }

    nonisolated func cache(_ img: NSImage, url: URL) {
        let key = Self.stableCacheKey(for: url) as NSString
        let cost = Int(img.size.width * img.size.height * 4)
        memory.setObject(img, forKey: key, cost: cost)
    }
```

- [ ] **Step 3: Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

---

## Task 7: AlbumArtView (iOS) — Local-First Load

**Files:**
- Modify: `Shelv/Shelv/Views/Shared/AlbumArtView.swift:61-103`

- [ ] **Step 1: `load()` mit Local-First-Step ergänzen**

Die komplette `load()`-Methode ersetzen:

```swift
    @MainActor
    private func load() async {
        guard let id = coverArtId,
              let url = SubsonicAPIService.shared.coverArtURL(for: id, size: size)
        else { uiImage = nil; loading = false; return }

        let key = "\(id)_\(size)"

        // 1. Memory-Cache — sofortige Rückgabe, kein Flash
        if let cached = ImageCacheService.shared.cachedImage(key: key) {
            uiImage = cached; loading = false; return
        }

        uiImage = nil
        loading = true

        // 2. Lokale heruntergeladene Cover-Datei (immer, online wie offline)
        if let localPath = LocalArtworkIndex.shared.localPath(for: id) {
            if let img = await Task.detached(priority: .medium) {
                UIImage(contentsOfFile: localPath)
            }.value {
                ImageCacheService.shared.cache(img, key: key)
                uiImage = img; loading = false; return
            }
        }

        // 3. Offline: Disk-Cache (normale ImageCacheService-Dateien)
        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") {
            uiImage = await ImageCacheService.shared.diskOnlyImage(key: key)
            loading = false
            return
        }

        // 4. Online: Netzwerk mit bis zu 3 Versuchen
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(Int64(500 * attempt)))
            }
            guard !Task.isCancelled else { return }
            let image = await ImageCacheService.shared.image(url: url, key: key)
            guard !Task.isCancelled else { return }
            if let image { uiImage = image; loading = false; return }
        }
        loading = false
    }
```

- [ ] **Step 2: Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

---

## Task 8: CoverArtView (Mac) — Local-First Load + Offline-Artist-Fix

**Files:**
- Modify: `Shelv Desktop/Shelv Desktop/Helpers/ImageCache.swift` — `CoverArtView` + `ImageCacheService`
- Modify: `Shelv Desktop/Shelv Desktop/ViewModels/LibraryViewModel.swift:112-129`

- [ ] **Step 1: `CoverArtView.loadImage()` Mac — Local-First-Step**

Die `loadImage()`-Methode in `CoverArtView` ersetzen:

```swift
    private func loadImage() async {
        guard let url else { image = nil; return }

        // 1. Memory-Cache
        if let hit = ImageCacheService.shared.cachedImage(url: url) {
            image = hit; return
        }

        // 2. Lokale heruntergeladene Datei (online wie offline)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let artId = comps?.queryItems?.first(where: { $0.name == "id" })?.value,
           let localPath = LocalArtworkIndex.shared.localPath(for: artId) {
            if let img = await Task.detached(priority: .medium) {
                NSImage(contentsOfFile: localPath)
            }.value {
                ImageCacheService.shared.cache(img, url: url)
                image = img; return
            }
        }

        // 3. Offline: Disk-Cache / Online: Netzwerk
        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") {
            image = await ImageCacheService.shared.diskOnlyImage(url: url)
        } else {
            image = await ImageCacheService.shared.image(url: url)
        }
    }
```

- [ ] **Step 2: Mac LibraryViewModel.loadArtists() — Offline-Notification fixen**

In `Shelv Desktop/Shelv Desktop/ViewModels/LibraryViewModel.swift`, `loadArtists()`:

Den `guard !OfflineModeService.shared.isOffline else { isLoadingArtists = false; return }` ersetzen:

```swift
        guard !OfflineModeService.shared.isOffline else {
            let map = Dictionary(uniqueKeysWithValues: DownloadStore.shared.artists.compactMap { a -> (String, String)? in
                guard let cover = a.coverArtId else { return nil }
                return (a.name, cover)
            })
            if !map.isEmpty {
                NotificationCenter.default.post(name: .libraryArtistsLoaded, object: map)
            }
            isLoadingArtists = false
            return
        }
```

- [ ] **Step 3: Build-Check**

```bash
xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" \
  -scheme "Shelv Desktop" -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 4: Commit**

```bash
cd /Users/vasco/Repositorys/Shelv
git add Shelv/Services/ImageCacheService.swift Shelv/Views/Shared/AlbumArtView.swift
git commit -m "feat: local-first artwork loading in AlbumArtView (iOS)"

cd "/Users/vasco/Repositorys/Shelv Desktop"
git add "Shelv Desktop/Helpers/ImageCache.swift" "Shelv Desktop/ViewModels/LibraryViewModel.swift"
git commit -m "feat: local-first artwork loading in CoverArtView + offline artist cover fix (Mac)"
```

---

## Task 9: Per-Song-Cover in AlbumDetailView (iOS + Mac)

**Files:**
- Modify: `Shelv/Shelv/Views/Library/AlbumDetailView.swift` — Track-Rows
- Modify: `Shelv Desktop/Shelv Desktop/Views/AlbumDetailView.swift` — `TrackRow`

Nur in Compilation-Alben haben Songs abweichende `coverArt`-IDs. Die Cover werden nur angezeigt wenn `song.coverArt != album.coverArt` — in Standard-Alben bleibt die Zeile unverändert.

- [ ] **Step 1: iOS AlbumDetailView — Track-Row-Cover**

Die iOS `AlbumDetailView` hat Song-Rows wo `NowPlayingIndicator` + Titeldaten angezeigt werden. Suche nach der Section die Songs listet (enthält `song.title`) und ergänze vor dem Titeltext ein Cover:

```swift
// In der HStack der Song-Row, ganz links (vor NowPlayingIndicator):
if let songCover = song.coverArt, songCover != album.coverArt {
    AlbumArtView(coverArtId: songCover, size: 44, cornerRadius: 4)
        .frame(width: 44, height: 44)
}
```

Hinweis: Die genaue Position in der Datei findest du indem du nach `song.title` und dem HStack der Track-Liste suchst. Das Cover wird nur gerendert wenn Song und Album unterschiedliche IDs haben.

- [ ] **Step 2: iOS Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

- [ ] **Step 3: Mac `TrackRow` — Per-Song-Cover**

In `TrackRow` (`Shelv Desktop/Shelv Desktop/Views/AlbumDetailView.swift:233-300`), die `body` HStack. Das Album-`coverArt`-ID muss an `TrackRow` übergeben werden. `TrackRow` erhält ein neues optionales Feld:

```swift
struct TrackRow: View {
    let song: Song
    let isPlaying: Bool
    var albumCoverArt: String? = nil   // neu — Album-Cover für Compilation-Erkennung
    // ...bestehende Felder...
```

In der `body` HStack, nach dem Tracknummer-Block und vor `VStack(alignment: .leading`:

```swift
            if let songCover = song.coverArt, songCover != albumCoverArt {
                CoverArtView(
                    url: SubsonicAPIService.shared.coverArtURL(id: songCover, size: 80),
                    size: 36,
                    cornerRadius: 4
                )
                .padding(.leading, 10)
            }
```

Beim Aufruf von `TrackRow(...)` in `AlbumDetailView` das neue Feld übergeben:
```swift
TrackRow(song: song, isPlaying: ..., albumCoverArt: vm.album?.coverArt, ...)
```

- [ ] **Step 4: Mac Build-Check**

```bash
xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" \
  -scheme "Shelv Desktop" -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`.

- [ ] **Step 5: Commit**

```bash
cd /Users/vasco/Repositorys/Shelv
git add Shelv/Views/Library/AlbumDetailView.swift
git commit -m "feat: show per-song cover in compilation album tracks (iOS)"

cd "/Users/vasco/Repositorys/Shelv Desktop"
git add "Shelv Desktop/Views/AlbumDetailView.swift"
git commit -m "feat: show per-song cover in compilation album tracks (Mac)"
```

---

## Task 10: LibraryView (iOS) — @State-Vars entfernen

**Files:**
- Modify: `Shelv/Shelv/Views/LibraryView.swift`

- [ ] **Step 1: @ObservedObject hinzufügen, @State-Vars entfernen**

In `LibraryView`, die fünf `@State`-Zeilen (82-86) entfernen:
```swift
// LÖSCHEN:
@State private var downloadedAlbumIds: Set<String> = []
@State private var downloadedArtistNames: Set<String> = []
@State private var downloadedSongIds: Set<String> = []
@State private var downloadedAlbums: [DownloadedAlbum] = []
@State private var downloadedArtists: [DownloadedArtist] = []
```

Stattdessen einfügen (bei den anderen @ObservedObject-Deklarationen oder am Ende der Properties):
```swift
@ObservedObject private var downloadStore = DownloadStore.shared
```

- [ ] **Step 2: `refreshDownloadState()` entfernen + Aufrufe löschen**

Die Methode `refreshDownloadState()` (Zeilen 259-264) komplett löschen.

Die zwei Aufruf-Stellen entfernen:
- `.onChange(of: downloadStore.albums) { refreshDownloadState() }` — entfernen (`.onChange` ebenfalls, wenn keine anderen Handler drin sind)
- `.task { refreshDownloadState() }` — entfernen

- [ ] **Step 3: Berechnete Variablen auf downloadStore umstellen**

Die computed vars `displayedAlbums`, `displayedArtists`, `displayedStarredSongs`, `displayedStarredAlbums`, `displayedStarredArtists` referenzieren noch `downloadedAlbumIds`, `downloadedArtistNames` etc. Diese durch `downloadStore.*` ersetzen:

```swift
private var downloadedAlbumIds: Set<String> {
    Set(downloadStore.albums.map { $0.albumId })
}
private var downloadedArtistNames: Set<String> {
    Set(downloadStore.artists.map { $0.name })
}
private var downloadedSongIds: Set<String> {
    Set(downloadStore.songs.map { $0.songId })
}
```

Diese drei als private computed vars am Ende des Structs hinzufügen (statt @State). Alle anderen Stellen im View, die `downloadedAlbums` oder `downloadedArtists` direkt nutzen, auf `downloadStore.albums` bzw. `downloadStore.artists` umstellen.

- [ ] **Step 4: Build-Check**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`. Compiler zeigt alle noch fehlenden Ersetzungen als Fehler.

- [ ] **Step 5: Commit**

```bash
cd /Users/vasco/Repositorys/Shelv
git add Shelv/Views/LibraryView.swift
git commit -m "refactor: LibraryView uses DownloadStore directly instead of mirrored @State vars"
```

---

## Task 11: Final-Verifikation (iOS + Mac)

- [ ] **Step 1: Vollständiger Build beider Targets**

```bash
xcodebuild -project /Users/vasco/Repositorys/Shelv/Shelv.xcodeproj \
  -scheme Shelv -destination 'generic/platform=iOS Simulator' \
  build 2>&1 | grep -E "error:|warning:|Build succeeded"

xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" \
  -scheme "Shelv Desktop" -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|warning:|Build succeeded"
```

Expected: Keine `error:` Zeilen, `Build succeeded` für beide.

- [ ] **Step 2: Manuelle Checks**

Folgende Szenarien durchspielen:

**iOS – Online:**
- Song herunterladen → Cover erscheint sofort nach Download (kein Neustart nötig)
- Artist-Seite öffnen → Artist-Bild erscheint

**iOS – Offline-Start (App killen, Netz aus, App starten):**
- Downloads-Tab → Alben mit Cover sichtbar
- Artist-Row → Artist-Bild sichtbar
- Song antippen → Player zeigt korrektes Cover
- AlbumDetail → Track-Cover bei Compilations sichtbar

**Mac – Offline-Modus:**
- Offline-Modus aktivieren
- Alben → Cover sichtbar
- Artists → Artist-Bild sichtbar
- Albumdetail → Tracks korrekt
- Player → korrektes Cover, kein Stale aus letzter Session

- [ ] **Step 3: Abschließender Commit**

```bash
cd /Users/vasco/Repositorys/Shelv
git add -p  # nur verbleibende Änderungen
git commit -m "feat: complete local-first artwork system"
```

---

## Self-Review

**Spec-Coverage:**

| Anforderung | Task |
|-------------|------|
| Heruntergeladen → lokal | T7, T8 (Local-First-Step in load) |
| Artist-Image herunterladen | T4 (downloadAssetsIfNeeded) |
| `artistCoverArtId` in DB persistieren | T2 (Migration v2), T3 (Model), T4 (Record), T5 (reload) |
| Cold-Start offline Downloads anzeigen | T5 (reload() ruft LocalArtworkIndex.update auf) |
| Player-Cover offline | T7/T8 (Local-First vor diskOnly) |
| Artist-Cover offline | T4 + T5 (DB) + T7/T8 (Index-Lookup) |
| Per-Song-Cover in Compilations | T9 |
| LibraryView vereinfacht | T10 |
| Mac parity | T4/T5/T6/T8 (Mac-Varianten in jedem Task) |
| Mac offline Artist-Notification | T8 Step 2 |
| Builds funktionieren | T1 Step 4, T5 Step 5, T7 Step 2, T8 Step 3, T9 Step 4, T10 Step 4, T11 |

**Type-Consistency:**
- `LocalArtworkIndex.localPath(for: artId: String) -> String?` — verwendet in T7 (iOS) und T8 (Mac, als `localPath(for: artId)` wobei artId aus URL extrahiert wird)
- `DownloadService.artistCoverPath(serverId:artId:)` — static func, verwendet in T4 (DownloadService) und T5 (DownloadStore)
- `DownloadRecord.artistCoverArtId: String?` — deklariert T2, in toDownloadedSong T3, im DownloadJob T4, in DownloadStore T5
- `ImageCacheService.cache(_:key:)` iOS / `cache(_:url:)` Mac — deklariert T6, verwendet T7/T8

**Placeholder-Scan:** Keine TBDs, kein „fill in details". Alle Methodennamen und Typen sind konsistent über Tasks hinweg.
