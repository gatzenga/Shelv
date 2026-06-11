# macOS-Target-Migration & Code-Konsolidierung — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die separate macOS-App (`/Users/vasco/Repositorys/Shelv Desktop`) vollständig in das iOS-Projekt integrieren — erst 1:1 als zweites Target (Meilenstein 1), dann Backend-Code schrittweise in einen geteilten Ordner `ShelvCore/` konsolidieren (Meilensteine 2–3), sodass Logik nur noch einmal existiert und beide Frontends sie nutzen.

**Architecture:** Ein Xcode-Projekt, zwei App-Targets („Shelv" iOS, „Shelv Mac" macOS), drei FileSystemSynchronizedRootGroups: `Shelv/` (nur iOS-Target), `Shelv Mac/` (nur Mac-Target), `ShelvCore/` (beide Targets). Plattform-Unterschiede innerhalb geteilter Dateien via `#if os(iOS)` / `#if os(macOS)`. Bei Merges gewinnt grundsätzlich die iOS-Version als Basis (neuer, mehr Fixes), Mac-Extras werden hineinportiert.

**Tech Stack:** Swift 5 (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, APPROACHABLE_CONCURRENCY = YES in **beiden** Targets — identisch zum alten Desktop-Projekt, daher keine Concurrency-Überraschungen), SwiftUI, GRDB (gleiche Package-Referenz, bereits in beiden Targets verlinkt), CloudKit, AVFoundation.

---

## Faktenbasis (Stand der Recherche, alle Werte gemessen)

### Diff-Matrix gleichnamiger Dateien (Mac ↔ iOS, `diffzeilen` = Zeilen mit `<`/`>` aus `diff`)

| Datei | mac LOC | ios LOC | Diffzeilen | Einordnung |
|---|---|---|---|---|
| FileManager+Extensions | – | – | **0** | byte-identisch |
| LocalArtworkIndex | 29 | 29 | **0** | byte-identisch |
| NetworkStatus | 78 | 78 | **0** | byte-identisch |
| StreamCacheLog | 34 | 34 | **0** | byte-identisch |
| StreamCacheService | 142 | 142 | **0** | byte-identisch |
| DownloadStatusCache | 23 | 23 | **0** | byte-identisch |
| LocalDownloadIndex | 43 | 45 | 2 | trivial |
| OfflineModeService | 75 | 76 | 3 | trivial |
| DBErrorLog | 38 | 40 | 8 | trivial |
| TranscodingPolicy | 67 | 74 | 15 | klein |
| DownloadModels | – | – | 16 | klein |
| PlayTracker | 83 | 101 | 24 | klein |
| KeychainService | 48 | 50 | 34 | klein — iOS-Version ist besser (AfterFirstUnlock, delete-before-add); Key-Format `shelv_server_<UUID>` identisch ✓ |
| PlayerEngine | 334 | 369 | 47 | klein |
| RecapGenerator | 317 | 339 | 54 | klein |
| AppTheme | – | – | 61 | klein |
| RecapStore | 864 | 917 | 77 | mittel |
| LyricsStore | 164 | 171 | 97 | mittel |
| ServerStore | 162 | 126 | 98 | mittel — **Achtung Keys**, siehe unten |
| DemoContent | 281 | 319 | 110 | mittel |
| CloudKitSyncService | 854 | 894 | 120 | mittel |
| LyricsService | 388 | 403 | 127 | mittel |
| DownloadDatabase | 442 | 501 | 139 | mittel |
| PlayLogService | 581 | 678 | 177 | mittel |
| DownloadStore | 523 | 564 | 221 | mittel |
| DownloadService | 884 | 946 | 336 | groß |
| SubsonicAPIService | 534 | 858 | 1016 | groß — iOS deutlich umfangreicher (Error-Enum, mehr Endpoints) |
| AudioPlayerService | 1278 | 1350 | 1732 | sehr groß — eigene Phase |

### Kritische Befunde (müssen im Plan behandelt werden)

1. **ATS:** Die alte Mac-App hat `Shelv-Desktop-Info.plist` im Repo-Root mit `NSAllowsArbitraryLoads = true` (HTTP-Navidrome-Server!). Das neue Mac-Target hat noch **keine** Info.plist → ohne Fix gehen nur HTTPS-Server. iOS löst es identisch (`Info.plist` im Repo-Root).
2. **Song-Model divergiert:** Desktop-`Song` hat `artistId: String?`, `contentType: String?`, `starred: String?` (mutable) + `isStarred`/`durationString`; iOS-`Song` hat **kein** `artistId`/`contentType`, `starred: Date?`, eigene CodingKeys. Persistierte Daten der Mac-App (UserDefaults-Queue, GRDB) enthalten `starred` als String → Konsolidierung braucht Decode-Fallback.
3. **Mac-eigene UserDefaults-Keys:** `shelv_mac_servers`, `shelv_mac_active_server`, `shelv_mac_seen_servers`, Player-State `shelv_mac_*` (queue, currentIndex, …, volume, isPlayingFromPlayNext). iOS: `shelv_servers`, `shelv_player_*`. **Mac muss seine Keys behalten** (gleiche Bundle-ID → der Sandbox-Container der alten App wird von der neuen weiterverwendet; Bestandsdaten dürfen nicht verloren gehen).
4. **QueueItem (Mac) = `{ id: String(UUID), song: Song }`** — reiner SwiftUI-Identity-Wrapper, Queue-Logik dahinter identisch zur iOS-3-Array-Struktur.
5. **Desktop `SubsonicModels.swift` (363 LOC)** enthält neben API-Modellen auch UI-Enums (`SidebarItem`, `LibrarySortOption`, `ArtistSortOption`, `SortDirection`), `QueueItem`, `RepeatMode`, `ServerConfig` — beim Zerlegen bleiben UI-Enums Mac-only.
6. **Lokalisierung:** Beide Repos nutzen `String(localized:)` + `de.lproj`/`en.lproj/Localizable.strings` (keine `tr()`-Funktion). Desktop-Strings müssen mit ins Mac-Target.
7. **Assets:** Desktop-`Assets.xcassets` enthält **keinen** AccentColor, aber 23 `demo_*`-Imagesets (Demo-Content). Das neue `Shelv Mac/Assets.xcassets` hat AccentColor → Demo-Imagesets werden **dazukopiert**, AccentColor bleibt.
8. **App-Entry:** `Shelv_DesktopApp.swift` (`@main`, AppState.shared, 4 Zusatz-Fenster, Menü-Commands, eigene Notification-Definitionen) ersetzt die Xcode-Template-Dateien.
9. **Build-Nummer:** Mac-Target steht auf `CURRENT_PROJECT_VERSION = 81` (= letzter Stand der alten App). **Vor einem App-Store-Upload auf ≥ 82 erhöhen** (nicht Teil dieses Plans, Erinnerung an User).
10. **Deployment Target:** Neues Mac-Target = 15.6 (User-Entscheidung; alte App war 14.6 — macOS-14-Nutzer erhalten kein Update, App bleibt bei ihnen auf altem Stand. Vom User bewusst so gesetzt).
11. iOS-Repo hat zusätzlich `LyricsBackgroundService` (iOS-only Background-URLSession) und CarPlay (9 Dateien) — bleiben iOS-only, kommen nie nach ShelvCore.
12. Desktop-only Views/Helpers ohne iOS-Pendant: AppState, DiscoverViewModel, LibraryViewModel (≈ iOS LibraryStore), ImageCache (≈ iOS ImageCacheService), AlbumContextMenu/ArtistContextMenu/NowPlayingOverlay (gleichnamig, aber UI = plattformspezifisch) — bleiben in `Shelv Mac/`.

### Verifikations-Kommandos (nach **jedem** Task, „Build-Gate")

```bash
# Mac-Build
xcodebuild -project Shelv.xcodeproj -scheme "Shelv Mac" -destination "platform=macOS" build 2>&1 | tail -3
# iOS-Build
xcodebuild -project Shelv.xcodeproj -scheme "Shelv" -destination "generic/platform=iOS Simulator" build 2>&1 | tail -3
```
Erwartung: beide `** BUILD SUCCEEDED **`. Bei Fehlschlag: Task nicht committen, Fehler beheben oder Task zurückrollen (`git checkout -- <pfad>`).

Mac-Launch-Smoke-Test (nach M1 und nach jeder M3-Welle):
```bash
APP=$(xcodebuild -project Shelv.xcodeproj -scheme "Shelv Mac" -destination "platform=macOS" -showBuildSettings build 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{d=$3}/ FULL_PRODUCT_NAME/{n=$3" "$4}END{print d"/"n}')
open "$APP" && sleep 5 && pgrep -x "Shelv Mac" && echo "LÄUFT" ; osascript -e 'tell application "Shelv Mac" to quit' 2>/dev/null
```
Erwartung: PID + `LÄUFT`.

---

## Architektur-Entscheidungen (festgezurrt)

| # | Entscheidung | Begründung |
|---|---|---|
| E1 | Geteilter Code kommt in neuen Root-Ordner `ShelvCore/`, als dritte synchronized group **beiden** Targets zugeordnet | Sauberer als Membership-Exceptions; Xcode-16-Standardweg |
| E2 | Bei jedem Merge: **iOS-Version ist Basis**, Mac-Extras werden hineinportiert | iOS-Code ist neuer (z. B. Codec-Probing), hat besseres Error-Handling |
| E3 | Mac behält seine UserDefaults-Keys (`shelv_mac_*`) via plattformabhängiger Konstanten (`#if os(macOS)`) | Keine Daten-Migration nötig, Bestands-User verlieren nichts |
| E4 | Gemeinsames `Song` = iOS-Variante + `artistId` + `contentType` (beide optional), `starred: Date?` mit **custom Decoder, der ISO-String als Fallback parst** | Mac-persistierte Songs (starred=String) bleiben dekodierbar; iOS-Daten unverändert |
| E5 | `QueueItem` wird abgeschafft, Mac-Queue wird `[Song]` (erst in Phase W6/AudioPlayer) — gespeicherte Mac-Queue wird mit Decode-Fallback `[QueueItem] → map(\.song)` migriert | Unnötige Divergenz beseitigen, ohne State-Verlust |
| E6 | Views/ViewModels der UI bleiben dauerhaft plattformspezifisch (`Shelv/Views`, `Shelv Mac/Views`); gleichnamige UI-Dateien (DiscoverView etc.) sind **kein** Konflikt, da nie im selben Target | UI ist gewollt unterschiedlich |
| E7 | Pro konsolidierter Datei: ein Commit, beide Builds grün — jeder Zwischenstand ist shippable | Jederzeit abbrechbar/bisectbar |
| E8 | `ImageCache` (Mac, NSImage) und `ImageCacheService` (iOS, UIImage) werden in diesem Plan **nicht** zusammengelegt (PlatformImage-Refactor = eigenes Projekt) | Risiko/Nutzen; UI-nah, wenig Drift-Schmerz |
| E9 | `SubsonicAPIService`: iOS-Version wird geteilt; fehlende Mac-Endpoints (falls vorhanden) werden ergänzt; Mac-Aufrufer auf iOS-API umgestellt (`SubsonicAPIError` etc.) | iOS-Version ist Obermenge (858 vs. 534 LOC) |
| E10 | `LibraryStore` (iOS) und `LibraryViewModel`/`AppState`/`DiscoverViewModel` (Mac) bleiben getrennt | Store-Schicht ist UI-nah orchestrierend; Konsolidierung optional später |

### Standard-Merge-Prozedur „K" (gilt für alle Tasks in M3, wird dort referenziert)

Für Datei `X.swift` (Mac-Pfad `Shelv Mac/<dir>/X.swift`, iOS-Pfad `Shelv/<dir>/X.swift`):

1. `diff "Shelv Mac/<dir>/X.swift" "Shelv/<dir>/X.swift"` vollständig lesen.
2. Jede Diff-Hunk klassifizieren: (a) iOS-only Feature/Fix → bleibt (iOS ist Basis), (b) Mac-only Feature → mit `#if os(macOS)` übernehmen, (c) reine Drift (Naming/Whitespace/Reihenfolge) → iOS-Form,
   (d) iOS-only API (UIKit, UIApplication, MediaPlayer, BackgroundTask, CarPlay) → mit `#if os(iOS)` guarden.
3. `git mv Shelv/<dir>/X.swift ShelvCore/<dir>/X.swift`, dann Mac-Extras/Guards einarbeiten.
4. `rm "Shelv Mac/<dir>/X.swift"` (Mac-Kopie löschen — sonst doppelte Symbole im Mac-Target).
5. Beide Build-Gates ausführen (siehe oben). Compile-Fehler in Mac-Views, die alte Mac-Symbolnamen nutzen, direkt in den Views fixen (Aufrufer folgen der geteilten API).
6. Commit: `git add -A && git commit -m "refactor: share X between iOS and macOS targets"`.

---

# MEILENSTEIN 1 — Mac-App 1:1 ins Projekt (kein Code-Sharing, null Verhaltensänderung)

Ergebnis: Beide Apps bauen aus einem Projekt; die Mac-App ist funktional identisch zur alten (gleiche Bundle-ID → erbt UserDefaults, Keychain, GRDB-Datenbanken, Caches des bestehenden Sandbox-Containers).

### Task 1: Arbeits-Branch anlegen

**Files:** keine

- [ ] **Step 1:** `git -C /Users/vasco/Repositorys/Shelv checkout -b feature/macos-target-merge`
- [ ] **Step 2:** `git status --short` → leer (sauberer Stand, alles committet).

### Task 2: Desktop-Quellcode nach `Shelv Mac/` kopieren

**Files:**
- Delete: `Shelv Mac/ContentView.swift`, `Shelv Mac/Shelv_MacApp.swift` (Xcode-Templates)
- Create: alle Desktop-Quellen unter `Shelv Mac/` (75 Swift-Dateien + Ressourcen)

- [ ] **Step 1: Template-Dateien löschen** (beide enthalten Platzhalter; `Shelv_MacApp.swift` enthält `@main`, das mit dem Desktop-`@main` kollidieren würde):

```bash
cd /Users/vasco/Repositorys/Shelv
rm "Shelv Mac/ContentView.swift" "Shelv Mac/Shelv_MacApp.swift"
```

- [ ] **Step 2: Quellcode kopieren** (Ordnerstruktur des Desktop-Repos beibehalten):

```bash
D="/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop"
cp -R "$D/Helpers" "$D/Models" "$D/Services" "$D/ViewModels" "$D/Views" "Shelv Mac/"
cp "$D/ContentView.swift" "$D/Shelv_DesktopApp.swift" "Shelv Mac/"
```

- [ ] **Step 3: Lokalisierung kopieren:**

```bash
cp -R "$D/de.lproj" "$D/en.lproj" "Shelv Mac/"
```

- [ ] **Step 4: Demo-Assets in den bestehenden Katalog mergen** (AccentColor bleibt erhalten):

```bash
cp -R "$D/Assets.xcassets/"demo_*.imageset "Shelv Mac/Assets.xcassets/"
```

- [ ] **Step 5: Vollständigkeit prüfen:**

```bash
diff <(cd "$D" && find . -name "*.swift" | sort | sed 's|Shelv_DesktopApp|Shelv_DesktopApp|') \
     <(cd "Shelv Mac" && find . -name "*.swift" | sort) ; echo "Exit: $?"
```
Erwartung: Exit 0 (identische Swift-Dateilisten).

### Task 3: Info.plist mit ATS-Ausnahme fürs Mac-Target

**Files:**
- Create: `Shelv-Mac-Info.plist` (Repo-Root — bewusst **außerhalb** des synchronized folders, sonst „Multiple commands produce Info.plist"; identisches Muster wie iOS-`Info.plist` im Root)
- Modify: `Shelv.xcodeproj/project.pbxproj` (beide „Shelv Mac"-Konfigurationen)

- [ ] **Step 1: Datei anlegen** (Inhalt = exakt die alte `Shelv-Desktop-Info.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
</dict>
</plist>
```

- [ ] **Step 2: In pbxproj verknüpfen.** In **beiden** XCBuildConfigurations des Mac-Targets (`BC7B83FD…` Debug und `BC7B83FE…` Release) nach `GENERATE_INFOPLIST_FILE = YES;` einfügen:

```
				INFOPLIST_FILE = "Shelv-Mac-Info.plist";
```
(Edit-Anker: der String `GENERATE_INFOPLIST_FILE = YES;\n				INFOPLIST_KEY_LSApplicationCategoryType` kommt exakt 2× vor — beide ersetzen, replace_all.)

### Task 4: Build-Gate + bekannte Stolpersteine

- [ ] **Step 1:** Mac-Build-Gate ausführen. Erwartete mögliche Fehlerklassen und ihre Fixes:
  - *„Multiple commands produce …"* bei Localizable.strings → tritt nur auf, wenn `.lproj` doppelt vorhanden; prüfen mit `find "Shelv Mac" -name "*.lproj"` (genau 2 erwartet).
  - *`@main` doppelt* → Template-Datei nicht gelöscht (Task 2 Step 1 prüfen).
  - *GitHub-Link/Strings fehlen* → `String(localized:)`-Keys brauchen die kopierten `Localizable.strings` (Task 2 Step 3 prüfen).
- [ ] **Step 2:** iOS-Build-Gate ausführen (muss unverändert grün sein — iOS-Target kompiliert `Shelv Mac/` nicht).
- [ ] **Step 3:** Mac-Launch-Smoke-Test (Kommando siehe oben). Erwartung: App startet, Prozess läuft. Da die Bundle-ID identisch zur installierten alten App ist, startet sie mit den **echten Bestandsdaten** des Users — Login-Status und Server müssen sichtbar sein (Log-Ausgabe `[ServerID] Active server stableId:` im Konsolen-Log ist der Beleg, via `log stream --predicate 'process == "Shelv Mac"' --timeout 8s` parallel zum Start prüfbar).

### Task 5: Commit M1

- [ ] **Step 1:**
```bash
git add -A && git commit -m "feat: migrate desktop app sources into Shelv Mac target

1:1 copy of the Shelv Desktop repo sources (75 Swift files, localization,
demo assets) plus ATS-enabled Info.plist. No code sharing yet - the Mac
app behaves exactly like the standalone repo version."
```
- [ ] **Step 2:** `git status --short` → leer.

---

# MEILENSTEIN 2 — `ShelvCore/` einführen + byte-identische Dateien teilen

Ergebnis: Geteilter Ordner existiert, 6 risikofreie Dateien sind konsolidiert, der Mechanismus ist bewiesen.

### Task 6: `ShelvCore/` als dritte synchronized group anlegen

**Files:**
- Create: `ShelvCore/Services/` (Ordner)
- Modify: `Shelv.xcodeproj/project.pbxproj`

- [ ] **Step 1: Erste Datei verschieben** (Ordner darf nicht leer sein): byte-identische `NetworkStatus.swift`:

```bash
mkdir -p ShelvCore/Services
git mv Shelv/Services/NetworkStatus.swift ShelvCore/Services/NetworkStatus.swift
rm "Shelv Mac/Services/NetworkStatus.swift"
```

- [ ] **Step 2: pbxproj erweitern.** Drei Edits (UUID `BCC0DE00...` ist frei wählbar, muss nur eindeutig sein — `BCC0DE0000000000000000C0` verwenden):

(a) Im `PBXFileSystemSynchronizedRootGroup section` ergänzen:
```
		BCC0DE0000000000000000C0 /* ShelvCore */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = ShelvCore;
			sourceTree = "<group>";
		};
```
(b) In der mainGroup-children-Liste (`BC9C592F…`) nach dem `Shelv Mac`-Eintrag:
```
				BCC0DE0000000000000000C0 /* ShelvCore */,
```
(c) In **beiden** PBXNativeTargets die `fileSystemSynchronizedGroups`-Liste erweitern:
```
			fileSystemSynchronizedGroups = (
				BC9C593A2F8E9FB000FF4D25 /* Shelv */,
				BCC0DE0000000000000000C0 /* ShelvCore */,
			);
```
bzw. beim Mac-Target analog mit `BC7B83F62FDB17700058CB78 /* Shelv Mac */`.

- [ ] **Step 3:** Beide Build-Gates → grün (beweist: beide Targets kompilieren ShelvCore).
- [ ] **Step 4:** Commit `refactor: introduce ShelvCore shared folder, share NetworkStatus`.

### Task 7: Restliche byte-identische Dateien teilen

**Files:** je `git mv Shelv/... → ShelvCore/...` + `rm "Shelv Mac/..."`:

| iOS-Quelle | Mac-Kopie löschen |
|---|---|
| `Shelv/Services/StreamCacheLog.swift` | `Shelv Mac/Services/StreamCacheLog.swift` |
| `Shelv/Services/StreamCacheService.swift` | `Shelv Mac/Services/StreamCacheService.swift` |
| `Shelv/Services/LocalArtworkIndex.swift` | `Shelv Mac/Services/LocalArtworkIndex.swift` |
| `Shelv/ViewModels/DownloadStatusCache.swift` → `ShelvCore/Stores/` | `Shelv Mac/ViewModels/DownloadStatusCache.swift` |
| `Shelv/App/FileManager+Extensions.swift` → `ShelvCore/Support/` | `Shelv Mac/Helpers/FileManager+Extensions.swift` |

- [ ] **Step 1:** Vor jedem mv byte-Gleichheit verifizieren: `diff <macdatei> <iosdatei>` → leer. (Bei FileManager+Extensions bereits gemessen: 0.)
- [ ] **Step 2:** Alle 5 verschieben/löschen.
- [ ] **Step 3:** Beide Build-Gates → grün.
- [ ] **Step 4:** Commit `refactor: share byte-identical services between targets`.

---

# MEILENSTEIN 3 — Inhaltliche Konsolidierung (Welle für Welle, Prozedur K)

Jede Welle endet mit: beide Builds grün, Mac-Launch-Smoke-Test, ein Commit pro Datei. Reihenfolge ist abhängigkeitsgetrieben: erst model-freie Dateien, dann Models, dann model-abhängige Services, dann Stores, zuletzt der Player.

### Task 8 — Welle W1: Triviale & kleine model-freie Dateien (Prozedur K je Datei)

| Datei | Diffzeilen | Bekannte Unterschiede / Entscheidungen |
|---|---|---|
| `LocalDownloadIndex` | 2 | reine Drift → iOS-Form |
| `OfflineModeService` | 3 | reine Drift → iOS-Form |
| `DBErrorLog` | 8 | reine Drift → iOS-Form |
| `TranscodingPolicy` | 15 | iOS hat `nonisolated`-Fixes → iOS-Form |
| `KeychainService` | 34 | **iOS-Version gewinnt komplett** (kSecAttrAccessibleAfterFirstUnlock + delete-before-add ist der bessere/robustere Pfad; Mac-`@discardableResult`-Bool-Rückgabe entfällt — Mac-Aufrufer prüfen, die den Bool auswerten, und Aufrufe anpassen). Key-Format identisch → Bestands-Keychain-Einträge bleiben lesbar |
| `AppTheme` | 61 | iOS-Version als Basis; Mac-`themeColor`-Environment-Key (`\.themeColor`) muss erhalten bleiben (wird in `Shelv_DesktopApp` genutzt) — falls nur in der Mac-Version vorhanden, mit übernehmen (kein `#if` nötig, schadet iOS nicht) |

- [ ] Pro Datei: Prozedur K Schritte 1–6. Ziel-Pfade: Services → `ShelvCore/Services/`, AppTheme → `ShelvCore/Support/AppTheme.swift` (Mac-Kopie `Shelv Mac/Helpers/AppTheme.swift` löschen).
- [ ] Welle-Abschluss: Mac-Launch-Smoke-Test.

### Task 9 — Welle W2: Models konsolidieren (der Schlüssel-Task)

**Files:**
- Move: `Shelv/Models/{Song,Album,Artist,Playlist,SubsonicServer,DownloadModels}.swift` → `ShelvCore/Models/`
- Modify: `ShelvCore/Models/Song.swift` (Felder ergänzen + Decode-Fallback), weitere Models analog
- Modify: `Shelv Mac/Models/SubsonicModels.swift` → wird zerlegt zu `Shelv Mac/Models/MacUIModels.swift`
- Modify: diverse `Shelv Mac/Views/*` (Anpassung an iOS-Model-API)

- [ ] **Step 1: iOS-Models nach ShelvCore verschieben** (`git mv`), noch ohne inhaltliche Änderung. iOS-Build-Gate → grün.
- [ ] **Step 2: `Song` erweitern** — Desktop-Felder ergänzen und `starred` robust dekodieren. Ziel-Definition (Kern):

```swift
struct Song: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let artistId: String?        // NEU: war bisher nur Desktop — iOS dekodiert ab jetzt mit (optional, abwärtskompatibel)
    let album: String?
    let albumId: String?
    let track: Int?
    let discNumber: Int?
    let duration: Int?
    let coverArt: String?
    let year: Int?
    let genre: String?
    let playCount: Int?
    var starred: Date?
    let contentType: String?     // NEU: war bisher nur Desktop
    let suffix: String?
    let bitRate: Int?
    let replayGain: ReplayGain?

    var isStarred: Bool { starred != nil }          // Desktop-Convenience erhalten

    var durationFormatted: String {
        guard let d = duration else { return "" }
        return String(format: "%d:%02d", d / 60, d % 60)
    }
    var durationString: String {                     // Desktop-Name als Alias (Mac-Views nutzen ihn)
        duration == nil ? "--:--" : durationFormatted
    }
    var displayTrack: String { track.map(String.init) ?? "" }
}
```
**Decode-Fallback für `starred`** (Mac-Bestandsdaten enthalten ISO-Strings): custom `init(from:)`, das zuerst `Date`, dann `String` (ISO8601 mit/ohne Fractional Seconds) versucht. Vorher prüfen, wie der iOS-`SubsonicAPIService` Dates dekodiert (dateDecodingStrategy), und exakt dieselbe Strategie im Fallback verwenden — der Fallback betrifft primär `JSONDecoder()`-Default-Aufrufe beim State-Restore.
- [ ] **Step 3: `SubsonicModels.swift` zerlegen.** Aus der Mac-Datei alles löschen, was jetzt aus ShelvCore kommt (ServerConfig? prüfen ob iOS ein Pendant hat — wenn nein, nach ShelvCore übernehmen; SubsonicResponse/Body, Artist*, Album*, ReplayGain, Song, Playlist*, Search/Starred-Results). Übrig bleibt `Shelv Mac/Models/MacUIModels.swift` mit: `SidebarItem`, `LibrarySortOption`, `ArtistSortOption`, `SortDirection`, `QueueItem`, `RepeatMode` (Mac-Variante; bleibt bis W6 bestehen).
- [ ] **Step 4: Mac-Build-Gate.** Erwartete Fehlerklassen in Mac-Views/Services und ihre Fixes:
  - `starred` war `String?` → Vergleiche/Zuweisungen auf `Date?` umstellen (`song.starred = Date()` statt ISO-String, `isStarred` bleibt).
  - Response-Wrapper-Namen unterscheiden sich evtl. (`Starred2Result` vs. iOS-`StarredResult`) → Mac-Aufrufer auf iOS-Namen umstellen.
- [ ] **Step 5:** iOS-Build-Gate → grün. **Persistenz-Check iOS:** `git grep -n "JSONDecoder\|JSONEncoder" Shelv/Services/AudioPlayerService.swift Shelv/ViewModels/` — sicherstellen, dass das neue optionale Feld `artistId`/`contentType` ältere iOS-States weiterhin dekodiert (optionale Felder: ja).
- [ ] **Step 6:** Mac-Launch-Smoke-Test (besonders: gespeicherte Queue der alten App wird noch geladen — Konsole auf Decode-Fehler prüfen).
- [ ] **Step 7:** Commit `refactor: unify Song/Album/Artist models in ShelvCore with legacy decode fallback`.

### Task 10 — Welle W3: Model-abhängige Services (Prozedur K je Datei)

Reihenfolge (aufsteigende Diffgröße):

| Datei | Diffzeilen | Bekannte Unterschiede / Entscheidungen |
|---|---|---|
| `PlayTracker` | 24 | iOS-Basis |
| `RecapGenerator` | 54 | iOS-Basis |
| `DemoContent` | 110 | iOS-Basis; beide Targets haben eigene `demo_*`-Assets → Asset-Namen vor Merge abgleichen (`grep -o 'demo_[a-z_]*' …`) |
| `CloudKitSyncService` | 120 | iOS-Basis (Wipe-on-Enable etc. laut CLAUDE.md ist iOS-Stand) |
| `LyricsService` | 127 | iOS-Basis; iOS-only `LyricsBackgroundService`-Anbindung ggf. `#if os(iOS)` |
| `DownloadDatabase` | 139 | iOS-Basis; GRDB-Schema **muss identisch bleiben** (beide Apps haben produktive DBs!) — Diff explizit auf `create table`/Migrationen prüfen; bei Schema-Differenz: Migrations-Schritt statt Schema-Tausch |
| `PlayLogService` | 177 | iOS-Basis; gleiches GRDB-Schema-Gebot (play_log, recap_registry, scrobble_queue) |
| `DownloadService` | 336 | iOS-Basis; Background-URLSession-Konfiguration iOS-spezifisch → `#if os(iOS)` um `URLSessionConfiguration.background`-Pfad, macOS nutzt den Pfad der bisherigen Mac-Version (Diff zeigt, wie der Mac die Session konfiguriert) |
| `SubsonicAPIService` | 1016 | **E9:** iOS-Version wird geteilt. Vorgehen abweichend von K: (1) Mac-only Endpoints identifizieren: `grep -o "func [a-zA-Z]*(" beider Dateien | sort | diff` — fehlende Funktionen in die iOS-Version übernehmen (z. B. `authLogin`/`setConfig`/`ServerConfig`-Pfad, den `Shelv_DesktopApp` nutzt). (2) Datei nach ShelvCore, Mac-Kopie löschen. (3) Mac-Aufrufer auf iOS-API umstellen (Fehlertyp `SubsonicAPIError`, `getStarred2`-Wrapper-Namen) |

- [ ] Pro Datei: Prozedur K + die genannten Sonderpunkte. Nach `DownloadDatabase`/`PlayLogService`/`DownloadService` zusätzlich Mac-Launch-Smoke-Test (produktive DBs!).

### Task 11 — Welle W4: Stores (Prozedur K je Datei)

| Datei | Diffzeilen | Bekannte Unterschiede / Entscheidungen |
|---|---|---|
| `RecapStore` | 77 | iOS-Basis |
| `LyricsStore` | 97 | iOS-Basis |
| `DownloadStore` | 221 | iOS-Basis; `shelv_offline_playlists_<serverId>`-Key in beiden prüfen |
| `ServerStore` | 98 | iOS-Basis, **aber E3:** Keys plattformabhängig machen: |

```swift
#if os(macOS)
private let saveKey   = "shelv_mac_servers"
private let activeKey = "shelv_mac_active_server"
private let seenKey   = "shelv_mac_seen_servers"
#else
private let saveKey   = "shelv_servers"
private let activeKey = "shelv_active_server"
private let seenKey   = "shelv_seen_servers"
#endif
```
Zusätzlich prüfen: Mac-`ServerStore` hat 36 Zeilen mehr als iOS trotz iOS-Basis-Regel — Diff lesen; Mac-Extras (z. B. `remoteUserId`-Backfill-Helfer) mitnehmen, sie schaden iOS nicht oder werden geguardet. `SubsonicServer`-Struct ist seit W2 geteilt — Felder wie `remoteUserId` müssen dort schon abgeglichen sein (in W2 prüfen!).

- [ ] Pro Datei: Prozedur K. Ziel: `ShelvCore/Stores/`.
- [ ] Welle-Abschluss: Mac-Launch-Smoke-Test — **Kernprüfung: Server + Login der alten App sind noch da** (beweist Key-Erhalt).

### Task 12 — Welle W5: PlayerEngine teilen

**Files:**
- Move: `Shelv/Services/PlayerEngine.swift` → `ShelvCore/Services/PlayerEngine.swift`
- Delete: `Shelv Mac/Services/PlayerEngine.swift`

Bekannte Diffs (47 Zeilen): iOS hat `AudioToolbox`-Import + `currentAudioFormat(matching:)`/`codecLabel` (Codec-Probing, neu), `setVolume()`-Methode; Mac hat `var volume { didSet }` und `MainActor.assumeIsolated`-Notification-Pattern.

- [ ] **Step 1:** Prozedur K; dabei: iOS-Basis + Mac-`volume`-Property zusätzlich übernehmen (ohne `#if` — eine `volume`-Property schadet iOS nicht; `setVolume()` bleibt für ReplayGain). AudioToolbox/Codec-Probing ist plattformneutral → bleibt.
- [ ] **Step 2:** Mac-`AudioPlayerService` (noch unkonsolidiert!) gegen die geteilte Engine bauen — Aufrufer-Fixes direkt in `Shelv Mac/Services/AudioPlayerService.swift`.
- [ ] **Step 3:** Beide Build-Gates, Commit.

### Task 13 — Welle W6: AudioPlayerService konsolidieren (Finale, größtes Stück)

**Files:**
- Move: `Shelv/Services/AudioPlayerService.swift` → `ShelvCore/Services/AudioPlayerService.swift`
- Delete: `Shelv Mac/Services/AudioPlayerService.swift`
- Modify: alle Mac-Views, die `QueueItem`/Mac-Player-API nutzen (`grep -rln "QueueItem\|\.player\." "Shelv Mac/Views"`)
- Modify: `Shelv Mac/Models/MacUIModels.swift` (QueueItem + Mac-RepeatMode entfernen)

Vorab-Wissen (aus Analyse): Kern-Logik (3-Array-Queue, truth-Snapshots, Gapless-10s-Preload mit peekNextSong-Verifikation, Seek/pauseUntilBuffered, NWPathMonitor-Recovery) ist in beiden funktional identisch. Echte Plattform-Unterschiede: iOS = AVAudioSession + Interruption, MPRemoteCommands/NowPlaying, UIBackgroundTask, CarPlay-Flag, UIImage-Artwork; Mac = `volume`-Published, Mac-State-Keys, ggf. `loadURL`-Naming.

- [ ] **Step 1: iOS-Datei nach ShelvCore verschieben**, dann plattform-guarden:
  - `import UIKit` / AVAudioSession-Setup / `handleAudioInterruption` / `beginBackgroundTask` / `isCarPlayActive` + RemoteCommand-Extras → `#if os(iOS)`
  - NowPlaying-Artwork via UIImage → `#if os(iOS)` (Mac-NowPlaying übernimmt die bisherige Mac-Lösung, falls vorhanden — Diff prüfen; sonst auf Mac vorerst ohne Artwork im NowPlaying)
  - Mac-Extras rein: `@Published var volume` (mit `#if os(macOS)` oder plattformneutral — Entscheidung beim Diff-Lesen: neutral bevorzugt), Persistenz von `volume`.
- [ ] **Step 2: State-Keys plattformabhängig (E3):**

```swift
#if os(macOS)
private static let keyPrefix = "shelv_mac_"
#else
private static let keyPrefix = "shelv_player_"
#endif
```
Alle `shelv_player_*`-Literalstellen auf `keyPrefix + "queue"` etc. umstellen. **Achtung:** Mac-Altkeys heißen exakt `shelv_mac_queue`, `shelv_mac_currentIndex`, `shelv_mac_playNextQueue`, `shelv_mac_userQueue`, `shelv_mac_currentTime`, `shelv_mac_isShuffled`, `shelv_mac_repeatMode`, `shelv_mac_volume`, `shelv_mac_truthAlbum`, `shelv_mac_truthPlayNext`, `shelv_mac_truthUserQueue`, `shelv_mac_isPlayingFromPlayNext` — iOS-Suffixe weichen ab (`currentIndex` vs `currentIndex`? `resumeTime` vs `currentTime`!). Mapping-Tabelle beim Diff-Lesen erstellen; wo die Semantik abweicht (`resumeTime`/`currentTime`), Mac-Suffix per `#if` mappen.
- [ ] **Step 3: Queue-State-Decode-Fallback (E5):** Beim Restore zuerst `[Song]` versuchen, bei Fehlschlag `[QueueItem]` dekodieren und `map(\.song)`:

```swift
private struct LegacyQueueItem: Decodable { let id: String; let song: Song }
private func decodeSongs(_ data: Data) -> [Song]? {
    if let songs = try? JSONDecoder().decode([Song].self, from: data) { return songs }
    if let items = try? JSONDecoder().decode([LegacyQueueItem].self, from: data) { return items.map(\.song) }
    return nil
}
```
(`LegacyQueueItem` lebt privat im Service; `QueueItem` wird aus `MacUIModels.swift` gelöscht.)
- [ ] **Step 4: Mac-Views umstellen:** alle `item.song.…`-Zugriffe → direkt `song.…`; `ForEach(queue)`-IDs auf `enumerated()`-Pattern oder Song-ID umstellen (iOS-QueueView als Referenz, sie löst dasselbe Problem bereits).
- [ ] **Step 5: Scrobble-Abgleich:** Diff zeigt Mac-`scrobbleIfNeeded()`; prüfen, was iOS äquivalent macht (CLAUDE.md: `scrobble_queue` via PlayLogService). Funktional gleiche Stelle wählen, kein doppeltes Scrobbling.
- [ ] **Step 6:** Beide Build-Gates. Mac-Launch-Smoke-Test inkl. Konsole: gespeicherte Queue der alten App erscheint (Decode-Fallback greift), Wiedergabe-Start eines Songs via UI durch User verifizieren lassen (einziger nicht automatisierbarer Schritt).
- [ ] **Step 7:** Commit `refactor: unify AudioPlayerService across platforms with state-key compatibility`.

### Task 14: Abschluss-Verifikation & Aufräumen

- [ ] **Step 1: Vollständigkeits-Inventar:** `find "Shelv Mac/Services" "Shelv Mac/Models" -name "*.swift"` — erwartet bleiben nur plattformspezifische Dateien (ImageCache [E8], MacUIModels mit UI-Enums). Jede verbliebene Doppelung begründen oder konsolidieren.
- [ ] **Step 2:** Beide Build-Gates + Mac-Launch-Smoke-Test + iOS-Simulator-Launch (`xcrun simctl` boot + install + launch, Prozess-Check).
- [ ] **Step 3: CLAUDE.md aktualisieren:** Abschnitt „Architektur" um ShelvCore-Struktur, Mac-Target, E1–E10-Entscheidungen (kompakt) ergänzen.
- [ ] **Step 4:** Commit `docs: document ShelvCore shared architecture`.
- [ ] **Step 5: Übergabe an User — manueller Smoke-Test beider Apps** (Checkliste):
  - Mac: Login/Server da, Wiedergabe, Queue, Gapless, Downloads, Lyrics, Recap-Liste, iCloud-Sync-Status, Settings-Fenster, Menü-Shortcuts (Space, ⌘→)
  - iOS: Wiedergabe, Queue, Downloads, CarPlay (falls verfügbar), Lock-Screen-Controls
  - Erst danach: Merge auf main + Push. **Erinnerung:** Mac-Build-Nummer vor App-Store-Upload auf ≥ 82.

---

## Risiken & Abbruchpunkte

| Risiko | Absicherung |
|---|---|
| Mac-Bestandsdaten (Server, Queue, DBs) gehen verloren | E3/E4/E5: Keys behalten, Decode-Fallbacks, GRDB-Schema unangetastet; Launch-Tests laufen gegen den echten Container des Users |
| Merge-Fehler in großen Dateien (API/Player) | iOS-Basis-Regel + ein Commit pro Datei + Build-Gates → jeder Stand bisectbar; Task 13 ist der einzige „große" Merge und kommt zuletzt |
| iOS-Regression durch geteilte Dateien | iOS-Build-Gate nach jedem Schritt; geteilte Dateien starten als exakte iOS-Version |
| Xcode-Projektdatei-Korruption (Task 6 Hand-Edit) | Minimal-invasive Edits nach bestehendem Muster; Build-Gate direkt danach; git checkout als Rollback |
| Zeitbedarf Task 13 explodiert | Plan ist nach jeder Welle shippable — notfalls Task 13 als Folgesession, alles davor ist bereits voller Gewinn |

## Selbst-Review (durchgeführt)

- Spec-Abdeckung: 1:1-Migration ✓ (M1), geteilter Backend-Code ✓ (M2/M3 decken alle 20 gemeinsamen Services + Models + Stores ab), UI getrennt ✓ (E6), Mac funktioniert weiter wie bisher ✓ (E3/E4/E5 + Smoke-Tests), CarPlay/Background unangetastet ✓ (bleiben in `Shelv/`).
- Bewusst ausgeklammert (dokumentiert): ImageCache-Vereinheitlichung (E8), LibraryStore/LibraryViewModel-Merge (E10), Deployment-Target-Entscheidung (Befund 10), Build-Nummern-Bump (Befund 9).
- Typ-Konsistenz: `Song`-Definition aus Task 9 wird in Task 13 (`LegacyQueueItem.song`) wiederverwendet; `keyPrefix`-Pattern konsistent mit E3.
