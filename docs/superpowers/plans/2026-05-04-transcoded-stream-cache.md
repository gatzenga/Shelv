# Transcoded Stream Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transcodierte Audio-Streams werden zuerst vollständig in eine Temp-Datei geladen und dann lokal abgespielt, um AVPlayer-Range-Request-Inkompatibilität mit Live-Transcoding zu beheben.

**Architecture:** Neuer `StreamCacheService` (actor) lädt transcodierte Streams in `FileManager.temporaryDirectory`. `AudioPlayerService` prüft bei jedem Songstart, ob eine gecachte Datei vorhanden ist — wenn ja sofort abspielen, sonst Download + `isBuffering = true`. Prefetch startet 30s vor Songwechsel unabhängig vom Gapless-Modus. Watchdog und `fallbackToRawStream` werden entfernt. Gapless funktioniert automatisch wenn Prefetch rechtzeitig fertig ist.

**Tech Stack:** Swift, AVFoundation, URLSession (foreground), actor isolation

---

## File Map

### Neue Dateien
- `Shelv/Services/StreamCacheService.swift` — actor, Download-to-temp, Prefetch, Cancel, Cleanup
- `Shelv Desktop/Services/StreamCacheService.swift` — identisch, minimale Anpassungen für Desktop

### Geänderte Dateien — iOS (`Shelv/`)
- `Shelv/Services/AudioPlayerService.swift` — `resolveURL`, `startPlayback`, `seek`, `checkGaplessTrigger`, Watchdog entfernen, `probeStreamFormat` anpassen
- `Shelv/Views/Player/PlayerBarView.swift` — „Verbinde…" → „Lädt…"
- `Shelv/ShelvApp.swift` — Temp-Dateien beim App-Start bereinigen

### Geänderte Dateien — Desktop (`Shelv Desktop/`)
- `Shelv Desktop/Services/AudioPlayerService.swift` — `resolveURL`, `loadURL`, `seek`, `checkGaplessTrigger`, Watchdog entfernen, `probeStreamFormat` anpassen
- `Shelv Desktop/ShelvApp.swift` — Temp-Dateien beim App-Start bereinigen

---

## Task 1: StreamCacheService (iOS)

**Files:**
- Create: `Shelv/Services/StreamCacheService.swift`

### Konzept
- `prefetch(songId:url:codec:bitrate:)` — startet Download in Hintergrund-Task, max 3 Versuche
- `localURL(for songId:) -> URL?` — synchroner Check ob Datei fertig
- `cancel(songId:)` — laufenden Task canceln + Temp-Datei löschen
- `cancelAll()` — beim App-Start und Stop
- `cachedFormat(for songId:) -> ActualStreamFormat?` — bekanntes Format für Bitrate-Anzeige
- Retry-Auslöser: Netzwerk- oder Server-Fehler (nicht Timeout)

- [ ] **Step 1: StreamCacheService anlegen**

```swift
// Shelv/Services/StreamCacheService.swift
import Foundation

actor StreamCacheService {
    static let shared = StreamCacheService()
    private init() {}

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var cachedURLs: [String: URL] = [:]
    private var cachedFormats: [String: ActualStreamFormat] = [:]

    private static func tempURL(for songId: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shelv_stream_\(songId)")
    }

    func localURL(for songId: String) -> URL? {
        cachedURLs[songId]
    }

    func cachedFormat(for songId: String) -> ActualStreamFormat? {
        cachedFormats[songId]
    }

    func prefetch(songId: String, url: URL, codec: String, bitrate: Int) {
        guard activeTasks[songId] == nil, cachedURLs[songId] == nil else { return }
        let format = ActualStreamFormat(codecLabel: codec.uppercased(), bitrateKbps: bitrate)
        cachedFormats[songId] = format
        activeTasks[songId] = Task {
            await downloadWithRetry(songId: songId, url: url, maxAttempts: 3)
        }
    }

    func cancel(songId: String) {
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        cachedURLs.removeValue(forKey: songId)
        cachedFormats.removeValue(forKey: songId)
        try? FileManager.default.removeItem(at: Self.tempURL(for: songId))
    }

    func cancelAll() {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        cachedURLs.removeAll()
        cachedFormats.removeAll()
    }

    func cleanupOldFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("shelv_stream_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func downloadWithRetry(songId: String, url: URL, maxAttempts: Int) async {
        let dest = Self.tempURL(for: songId)
        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            do {
                let (tmpURL, response) = try await URLSession.shared.download(from: url)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: tmpURL)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    print("[StreamCache] Attempt \(attempt)/\(maxAttempts): bad status for \(songId)")
                    if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                    continue
                }
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                cachedURLs[songId] = dest
                activeTasks.removeValue(forKey: songId)
                print("[StreamCache] Cached \(songId)")
                return
            } catch {
                guard !Task.isCancelled else { return }
                print("[StreamCache] Attempt \(attempt)/\(maxAttempts) error: \(error.localizedDescription)")
                if attempt < maxAttempts { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        // Alle 3 Versuche fehlgeschlagen — kein Cache, normaler Pfad
        activeTasks.removeValue(forKey: songId)
        print("[StreamCache] All attempts failed for \(songId)")
    }
}
```

- [ ] **Step 2: Datei zur iOS Xcode-Gruppe hinzufügen**

In Xcode: `Shelv/Services/` Gruppe → Rechtsklick → „Add Files" → `StreamCacheService.swift`. Danach Build prüfen: `Cmd+B`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/vasco/Repositorys/Shelv add Shelv/Services/StreamCacheService.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "feat: add StreamCacheService for transcoded stream temp-caching"
```

---

## Task 2: AudioPlayerService iOS — resolveURL + startPlayback

**Files:**
- Modify: `Shelv/Services/AudioPlayerService.swift`

Ziel: transcodierte Streams werden nie direkt an AVPlayer übergeben. Stattdessen: `StreamCacheService` prüfen → wenn da, lokale URL; wenn nicht da, Download starten + warten.

- [ ] **Step 1: `resolveURL(for:)` um Cache-Check erweitern**

Aktuelle Methode (`Zeile ~480`):
```swift
private func resolveURL(for song: Song) -> URL? {
    let serverId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
    if !serverId.isEmpty,
       let local = LocalDownloadIndex.shared.url(songId: song.id, serverId: serverId) {
        return local
    }
    guard !OfflineModeService.shared.isOffline else { return nil }
    return SubsonicAPIService.shared.streamURL(for: song.id)
}
```

Ersetzen durch:
```swift
private func resolveURL(for song: Song) -> URL? {
    let serverId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
    if !serverId.isEmpty,
       let local = LocalDownloadIndex.shared.url(songId: song.id, serverId: serverId) {
        return local
    }
    guard !OfflineModeService.shared.isOffline else { return nil }
    // Gecachte Temp-Datei für transcodierte Streams
    if let cached = StreamCacheService.shared.localURL(for: song.id) {
        return cached
    }
    return SubsonicAPIService.shared.streamURL(for: song.id)
}
```

- [ ] **Step 2: Hilfsmethode `isTranscodedRemote(_:) -> Bool`**

Nach `resolveURL` einfügen:
```swift
private func isTranscodedRemote(_ url: URL) -> Bool {
    guard !url.isFileURL else { return false }
    return url.queryParam("format").map { $0 != "raw" } ?? false
}
```

- [ ] **Step 3: `startPlayback` anpassen**

Die aktuelle `startPlayback` (`Zeile ~490`) ruft nach `resolveURL` direkt `engine.play(url:)` auf. Wenn die URL transcodiert (remote) ist, muss zuerst der Download abgewartet werden.

Bestehenden Block ab `self.currentStreamURL = url` bis `self.engine.play(url: url)` ersetzen:

```swift
self.currentStreamURL = url
self.streamTimeOffset = 0
self.gaplessPreloadTriggered = false
self.gaplessPreloadSong = nil
self.gaplessPreloadURL = nil
self.formatProbeTask?.cancel()
self.actualStreamFormat = nil
self.currentSong = song
self.isBuffering = true
self.isSeeking = false
self.currentTime = 0
if let d = song.duration { self.duration = Double(d) }
self.timePublisher.send((time: 0, duration: self.duration))
self.isPlaying = true
if song.coverArt != self.lastArtworkCoverArt {
    self.artworkReloadToken = UUID()
    self.lastArtworkCoverArt = song.coverArt
}

// Transcodierter Remote-Stream → erst cachen, dann abspielen
if self.isTranscodedRemote(url), let fmt = TranscodingPolicy.currentStreamFormat() {
    let songId = song.id
    // Format sofort setzen (wir kennen es)
    self.actualStreamFormat = ActualStreamFormat(
        codecLabel: fmt.codec.rawValue.uppercased(),
        bitrateKbps: fmt.bitrate
    )
    // Cancel vorheriger Cache-Downloads anderer Songs
    // (aktueller Song wird in prefetch nicht doppelt gestartet)
    await StreamCacheService.shared.prefetch(
        songId: songId,
        url: url,
        codec: fmt.codec.rawValue,
        bitrate: fmt.bitrate
    )
    // Warten bis Datei da ist (polling alle 200ms, max 60s)
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        guard self.currentSong?.id == songId else { return } // Song wurde gewechselt
        if let local = await StreamCacheService.shared.localURL(for: songId) {
            self.currentStreamURL = local
            self.engine.play(url: local)
            self.engine.trustedDuration = Double(song.duration ?? 0)
            if seekTo > 0 { self.engine.seek(to: seekTo) }
            self.isEngineLoaded = true
            break
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
} else {
    // Raw-Stream oder lokale Datei → wie bisher
    self.probeStreamFormat(for: song, url: url)
    self.engine.play(url: url)
    self.engine.trustedDuration = Double(song.duration ?? 0)
    if seekTo > 0 { self.engine.seek(to: seekTo) }
    self.isEngineLoaded = true
}
```

- [ ] **Step 4: `startPlayback` — `schedulePlaybackWatchdog` Aufruf entfernen**

Zeile `self.schedulePlaybackWatchdog(for: song, url: url)` löschen — Watchdog wird in Task 4 komplett entfernt.

- [ ] **Step 5: Beim Song-Cancel vorherigen Cache aufräumen**

Am Anfang von `startPlayback`, direkt nach `self.networkResumeSong = nil`:
```swift
// Vorherigen transcodierten Cache-Download canceln
if let prev = self.currentSong {
    await StreamCacheService.shared.cancel(songId: prev.id)
}
```

- [ ] **Step 6: Build + manuell testen**

`Cmd+B`. Simulator starten, einen transcodierten Song abspielen. Erwartung: isBuffering bis Datei fertig, dann Wiedergabe.

- [ ] **Step 7: Commit**

```bash
git -C /Users/vasco/Repositorys/Shelv add Shelv/Services/AudioPlayerService.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "feat: route transcoded streams through StreamCacheService in startPlayback"
```

---

## Task 3: AudioPlayerService iOS — seek vereinfachen

**Files:**
- Modify: `Shelv/Services/AudioPlayerService.swift` (Zeilen 725–746)

Da transcodierte Streams jetzt als lokale Dateien abgespielt werden, ist kein URL-Seek mehr nötig — normaler AVPlayer-Seek genügt.

- [ ] **Step 1: transcoded-Branch in `seek(to:)` entfernen**

Aktueller Code (`~Zeile 725`):
```swift
func seek(to seconds: Double) {
    let isTranscodedStream = currentStreamURL.map {
        !$0.isFileURL && ($0.queryParam("format").map { $0 != "raw" } ?? false)
    } ?? false

    if isTranscodedStream, let song = currentSong {
        let offset = Int(seconds)
        guard let newURL = SubsonicAPIService.shared.streamURL(for: song.id, timeOffset: offset) else { return }
        currentStreamURL = newURL
        streamTimeOffset = Double(offset)
        currentTime = seconds
        lastReportedNowPlayingTime = -1
        updateNowPlayingTime(seconds)
        gaplessPreloadTriggered = false
        gaplessPreloadSong = nil
        gaplessPreloadURL = nil
        isBuffering = true
        schedulePlaybackWatchdog(for: song, url: newURL)
        if let d = song.duration { duration = Double(d) }
        engine.play(url: newURL)
        engine.trustedDuration = Double(song.duration ?? 0)
        isEngineLoaded = true
    } else {
        currentTime = seconds
        isSeeking = true
        // ... normaler Seek
    }
}
```

Ersetzen durch (nur der else-Branch bleibt, ohne das if):
```swift
func seek(to seconds: Double) {
    currentTime = seconds
    isSeeking = true
    lastReportedNowPlayingTime = -1
    updateNowPlayingTime(seconds)
    let buffered = engine.isPositionBuffered(seconds)
    let shouldPauseAndWait = !buffered && self.isPlaying
    if shouldPauseAndWait { isBuffering = true }
    engine.seek(to: seconds, pauseUntilBuffered: shouldPauseAndWait) { [weak self] _ in
        Task { @MainActor [weak self] in self?.isSeeking = false }
    }
}
```

- [ ] **Step 2: `streamTimeOffset` — alle Referenzen prüfen**

```bash
grep -n "streamTimeOffset" /Users/vasco/Repositorys/Shelv/Shelv/Services/AudioPlayerService.swift
```

`streamTimeOffset` wird noch in `onTrackFinished` und dem `$currentTime`-Sink genutzt. Da transcodierte Streams immer 0 haben, ist das korrekt — keine weitere Änderung nötig.

- [ ] **Step 3: Build prüfen**

`Cmd+B`. Kein Fehler erwartet.

- [ ] **Step 4: Commit**

```bash
git -C /Users/vasco/Repositorys/Shelv add Shelv/Services/AudioPlayerService.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "simplify: remove transcoded URL-seek, use normal AVPlayer seek"
```

---

## Task 4: AudioPlayerService iOS — Watchdog + Fallback entfernen

**Files:**
- Modify: `Shelv/Services/AudioPlayerService.swift`

`fallbackToRawStream` und `schedulePlaybackWatchdog` sind nicht mehr nötig. Der HEAD-Probe in `probeStreamFormat` hat ebenfalls den Fallback-Pfad — dieser wird vereinfacht.

- [ ] **Step 1: `fallbackToRawStream` löschen**

Methode `private func fallbackToRawStream(songId:)` (Zeilen ~447–459) komplett löschen.

- [ ] **Step 2: `schedulePlaybackWatchdog` löschen**

Methode `private func schedulePlaybackWatchdog(for:url:)` (Zeilen ~461–478) komplett löschen.

- [ ] **Step 3: `playbackWatchdog` Property löschen**

```swift
private var playbackWatchdog: Task<Void, Never>?
```
Diese Zeile löschen.

- [ ] **Step 4: `probeStreamFormat` — Fallback-Aufrufe entfernen**

In `probeStreamFormat` gibt es zwei Stellen wo `fallbackToRawStream` aufgerufen wird (bei schlechtem HTTP-Status und bei Netzwerkfehler). Diese Blocks einfach mit `return` beenden:

```swift
// VORHER:
if http.statusCode != 200, isTranscoded {
    print("[Transcoding] HEAD status \(http.statusCode) → fallback to raw")
    await MainActor.run { self?.fallbackToRawStream(songId: songId) }
    return
}

// NACHHER:
if http.statusCode != 200 { return }
```

```swift
// VORHER (catch-Block):
if isTranscoded {
    print("[Transcoding] HEAD failed (\(error.localizedDescription)) → fallback to raw")
    await MainActor.run { self?.fallbackToRawStream(songId: songId) }
}

// NACHHER:
print("[StreamFormat] HEAD failed: \(error.localizedDescription)")
```

Ausserdem: Da `probeStreamFormat` für transcodierte Streams nicht mehr aufgerufen wird (in Task 2 wird `actualStreamFormat` sofort aus der Policy gesetzt), kann die `isTranscoded`-Variable in `probeStreamFormat` entfernt werden — sie hat keinen Effekt mehr. Die gesamte Funktion vereinfacht sich zu einem HEAD-Request für Raw-Streams zur Bitrate-Erkennung.

- [ ] **Step 5: Build + Kompilierungsfehler beheben**

`Cmd+B`. Alle Stellen die `fallbackToRawStream` / `schedulePlaybackWatchdog` / `playbackWatchdog` referenzieren müssen bereits in den vorigen Tasks entfernt worden sein. Falls noch Fehler → fehlende Stellen nachziehen.

- [ ] **Step 6: Commit**

```bash
git -C /Users/vasco/Repositorys/Shelv add Shelv/Services/AudioPlayerService.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "remove: watchdog and raw stream fallback (no longer needed)"
```

---

## Task 5: AudioPlayerService iOS — Prefetch + Gapless

**Files:**
- Modify: `Shelv/Services/AudioPlayerService.swift`

Prefetch startet 30s vor Ende für transcodierte Streams. Gapless bekommt bei fertigem Cache die lokale URL, sonst wird der transkodierte Remote-URL-Pfad geblockt.

- [ ] **Step 1: `checkGaplessTrigger` erweitern**

Aktueller Code (Zeile ~1097):
```swift
private func checkGaplessTrigger(currentTime: Double) {
    guard gaplessEnabled else { return }
    guard !gaplessPreloadTriggered, duration > 11 else { return }
    let preloadAt = duration - 10
    guard currentTime >= preloadAt else { return }
    guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
    guard let nextSong = peekNextSong() else { return }
    guard let url = resolveURL(for: nextSong) else { return }
    gaplessPreloadSong = nextSong
    gaplessPreloadURL = url
    gaplessPreloadTriggered = true
    engine.preloadForGapless(url: url)
}
```

Ersetzen durch:
```swift
private func checkGaplessTrigger(currentTime: Double) {
    guard !gaplessPreloadTriggered, duration > 11 else { return }
    guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
    guard let nextSong = peekNextSong() else { return }

    // Prefetch: 30s vor Ende starten (immer, unabhängig von Gapless)
    let prefetchAt = max(0, duration - 30)
    if currentTime >= prefetchAt,
       let nextURL = SubsonicAPIService.shared.streamURL(for: nextSong.id),
       isTranscodedRemote(nextURL),
       let fmt = TranscodingPolicy.currentStreamFormat() {
        Task {
            await StreamCacheService.shared.prefetch(
                songId: nextSong.id,
                url: nextURL,
                codec: fmt.codec.rawValue,
                bitrate: fmt.bitrate
            )
        }
    }

    // Gapless: 10s vor Ende
    guard gaplessEnabled else { return }
    let preloadAt = duration - 10
    guard currentTime >= preloadAt else { return }
    guard let url = resolveURL(for: nextSong) else { return }

    // Transcodierten Remote-Stream nicht an engine übergeben — Prefetch evtl. noch nicht fertig
    guard !isTranscodedRemote(url) else { return }

    gaplessPreloadSong = nextSong
    gaplessPreloadURL = url
    gaplessPreloadTriggered = true
    engine.preloadForGapless(url: url)
}
```

**Hinweis:** `gaplessPreloadTriggered = true` wird erst gesetzt wenn `preloadForGapless` wirklich aufgerufen wird. Für den Prefetch-Pfad (30s) wird das Flag nicht gesetzt, damit die 10s-Prüfung noch normal laufen kann sobald die Datei gecacht ist.

**Problem:** Im aktuellen Code prüft die 10s-Prüfung nur einmal (weil `gaplessPreloadTriggered` dann true wäre). Für den Fall dass die Datei zwischen 30s und 10s fertig wird, ist das ok — die 10s-Prüfung findet eine lokale URL und setzt `preloadForGapless`. Wenn die Datei erst nach 10s fertig ist → kein Gapless, kleiner Gap.

- [ ] **Step 2: Gapless-Callback wenn Prefetch nachträglich fertig**

Optional-Upgrade: Nach dem Download in `StreamCacheService` eine Notification posten, damit `AudioPlayerService` `preloadForGapless` nachholen kann wenn wir noch in der letzten 10s sind. Das ist eine separate optionale Verbesserung — für den ersten Wurf überspringen.

- [ ] **Step 3: Build prüfen**

`Cmd+B`. Kein Fehler erwartet.

- [ ] **Step 4: Commit**

```bash
git -C /Users/vasco/Repositorys/Shelv add Shelv/Services/AudioPlayerService.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "feat: transcoded stream prefetch 30s before end, gapless blocks remote transcoded URL"
```

---

## Task 6: App-Cleanup + PlayerBarView iOS

**Files:**
- Modify: `Shelv/ShelvApp.swift`
- Modify: `Shelv/Views/Player/PlayerBarView.swift`

- [ ] **Step 1: Temp-Dateien beim App-Start bereinigen**

In `ShelvApp.swift`, im ersten `onAppear` oder `.task {}` Block:
```swift
Task.detached(priority: .utility) {
    await StreamCacheService.shared.cleanupOldFiles()
}
```

- [ ] **Step 2: „Verbinde…" → „Lädt…" in PlayerBarView**

Datei: `Shelv/Views/Player/PlayerBarView.swift`, Zeile 16:

```swift
// VORHER:
Text(tr("Connecting...", "Verbinde..."))

// NACHHER:
Text(tr("Loading...", "Lädt..."))
```

- [ ] **Step 3: Build + kurzer manueller Test**

Song mit Transcoding abspielen → PlayerBar soll „Lädt..." zeigen während Download läuft.

- [ ] **Step 4: Commit**

```bash
git -C /Users/vasco/Repositorys/Shelv add Shelv/ShelvApp.swift Shelv/Views/Player/PlayerBarView.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "fix: loading text and startup cleanup for stream cache"
```

---

## Task 7: StreamCacheService Desktop

**Files:**
- Create: `Shelv Desktop/Services/StreamCacheService.swift`

Der Service ist identisch mit iOS. Einzige Unterschiede:
- `ActualStreamFormat` liegt möglicherweise in einer anderen Datei — Pfad prüfen

- [ ] **Step 1: Datei suchen**

```bash
grep -rn "struct ActualStreamFormat" "/Users/vasco/Repositorys/Shelv Desktop/"
```

- [ ] **Step 2: `StreamCacheService.swift` für Desktop anlegen**

Inhalt identisch mit `Shelv/Services/StreamCacheService.swift` aus Task 1. Datei ablegen unter:
`Shelv Desktop/Services/StreamCacheService.swift`

In Xcode zur Gruppe `Shelv Desktop/Services/` hinzufügen. Build: `Cmd+B`.

- [ ] **Step 3: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add "Shelv Desktop/Services/StreamCacheService.swift"
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "feat: add StreamCacheService for transcoded stream temp-caching"
```

---

## Task 8: AudioPlayerService Desktop

**Files:**
- Modify: `Shelv Desktop/Services/AudioPlayerService.swift`

Die Desktop-Version verwendet `loadURL(_:song:seekTo:)` statt `startPlayback`, und `resolveURL(songId:)` statt `resolveURL(for:)`. Die Änderungen sind analog zu iOS.

- [ ] **Step 1: `resolveURL(songId:)` erweitern**

Aktuelle Methode (`Zeile ~153`):
```swift
private func resolveURL(songId: String) -> URL? {
    let serverId = AppState.shared.serverStore.activeServer?.stableId ?? ""
    if !serverId.isEmpty,
       let local = LocalDownloadIndex.shared.url(songId: songId, serverId: serverId) {
        return local
    }
    guard !OfflineModeService.shared.isOffline else { return nil }
    return apiService.streamURL(songId: songId)
}
```

Ersetzen durch:
```swift
private func resolveURL(songId: String) -> URL? {
    let serverId = AppState.shared.serverStore.activeServer?.stableId ?? ""
    if !serverId.isEmpty,
       let local = LocalDownloadIndex.shared.url(songId: songId, serverId: serverId) {
        return local
    }
    guard !OfflineModeService.shared.isOffline else { return nil }
    if let cached = StreamCacheService.shared.localURL(for: songId) {
        return cached
    }
    return apiService.streamURL(songId: songId)
}
```

- [ ] **Step 2: `isTranscodedRemote(_:)` einfügen**

Nach `resolveURL`:
```swift
private func isTranscodedRemote(_ url: URL) -> Bool {
    guard !url.isFileURL else { return false }
    let fmt = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "format" })?.value
    return fmt != nil && fmt != "raw"
}
```

- [ ] **Step 3: `loadURL` anpassen**

In `loadURL(_:song:seekTo:)` (`Zeile ~777`), nach dem bisherigen Setup-Block (vor `engine.play(url: url)`):

```swift
// Transcodierter Remote-Stream → erst cachen, dann abspielen
if isTranscodedRemote(url), let fmt = TranscodingPolicy.currentStreamFormat() {
    let songId = song.id
    actualStreamFormat = ActualStreamFormat(
        codecLabel: fmt.codec.rawValue.uppercased(),
        bitrateKbps: fmt.bitrate
    )
    Task { @MainActor [weak self] in
        guard let self else { return }
        await StreamCacheService.shared.prefetch(
            songId: songId,
            url: url,
            codec: fmt.codec.rawValue,
            bitrate: fmt.bitrate
        )
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            guard self.currentSong?.id == songId else { return }
            if let local = await StreamCacheService.shared.localURL(for: songId) {
                self.currentStreamURL = local
                self.engine.play(url: local)
                self.engine.trustedDuration = Double(song.duration ?? 0)
                if seekTo > 1 { self.engine.seek(to: seekTo) }
                self.isEngineLoaded = true
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
} else {
    engine.play(url: url)
    engine.trustedDuration = Double(song.duration ?? 0)
    isEngineLoaded = true
    if seekTo > 1 { engine.seek(to: seekTo) }
}
```

`schedulePlaybackWatchdog` Aufruf aus `loadURL` entfernen.

- [ ] **Step 4: Cancel beim Song-Wechsel**

Am Anfang von `loadURL`, nach dem Reset der State-Variablen:
```swift
if let prev = currentSong {
    Task { await StreamCacheService.shared.cancel(songId: prev.id) }
}
```

- [ ] **Step 5: `seek(to:)` vereinfachen**

Aktuellen transcoded-Branch (Zeilen 708–727) entfernen, nur den normalen Seek-Block behalten:
```swift
func seek(to time: Double) {
    isSeeking = true
    currentTime = time
    let buffered = engine.isPositionBuffered(time)
    let shouldPauseAndWait = !buffered && self.isPlaying
    if shouldPauseAndWait { isBuffering = true }
    engine.seek(to: time, pauseUntilBuffered: shouldPauseAndWait) { [weak self] finished in
        Task { @MainActor [weak self] in
            guard let self else { return }
            if finished { self.currentTime = time }
            self.isSeeking = false
        }
    }
}
```

- [ ] **Step 6: Watchdog + Fallback entfernen (Desktop)**

`fallbackToRawStream(songId:duration:)` und `schedulePlaybackWatchdog(songId:url:duration:)` komplett löschen. `playbackWatchdog` Property löschen. In `probeStreamFormat` Fallback-Aufrufe durch `return` ersetzen (analog Task 4, Step 4 iOS).

- [ ] **Step 7: `checkGaplessTrigger` Desktop anpassen**

Analog zu Task 5 iOS. Unterschied: `apiService.streamURL(songId:)` statt `SubsonicAPIService.shared.streamURL(for:)`.

```swift
private func checkGaplessTrigger(currentTime: Double) {
    guard !gaplessPreloadTriggered, duration > 11 else { return }
    guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
    guard let nextSong = peekNextSong() else { return }

    let prefetchAt = max(0, duration - 30)
    if currentTime >= prefetchAt,
       let nextURL = apiService.streamURL(songId: nextSong.id),
       isTranscodedRemote(nextURL),
       let fmt = TranscodingPolicy.currentStreamFormat() {
        Task {
            await StreamCacheService.shared.prefetch(
                songId: nextSong.id,
                url: nextURL,
                codec: fmt.codec.rawValue,
                bitrate: fmt.bitrate
            )
        }
    }

    guard gaplessEnabled else { return }
    let preloadAt = duration - 10
    guard currentTime >= preloadAt else { return }
    guard let url = resolveURL(songId: nextSong.id) else { return }
    guard !isTranscodedRemote(url) else { return }

    gaplessPreloadSong = nextSong
    gaplessPreloadURL = url
    gaplessPreloadTriggered = true
    engine.preloadForGapless(url: url)
}
```

- [ ] **Step 8: Build Desktop**

`Cmd+B`. Alle Kompilierungsfehler beheben.

- [ ] **Step 9: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add "Shelv Desktop/Services/AudioPlayerService.swift"
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "feat: route transcoded streams through StreamCacheService, remove watchdog"
```

---

## Task 9: Desktop App-Cleanup

**Files:**
- Modify: `Shelv Desktop/ShelvApp.swift` oder AppDelegate

- [ ] **Step 1: Cleanup beim App-Start**

```swift
Task.detached(priority: .utility) {
    await StreamCacheService.shared.cleanupOldFiles()
}
```

- [ ] **Step 2: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add .
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "feat: cleanup old temp stream files on app start"
```

---

## Spec-Coverage Check

| Anforderung | Task |
|---|---|
| StreamCacheService mit Download-to-temp | Task 1, 7 |
| Cancellation bei Song-Wechsel | Task 2 (Step 5), 8 (Step 4) |
| Retry 3× bei Fehler | Task 1 (downloadWithRetry) |
| isBuffering während Download | Task 2 (isBuffering=true vor Polling) |
| seekTo > 0 nach lokalem Download | Task 2 (Step 3), 8 (Step 3) |
| Watchdog + Fallback entfernen | Task 4, 8 (Step 6) |
| seek() vereinfachen | Task 3, 8 (Step 5) |
| streamTimeOffset für transcoded = 0 | Task 3 (implizit, wird nie gesetzt) |
| Prefetch 30s vor Ende | Task 5, 8 (Step 7) |
| Gapless blockiert remote transcoded URL | Task 5, 8 (Step 7) |
| Gapless für Raw/lokal unverändert | Task 5 (nur transcoded-Guard) |
| actualStreamFormat sofort aus Policy | Task 2 (Step 3), 8 (Step 3) |
| „Verbinde…" → „Lädt…" | Task 6 |
| Temp-Cleanup beim App-Start | Task 6, 9 |
| Song < 30s → Prefetch sofort | Task 5 (`max(0, duration - 30)`) |
| Fallback auf Raw wenn 3× fehlgeschlagen | `StreamCacheService` gibt auf, `startPlayback` bleibt in Polling → Timeout, dann kein Play. **Lücke:** Nach Timeout sollte Raw-Stream versucht werden. |

### Lücke: Raw-Fallback nach Timeout

Nach dem 60s-Polling-Timeout in `startPlayback` / `loadURL` sollte als letzter Ausweg der Raw-Stream abgespielt werden:

```swift
// Nach dem while-Loop in startPlayback (iOS):
// Timeout — Raw-Stream als Fallback
if let rawURL = SubsonicAPIService.shared.rawStreamURL(for: songId),
   self.currentSong?.id == songId {
    self.currentStreamURL = rawURL
    self.probeStreamFormat(for: song, url: rawURL)
    self.engine.play(url: rawURL)
    self.engine.trustedDuration = Double(song.duration ?? 0)
    if seekTo > 0 { self.engine.seek(to: seekTo) }
    self.isEngineLoaded = true
}
```

Entsprechend für Desktop mit `apiService.rawStreamURL(songId:)`. Dies in Task 2 (Step 3) und Task 8 (Step 3) jeweils nach dem `while`-Loop einfügen.
