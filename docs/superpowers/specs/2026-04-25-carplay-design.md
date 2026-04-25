# CarPlay Integration — Design Spec
**Datum:** 2026-04-25  
**Scope:** Vollständige CarPlay-Unterstützung für Shelv (Navidrome iOS-Client)  
**iOS-Minimum:** 18.0  
**Entitlement:** `com.apple.developer.carplay-audio` bereits vorhanden

---

## 1. Ziele & Nicht-Ziele

### Ziele
- Native CarPlay-UI mit CPTemplates (vollständiges Framework)
- Stabile, flüssige Wiedergabe — identische Queue- und Playback-Logik wie iPhone
- Scrobbling, PlayTracker, CloudKit-Sync laufen unverändert weiter
- Discover, Library (Alben/Künstler/Favoriten), Playlists (inkl. Recap), Suche
- Online- und Offline-Modus vollständig unterstützt
- Cover Art mit ausreichender Auflösung (300 px, ImageCacheService)
- Favoriten-Button wenn iPhone-seitig aktiviert
- 4 Aktions-Buttons (Play, Shuffle, Play Next, Add to Queue) auf Album-/Künstler-/Playlist-Ebene

### Nicht-Ziele
- Settings in CarPlay (komplett ausgeblendet)
- Download/Löschen in CarPlay
- Playlist erstellen/löschen in CarPlay
- "Zu Playlist hinzufügen" in CarPlay
- Sort-Controls in CarPlay (spiegelt iPhone-Einstellung)
- Lyrics-Anzeige in CarPlay (Lyrics nur als Suchtreffer, kein Player-Overlay)
- Per-Song Queue-Aktionen (nur auf Sammlungsebene)

---

## 2. Infrastruktur

### 2.1 Info.plist — Scene-Konfiguration

Die App nutzt SwiftUI App lifecycle (`@main struct ShelvApp: App`) — kein expliziter UIWindowSceneDelegate. Die Info.plist bekommt ein Scene-Manifest mit `UIApplicationSupportsMultipleScenes = true` und der neuen CarPlay-Scene. Die Phone-Scene braucht keinen Delegate-Klassennamen (SwiftUI verwaltet diese intern).

```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <true/>
    <key>UISceneConfigurations</key>
    <dict>
        <!-- Phone-Scene: SwiftUI verwaltet sie, kein Delegate-Klassenname nötig -->
        <key>UIWindowSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>Default Configuration</string>
            </dict>
        </array>
        <!-- Neue CarPlay-Scene -->
        <key>CPTemplateApplicationSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>CarPlay Configuration</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
            </dict>
        </array>
    </dict>
</dict>
```

### 2.2 Entitlements
- `com.apple.developer.carplay-audio` → bereits vorhanden ✅
- `UIBackgroundModes: audio` → bereits vorhanden ✅

### 2.3 Neue Dateien

Alle unter `Shelv/CarPlay/`:

```
CarPlay/
├── CarPlaySceneDelegate.swift       — CPTemplateApplicationSceneDelegate
├── CarPlayRootController.swift      — verwaltet CPTabBarTemplate + Lifecycle
├── CarPlayDiscoverController.swift  — Discover-Tab
├── CarPlayLibraryController.swift   — Library-Tab (Alben/Künstler/Favoriten)
├── CarPlayPlaylistsController.swift — Playlists-Tab (inkl. Recap)
└── CarPlaySearchController.swift    — Search-Tab (CPSearchTemplate)
```

---

## 3. Template-Hierarchie

```
CPTabBarTemplate (4 Tabs)
│
├── [0] Discover  ─── CPListTemplate
│       Sections:
│         • Mixes [3 Aktions-Rows: Newest / Frequent / Recent]  → sofort play
│         • Recently Added [Album-Rows mit Cover]                → push Album Detail
│         • Recently Played [Album-Rows]                         → push Album Detail
│         • Frequently Played [Album-Rows]                       → push Album Detail
│         • Random [Row "Zufällig aktualisieren" + Album-Rows]   → Refresh-Row startet neuen Random-Load, Album-Rows pushen Album Detail
│       Offline: eine Section mit Meldung + "Online gehen" Row
│
├── [1] Library   ─── CPListTemplate (Menü-Ebene)
│       Rows: Alben / Künstler / Favoriten* (* wenn enableFavorites)
│       └── Alben → CPListTemplate (alphabetisch, nach iPhone-Sort-Einstellung)
│               └── Album Detail → CPListTemplate
│                     Section 1 (Aktionen): Play / Shuffle / Play Next / Add to Queue
│                                           + Favorit-Toggle* (* wenn enableFavorites)
│                     Section 2 (Songs): Song-Rows → tap = play ab dieser Position
│       └── Künstler → CPListTemplate
│               └── Künstler Detail → CPListTemplate
│                     Section 1 (Aktionen): Play All / Shuffle All / Play Next / Add to Queue
│                                           + Favorit-Toggle* (* wenn enableFavorites)
│                     Section 2 (Alben): Album-Rows → push Album Detail
│       └── Favoriten* → CPListTemplate (Songs + Alben gemischt, wie iPhone)
│
├── [2] Playlists ─── CPListTemplate
│       Alle Playlists inkl. Recap-Playlists (anders als iPhone — CarPlay zeigt Recap hier)
│       └── Playlist Detail → CPListTemplate
│             Section 1 (Aktionen): Play / Shuffle / Play Next / Add to Queue
│             Section 2 (Songs): Song-Rows → tap = play ab dieser Position
│
└── [3] Search    ─── CPSearchTemplate
        Ergebnisse: CPListTemplate (identische Logik wie iPhone)
          • Online: Songs, Alben, Künstler, Lyrics-als-Songs
          • Offline: nur heruntergeladene Inhalte
          Song-Tap → play sofort
          Album-Tap → push Album Detail
          Künstler-Tap → push Künstler Detail
```

---

## 4. Detail-Verhalten

### 4.1 Aktions-Buttons in Detail-Views

Jedes Album/Künstler/Playlist-Detail hat eine Actions-Section als erste Section:

| Row | Icon | Aktion |
|-----|------|--------|
| Play | `play.fill` | `player.play(songs: allSongs, startIndex: 0)` |
| Shuffle | `shuffle` | `player.playShuffled(songs: allSongs)` |
| Play Next | `text.insert` | `player.addPlayNext(allSongs)` |
| Add to Queue | `text.append` | `player.addToQueue(allSongs)` |
| Favorit ★ / ☆ | `heart.fill` / `heart` | `libraryStore.toggleStarAlbum/Artist(...)` (wenn enableFavorites) |

Favorit-Toggle: optimistisch wie auf iPhone + Rollback bei Fehler. Nur anzeigen wenn `@AppStorage("enableFavorites") == true`.

### 4.2 Song-Row-Tap in Detail-Views

Tippt der User auf einen Song in Album/Playlist-Detail → `player.play(songs: allSongs, startIndex: tappedIndex)`. Queue wird aus der gesamten Liste aufgebaut, Wiedergabe beginnt beim angetippten Song.

### 4.3 Mixes (Discover)

Tap auf Mix-Row:
1. Sofortiges Setzen von `isLoading = true` auf dem Template
2. `SubsonicAPIService.shared.getAlbumList(type:)` aufrufen
3. Songs sammeln
4. `AudioPlayerService.shared.play(songs:)` — identisch zum iPhone-Mix-Button
5. `isLoading = false`

Fehler: CPAlertTemplate mit Fehlermeldung, dann dismiss.

### 4.4 Cover Art

- Alle CPListItems erhalten einen Platzhalter-UIImage (`UIImage(systemName: "music.note")`) sofort
- Asynchroner Load via `ImageCacheService.shared` mit 300 px
- Nach Laden: `item.setImage(_:)` auf Main Thread + `template.updateSections(_:)` — minimale Mutation
- Keine UIImage-Loads blockieren den Haupt-Thread

### 4.5 Offline-Modus

**Discover (Offline):**
- Eine Section: "Du bist im Offline-Modus"
- Row "Online gehen" → `OfflineModeService.shared.exitOfflineMode()`
- Kein Server erreichbar (aber Offline-Modus inaktiv): Row "Zu Offline-Modus wechseln" → `enterOfflineMode()`

**Library (Offline):**
- Alben: nur `DownloadStore.shared.albums` (identisch zu iPhone)
- Künstler: nur `DownloadStore.shared.artists`
- Favoriten: nur starred Songs die auch in `DownloadStore.shared.songs` sind (heruntergeladen + starred)

**Playlists (Offline):**
- Nur Playlists in `DownloadStore.shared.offlinePlaylistIds`
- Recap-Playlists: anzeigen wenn ihre Songs heruntergeladen sind

**Suche (Offline):**
- Exakt gleiche Logik wie iPhone SearchView im Offline-Modus: nur Downloads durchsuchen

### 4.6 Sort-Reihenfolge

- Liest `@AppStorage("albumSortOption")` und `@AppStorage("albumSortDirection")` — keine eigenen Einstellungen
- Wenn sich der Wert auf dem iPhone ändert: beim nächsten Reload in CarPlay wird die neue Sortierung verwendet
- Artikel-Stripping (en/de/fr/es/it/pt/nl) vor Alphabetsortierung — identische Implementierung wie LibraryView

### 4.7 NowPlaying / Fernbedienung

- `MPNowPlayingInfoCenter` wird von `AudioPlayerService` bereits befüllt → CarPlay-NowPlaying-Screen funktioniert automatisch
- `MPRemoteCommandCenter` ist bereits verdrahtet → Skip, Previous, Play/Pause funktionieren über Lenkrad-Tasten
- Kein zusätzlicher Code nötig

### 4.8 Scrobbling & Recap

- `PlayTracker.shared` beobachtet `AudioPlayerService.shared` via Combine — läuft unverändert
- Plays werden in `PlayLogService` geschrieben — unverändert
- Pending Scrobbles im Offline-Modus: Scrobble-Queue wird beim nächsten Online-Moment geleert — unverändert
- Recap-Generation via `RecapGenerator` — unverändert
- CloudKit-Sync — unverändert

---

## 5. Stabilität & Fehlerbehandlung

- **Kein Force Unwrap** in CarPlay-Code. Alle optionalen Daten mit `guard` behandelt.
- **Main-Thread-Pflicht:** Alle CPTemplate-Updates laufen auf `@MainActor` / `DispatchQueue.main`
- **Task-Cancellation:** Jeder async Load pro Controller via `Task` mit `isCancelled`-Checks. Beim Verlassen eines Templates: Task canceln.
- **Loading States:** `CPListTemplate(title:layout:sections:)` mit `isLoading = true` während Daten geladen werden. Nie leere Templates ohne Indikator zeigen.
- **Leere States:** Wenn keine Daten: eine Section mit einer Row "Keine Inhalte verfügbar" — kein Crash auf leeres Array.
- **Netzwerkfehler:** Bei API-Fehlern in Discover/Library: CPAlertTemplate mit Fehlermeldung. Beim Dismiss zurück zum vorherigen Template.
- **Server-Wechsel:** `CarPlayRootController` hört auf `serverStore.activeServerID` via Combine → kompletten Tab-Stack neu aufbauen, Player stoppen.
- **CarPlay-Disconnect:** `templateApplicationScene(_:didDisconnect:)` → alle Tasks canceln, Referenzen freigeben.

---

## 6. Architektur-Prinzipien

- **Kein SwiftUI in CarPlay.** Ausschliesslich CPTemplates.
- **Keine duplizierten Services.** Alle Singletons direkt nutzen, kein eigener CarPlay-State.
- **Thin Controllers.** CarPlay-Controller sind reine Template-Builder und Event-Router. Business-Logik bleibt in Services/Stores.
- **Reaktiv via Combine.** Controller abonnieren Published-Properties der Stores (isOffline, currentSong etc.) und updaten Templates bei Änderungen.
- **Cover-Loads nie blockierend.** Immer mit Platzhalter starten, async aktualisieren.

---

## 7. Was sich am iPhone-Code ändert

**Nichts in der bestehenden UI.** Alle Änderungen sind additiv:
- `ShelvApp.swift`: keine Änderung nötig (Scene-Config in Info.plist, nicht im Swift-Code)
- `AudioPlayerService`, `LibraryStore`, alle Services: keine Änderungen
- Neue Dateien ausschliesslich unter `Shelv/CarPlay/`

Einzige Cross-Cutting-Änderung: `playNextQueue`-Methode auf `AudioPlayerService` falls sie noch nicht `public` ist (wird geprüft).
