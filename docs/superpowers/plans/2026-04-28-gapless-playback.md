# Gapless Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Gapless toggle (mutually exclusive with Crossfade) that preloads the next song 10 s before the current one ends and swaps instantly at natural song end — on both iOS and macOS.

**Architecture:** CrossfadeEngine gets a `preloadForGapless(url:isTranscoded:)` method and a `private var gaplessPreloaded` flag; the natural-end observer performs an instant player-swap when the flag is set and passes a `Bool` to `onTrackFinished` so AudioPlayerService can update state without re-triggering `engine.play()`. AudioPlayerService stores the preloaded song/URL and advances the queue at preload time (same as crossfade).

**Tech Stack:** Swift, AVFoundation, SwiftUI `@AppStorage`, existing CrossfadeEngine / AudioPlayerService patterns.

---

## Files Modified

| File | What changes |
|------|-------------|
| `Shelv/Services/CrossfadeEngine.swift` | `onTrackFinished` → `(Bool)->Void`; `preloadForGapless`; `performGaplessSwap`; reset in `play()` |
| `Shelv/Services/AudioPlayerService.swift` | Gapless AppStorage + state; `setupEngine` callback; `checkCrossfadeTrigger` gapless path; `gaplessTransitionState` |
| `Shelv/Views/Settings/SettingsView.swift` | Gapless toggle, mutually exclusive with crossfade |
| `Shelv Desktop/Services/CrossfadeEngine.swift` | Same engine changes |
| `Shelv Desktop/Services/AudioPlayerService.swift` | Same service changes, adapted to QueueItem/`playNext` |
| `Shelv Desktop/Views/CrossfadePanel.swift` | Gapless toggle above crossfade |

**New AppStorage key:** `gaplessEnabled` (Bool, default `false`) — both platforms.

---

## Task 1: CrossfadeEngine — iOS

**Files:**
- Modify: `Shelv/Services/CrossfadeEngine.swift`

- [ ] **Step 1: `gaplessPreloaded` property + reset in `play()`**

Add after `private var isTranscoded: Bool = false`:
```swift
private var gaplessPreloaded = false
```

In `play(url:isTranscoded:)`, after `trustedDuration = 0`:
```swift
gaplessPreloaded = false
```

- [ ] **Step 2: `preloadForGapless` method**

Add after `triggerCrossfade`:
```swift
func preloadForGapless(url: URL, isTranscoded: Bool = false) {
    inactivePlayer.automaticallyWaitsToMinimizeStalling = isTranscoded
    inactivePlayer.replaceCurrentItem(with: makePlayerItem(url: url))
    inactivePlayer.volume = 0
    inactivePlayer.seek(to: .zero)
    inactivePlayer.play()
    gaplessPreloaded = true
}
```

- [ ] **Step 3: `performGaplessSwap` private method**

Add after `completeFade()`:
```swift
private func performGaplessSwap() {
    removeTimeObserver()
    removeItemFinishedObserver()

    let outgoing = activePlayer
    outgoing.pause()
    outgoing.replaceCurrentItem(with: nil)
    outgoing.volume = 1.0

    swap(&activePlayer, &inactivePlayer)
    activePlayer.volume = 1.0
    gaplessPreloaded = false
    isPlaying = true

    setupTimeObserver()
    setupItemFinishedObserver()
}
```

- [ ] **Step 4: Change `onTrackFinished` signature + update all call sites**

Change property declaration:
```swift
var onTrackFinished: ((Bool) -> Void)?
```

In `completeFade()`, change:
```swift
onTrackFinished?()
```
to:
```swift
onTrackFinished?(false)
```

In `setupItemFinishedObserver()`, change the observer body from:
```swift
) { [weak self] _ in
    guard let self, !self.isCrossfading else { return }
    self.isPlaying = false
    self.onTrackFinished?()
}
```
to:
```swift
) { [weak self] _ in
    guard let self, !self.isCrossfading else { return }
    if self.gaplessPreloaded {
        self.performGaplessSwap()
        self.onTrackFinished?(true)
    } else {
        self.isPlaying = false
        self.onTrackFinished?(false)
    }
}
```

- [ ] **Step 5: Build iOS to verify no errors**
```bash
xcodebuild -scheme Shelv -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "error:|Build succeeded|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **` (compiler errors expected until Task 2 updates the callback site)

---

## Task 2: AudioPlayerService — iOS

**Files:**
- Modify: `Shelv/Services/AudioPlayerService.swift`

- [ ] **Step 1: Add gapless state properties**

Near the top of the class, alongside `crossfadeTriggered`:
```swift
@AppStorage("gaplessEnabled") private var gaplessEnabled = false
private var gaplessPreloadTriggered = false
private var gaplessPreloadSong: Song? = nil
private var gaplessPreloadURL: URL? = nil
```

- [ ] **Step 2: Reset gapless state in `startPlayback(song:)`**

After `crossfadeTriggered = false` and `crossfadeSeekSuppressed = false`:
```swift
gaplessPreloadTriggered = false
gaplessPreloadSong = nil
gaplessPreloadURL = nil
```

- [ ] **Step 3: Update `setupEngine()` callback**

Change:
```swift
engine.onTrackFinished = { [weak self] in
    guard let self else { return }
    if self.crossfadeTriggered {
        self.crossfadeTriggered = false
    } else {
        self.next(triggeredByUser: false)
    }
}
```
to:
```swift
engine.onTrackFinished = { [weak self] gaplessSwapDone in
    guard let self else { return }
    if self.crossfadeTriggered {
        self.crossfadeTriggered = false
    } else if gaplessSwapDone, let song = self.gaplessPreloadSong {
        self.gaplessPreloadTriggered = false
        self.gaplessPreloadSong = nil
        let url = self.gaplessPreloadURL
        self.gaplessPreloadURL = nil
        self.crossfadeSeekSuppressed = false
        self.currentSong = song
        self.currentTime = 0
        self.isEngineLoaded = true
        self.isBuffering = false
        if let d = song.duration { self.duration = Double(d) }
        self.updateNowPlayingInfo(song: song)
        MPNowPlayingInfoCenter.default().playbackState = .playing
        if let url = url {
            self.probeStreamFormat(for: song, url: url)
            self.schedulePlaybackWatchdog(for: song, url: url)
        }
        let scrobbleSongId = song.id
        let scrobbleServerId = SubsonicAPIService.shared.activeServer?.stableId ?? ""
        let scrobbleAt = Date().timeIntervalSince1970
        Task {
            do {
                try await SubsonicAPIService.shared.scrobble(songId: scrobbleSongId, playedAt: scrobbleAt)
            } catch {
                guard !scrobbleServerId.isEmpty else { return }
                await PlayLogService.shared.addPendingScrobble(
                    songId: scrobbleSongId, serverId: scrobbleServerId, playedAt: scrobbleAt
                )
            }
        }
        self.saveState()
    } else {
        self.next(triggeredByUser: false)
    }
}
```

- [ ] **Step 4: Add gapless path to `checkCrossfadeTrigger`**

At the very start of `checkCrossfadeTrigger`, before the crossfade guard:
```swift
if gaplessEnabled && !crossfadeEnabled {
    guard !crossfadeTriggered, !gaplessPreloadTriggered, duration > 11 else { return }
    let preloadAt = duration - 10
    guard currentTime >= preloadAt else { return }
    guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
    guard let nextSong = peekNextSong() else { return }
    guard let url = resolveURL(for: nextSong) else { return }
    let isTranscoded = TranscodingPolicy.currentStreamFormat() != nil
    advanceQueueState()
    gaplessPreloadSong = nextSong
    gaplessPreloadURL = url
    gaplessPreloadTriggered = true
    engine.preloadForGapless(url: url, isTranscoded: isTranscoded)
    engine.trustedDuration = Double(nextSong.duration ?? 0)
    saveState()
    return
}
```

- [ ] **Step 5: Build iOS and verify**
```bash
xcodebuild -scheme Shelv -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "error:|Build succeeded|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **`

---

## Task 3: iOS Settings UI

**Files:**
- Modify: `Shelv/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Add `@AppStorage("gaplessEnabled")`**

Near `@AppStorage("crossfadeEnabled")`:
```swift
@AppStorage("gaplessEnabled") private var gaplessEnabled = false
```

- [ ] **Step 2: Add Gapless toggle to the Crossfade section**

The section currently starts at `Section(tr("Crossfade", "Crossfade")) {`. Replace the entire section with:
```swift
Section(tr("Crossfade & Gapless", "Crossfade & Gapless")) {
    Toggle(isOn: $gaplessEnabled) {
        Label { Text(tr("Gapless", "Gapless")) } icon: {
            Image(systemName: "waveform.path").foregroundStyle(accentColor)
        }
    }
    .tint(accentColor)
    .disabled(crossfadeEnabled)
    .onChange(of: gaplessEnabled) { _, on in
        if on { crossfadeEnabled = false }
    }

    Toggle(isOn: $crossfadeEnabled) {
        Label { Text(tr("Crossfade", "Crossfade")) } icon: {
            Image(systemName: "waveform").foregroundStyle(accentColor)
        }
    }
    .tint(accentColor)
    .disabled(gaplessEnabled)
    .onChange(of: crossfadeEnabled) { _, on in
        if on { gaplessEnabled = false }
    }

    if crossfadeEnabled {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label { Text(tr("Duration", "Dauer")) } icon: {
                    Image(systemName: "timer").foregroundStyle(accentColor)
                }
                Spacer()
                Text("\(crossfadeDuration)s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(crossfadeDuration) },
                    set: { crossfadeDuration = Int($0.rounded()) }
                ),
                in: 1...12,
                step: 1
            )
            .tint(accentColor)
        }
    }
}
```

- [ ] **Step 3: Build iOS**
```bash
xcodebuild -scheme Shelv -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "error:|Build succeeded|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **`

---

## Task 4: CrossfadeEngine — macOS Desktop

**Files:**
- Modify: `Shelv Desktop/Shelv Desktop/Services/CrossfadeEngine.swift`

Same changes as Task 1. The Desktop CrossfadeEngine has the same structure.

- [ ] **Step 1: `gaplessPreloaded` property + reset in `play()`**

Add after `private var isTranscoded: Bool = false`:
```swift
private var gaplessPreloaded = false
```

In `play(url:isTranscoded:)`, after `trustedDuration = 0`:
```swift
gaplessPreloaded = false
```

- [ ] **Step 2: `preloadForGapless` method**

Add after `triggerCrossfade`:
```swift
func preloadForGapless(url: URL, isTranscoded: Bool = false) {
    inactivePlayer.automaticallyWaitsToMinimizeStalling = isTranscoded
    inactivePlayer.replaceCurrentItem(with: makePlayerItem(url: url))
    inactivePlayer.volume = 0
    inactivePlayer.seek(to: .zero)
    inactivePlayer.play()
    gaplessPreloaded = true
}
```

- [ ] **Step 3: `performGaplessSwap` private method**

Add after `completeFade()`:
```swift
private func performGaplessSwap() {
    removeTimeObserver()
    removeItemFinishedObserver()

    let outgoing = activePlayer
    outgoing.pause()
    outgoing.replaceCurrentItem(with: nil)
    outgoing.volume = volume

    swap(&activePlayer, &inactivePlayer)
    activePlayer.volume = volume
    gaplessPreloaded = false
    isPlaying = true

    setupTimeObserver()
    setupItemFinishedObserver()
}
```

Note: Desktop uses `volume` (variable) instead of `1.0` (fixed) since Desktop has a volume property.

- [ ] **Step 4: Change `onTrackFinished` signature + update all call sites**

Change property declaration:
```swift
var onTrackFinished: ((Bool) -> Void)?
```

In `completeFade()`, change `onTrackFinished?()` to `onTrackFinished?(false)`.

In `setupItemFinishedObserver()`, change the observer body from:
```swift
) { [weak self] _ in
    guard let self, !self.isCrossfading else { return }
    self.isPlaying = false
    self.onTrackFinished?()
}
```
to:
```swift
) { [weak self] _ in
    guard let self, !self.isCrossfading else { return }
    if self.gaplessPreloaded {
        self.performGaplessSwap()
        self.onTrackFinished?(true)
    } else {
        self.isPlaying = false
        self.onTrackFinished?(false)
    }
}
```

- [ ] **Step 5: Build Desktop to verify**
```bash
xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" -scheme "Shelv Desktop" -destination 'platform=macOS' -configuration Debug build 2>&1 | grep -E "error:|Build succeeded|BUILD FAILED"
```
Expected: compiler errors until Task 5 updates the callback site.

---

## Task 5: AudioPlayerService — macOS Desktop

**Files:**
- Modify: `Shelv Desktop/Shelv Desktop/Services/AudioPlayerService.swift`

- [ ] **Step 1: Add gapless state properties**

Near `crossfadeTriggered`:
```swift
@AppStorage("gaplessEnabled") private var gaplessEnabled = false
private var gaplessPreloadTriggered = false
private var gaplessPreloadSong: Song? = nil
private var gaplessPreloadURL: URL? = nil
```

- [ ] **Step 2: Reset gapless state in `loadURL(_:song:)`**

After `crossfadeTriggered = false`:
```swift
gaplessPreloadTriggered = false
gaplessPreloadSong = nil
gaplessPreloadURL = nil
```

- [ ] **Step 3: Update `setupEngine()` callback**

Change:
```swift
engine.onTrackFinished = { [weak self] in
    guard let self else { return }
    Task { @MainActor [self] in
        if self.crossfadeTriggered {
            self.crossfadeTriggered = false
        } else {
            self.playNext(triggeredByUser: false)
        }
    }
}
```
to:
```swift
engine.onTrackFinished = { [weak self] gaplessSwapDone in
    guard let self else { return }
    Task { @MainActor [self] in
        if self.crossfadeTriggered {
            self.crossfadeTriggered = false
        } else if gaplessSwapDone, let song = self.gaplessPreloadSong {
            self.gaplessPreloadTriggered = false
            self.gaplessPreloadSong = nil
            let url = self.gaplessPreloadURL
            self.gaplessPreloadURL = nil
            self.currentSong = song
            self.currentTime = 0
            self.hasScrobbledCurrent = false
            self.isEngineLoaded = true
            self.isBuffering = false
            if let d = song.duration { self.duration = Double(d) }
            self.updateNowPlayingInfo(song: song)
            MPNowPlayingInfoCenter.default().playbackState = .playing
            self.loadArtworkAsync(for: song)
            if let url = url {
                self.probeStreamFormat(songId: song.id, url: url, duration: Double(song.duration ?? 0))
                self.schedulePlaybackWatchdog(songId: song.id, url: url, duration: Double(song.duration ?? 0))
            }
            self.saveState()
            Task { try? await self.apiService.scrobble(songId: song.id, submission: false) }
        } else {
            self.playNext(triggeredByUser: false)
        }
    }
}
```

- [ ] **Step 4: Add gapless path to `checkCrossfadeTrigger`**

At the very start of `checkCrossfadeTrigger`, before the crossfade guard:
```swift
if gaplessEnabled && !crossfadeEnabled {
    guard !crossfadeTriggered, !gaplessPreloadTriggered, duration > 11 else { return }
    let preloadAt = duration - 10
    guard currentTime >= preloadAt else { return }
    guard !(repeatMode == .one && playNextQueue.isEmpty) else { return }
    guard let nextSong = peekNextSong() else { return }
    guard let url = resolveURL(songId: nextSong.id) else { return }
    let isTranscoded = TranscodingPolicy.currentStreamFormat() != nil
    advanceQueueState()
    gaplessPreloadSong = nextSong
    gaplessPreloadURL = url
    gaplessPreloadTriggered = true
    engine.preloadForGapless(url: url, isTranscoded: isTranscoded)
    engine.trustedDuration = Double(nextSong.duration ?? 0)
    saveState()
    return
}
```

- [ ] **Step 5: Build Desktop**
```bash
xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" -scheme "Shelv Desktop" -destination 'platform=macOS' -configuration Debug build 2>&1 | grep -E "error:|Build succeeded|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **`

---

## Task 6: CrossfadePanel — macOS Desktop UI

**Files:**
- Modify: `Shelv Desktop/Shelv Desktop/Views/CrossfadePanel.swift`

- [ ] **Step 1: Add `@AppStorage("gaplessEnabled")` and update UI**

Replace the entire file content with:
```swift
import SwiftUI

struct CrossfadePanel: View {
    @AppStorage("crossfadeEnabled") private var crossfadeEnabled = false
    @AppStorage("crossfadeDuration") private var crossfadeDuration = 5
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $gaplessEnabled) {
                    Label(tr("Gapless", "Gapless"), systemImage: "waveform.path")
                }
                .tint(themeColor)
                .disabled(crossfadeEnabled)
                .onChange(of: gaplessEnabled) { _, on in
                    if on { crossfadeEnabled = false }
                }

                Toggle(isOn: $crossfadeEnabled) {
                    Label(tr("Crossfade", "Crossfade"), systemImage: "waveform")
                }
                .tint(themeColor)
                .disabled(gaplessEnabled)
                .onChange(of: crossfadeEnabled) { _, on in
                    if on { gaplessEnabled = false }
                }

                if crossfadeEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(tr("Duration", "Dauer"), systemImage: "timer")
                            Spacer()
                            Text("\(crossfadeDuration)s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(crossfadeDuration) },
                                set: { crossfadeDuration = Int($0.rounded()) }
                            ),
                            in: 1...12,
                            step: 1
                        )
                        .tint(themeColor)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .fixedSize()
    }
}
```

- [ ] **Step 2: Final build — both platforms**
```bash
xcodebuild -scheme Shelv -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | grep -E "error:|Build succeeded|BUILD FAILED"
```
```bash
xcodebuild -project "/Users/vasco/Repositorys/Shelv Desktop/Shelv Desktop.xcodeproj" -scheme "Shelv Desktop" -destination 'platform=macOS' -configuration Debug build 2>&1 | grep -E "error:|Build succeeded|BUILD FAILED"
```
Both expected: `** BUILD SUCCEEDED **`
