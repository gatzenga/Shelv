# UI Polish: 5 Bug Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 5 UI issues across Shelv iOS and Shelv Desktop: play/shuffle button icons missing in artist detail (iOS), download badge absent from Discover album cards (macOS), Settings tab icons jitter during downloads (macOS), sidebar has no download progress visible (macOS), offline mode missing from menu bar (macOS).

**Architecture:** Minimal targeted fixes only — no refactoring beyond what is needed. The iOS fix is a single `.labelStyle` addition. The macOS re-render fixes follow the existing isolated-sub-view pattern (same as `PlayerBarOverlay` / `PlayerBarInset` on iOS) so that high-frequency Combine updates stay in leaf views rather than propagating up to `TabView` or the entire `SidebarView`.

**Tech Stack:** SwiftUI (iOS 17+, macOS 14+), Combine, `@ObservedObject` isolation pattern

---

### Task 0: Throttle planBulkDownload (BEIDE Plattformen)

**Files:**
- Modify: `Shelv Desktop/Services/DownloadService.swift` (planBulkDownload)
- Modify: `Shelv/Services/DownloadService.swift` (planBulkDownload)

**Context:** `planBulkDownload` erstellt pro Album einen Task ohne Concurrency-Limit. Bei 200+ Alben = 200+ simultane HTTP-Requests → nw_endpoint-Fehler, App-Freeze. Fix: Producer/Consumer-Pattern innerhalb der `withTaskGroup` mit max. 10 gleichzeitigen Jobs.

- [ ] **Step 1: macOS — planBulkDownload throtteln**

In `Shelv Desktop/Services/DownloadService.swift`, den `allSongs`-Block in `planBulkDownload` ersetzen:

```swift
// Vorher (unbegrenzt):
let allSongs = await withTaskGroup(of: [Song].self) { group -> [Song] in
    for album in libraryAlbums {
        group.addTask {
            (try? await api.getAlbum(id: album.id))?.song ?? []
        }
    }
    var result: [Song] = []
    for await songs in group { result.append(contentsOf: songs) }
    return result
}
```

```swift
// Nachher (max 10 parallel):
let allSongs: [Song] = await withTaskGroup(of: [Song].self) { group in
    let limit = 10
    var index = 0
    var result: [Song] = []
    for album in libraryAlbums.prefix(limit) {
        group.addTask { (try? await api.getAlbum(id: album.id))?.song ?? [] }
        index += 1
    }
    for await songs in group {
        result.append(contentsOf: songs)
        if index < libraryAlbums.count {
            let next = libraryAlbums[index]
            group.addTask { (try? await api.getAlbum(id: next.id))?.song ?? [] }
            index += 1
        }
    }
    return result
}
```

- [ ] **Step 2: iOS — gleiche Änderung in Shelv/Services/DownloadService.swift**

Die identische Ersetzung in `Shelv/Services/DownloadService.swift` durchführen.

- [ ] **Step 3: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add "Shelv Desktop/Services/DownloadService.swift"
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "fix: throttle planBulkDownload to max 10 concurrent requests"

git -C /Users/vasco/Repositorys/Shelv add Shelv/Services/DownloadService.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "fix: throttle planBulkDownload to max 10 concurrent requests"
```

---

### Task 1: iOS — Play/Shuffle button icons in ArtistDetailView

**Files:**
- Modify: `Shelv/Views/Library/ArtistDetailView.swift` (lines 134–135, 149–150)

**Context:** `artistHeader` is rendered in both `gridBody` (ScrollView) and `listBody` (List). On iOS, a `List` implicitly applies `.labelStyle(.titleOnly)` to all descendant `Label` views, which strips the icon. Adding `.labelStyle(.titleAndIcon)` explicitly overrides this for the two action buttons.

- [ ] **Step 1: Fix Play button**

In `Shelv/Views/Library/ArtistDetailView.swift`, find (around line 133):
```swift
Label(tr("Play", "Abspielen"), systemImage: "play.fill")
    .font(.subheadline.weight(.semibold))
```
Replace with:
```swift
Label(tr("Play", "Abspielen"), systemImage: "play.fill")
    .labelStyle(.titleAndIcon)
    .font(.subheadline.weight(.semibold))
```

- [ ] **Step 2: Fix Shuffle button**

In the same file, find (around line 149):
```swift
Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
    .font(.subheadline.weight(.semibold))
```
Replace with:
```swift
Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
    .labelStyle(.titleAndIcon)
    .font(.subheadline.weight(.semibold))
```

- [ ] **Step 3: Build and verify in Xcode**

Build the Shelv (iOS) target. Navigate to Library → any Artist. Verify:
- In grid mode: play.fill icon and shuffle icon visible in header buttons
- Switch to list mode (via the ellipsis menu "Listenansicht"): icons still visible

- [ ] **Step 4: Commit**

```bash
git -C /Users/vasco/Repositorys/Shelv add Shelv/Views/Library/ArtistDetailView.swift
git -C /Users/vasco/Repositorys/Shelv commit -m "fix: show icons in play/shuffle buttons on artist detail"
```

---

### Task 2: macOS Discover — download badge on AlbumCard

**Files:**
- Modify: `Shelv Desktop/Views/DiscoverView.swift` (AlbumCard.body, around line 289)

**Context:** `AlbumDownloadBadge` already exists in `DownloadIndicators.swift` and is used in album detail views. `AlbumCard` in `DiscoverView` just needs the same overlay added to its `CoverArtView`. The badge internally checks `downloadStore.songs` so it only renders when songs from that album are downloaded — no extra feature-gating needed.

- [ ] **Step 1: Add badge overlay**

In `Shelv Desktop/Views/DiscoverView.swift`, find the `AlbumCard.body` `CoverArtView` line (around line 289):
```swift
CoverArtView(url: coverURL, size: 150, cornerRadius: 8)
    .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 4)
```
Replace with:
```swift
CoverArtView(url: coverURL, size: 150, cornerRadius: 8)
    .overlay(alignment: .bottomTrailing) {
        AlbumDownloadBadge(albumId: album.id)
            .padding(4)
    }
    .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 8 : 4)
```

- [ ] **Step 2: Build and verify**

Build Shelv Desktop. With Downloads enabled and at least one album downloaded: open Discover and confirm a filled circle badge (white arrow on theme-colored background) appears at the bottom-right corner of downloaded album covers.

- [ ] **Step 3: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add "Shelv Desktop/Views/DiscoverView.swift"
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "fix: show download badge on album cards in Discover"
```

---

### Task 3: macOS Settings — fix jittering tab icons during downloads

**Files:**
- Modify: `Shelv Desktop/Views/DownloadsTab.swift`

**Context:** `DownloadsTab` holds `@ObservedObject var downloadStore = DownloadStore.shared`. During active downloads, `batchProgress` publishes several times per second. This fires re-renders of the entire `DownloadsTab`, which sits directly inside `TabView`. macOS re-draws all tab bar icons on each re-render, causing the visible jitter. Fix: extract the progress section into a private `BatchProgressSection` struct. Only that leaf view will observe `downloadStore`; `DownloadsTab` itself becomes a static view.

- [ ] **Step 1: Read the full DownloadsTab file**

Read `Shelv Desktop/Views/DownloadsTab.swift` completely to confirm all usages of `downloadStore` before modifying.

- [ ] **Step 2: Add BatchProgressSection before DownloadsTab**

At the top of `DownloadsTab.swift`, before the `struct DownloadsTab` declaration, insert:

```swift
private struct BatchProgressSection: View {
    @ObservedObject private var downloadStore = DownloadStore.shared
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        if let progress = downloadStore.batchProgress {
            Section(tr("Active Downloads", "Aktive Downloads")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(progress.completed) / \(progress.total)")
                            .monospacedDigit()
                        Spacer()
                        if progress.failed > 0 {
                            Text(tr("\(progress.failed) failed", "\(progress.failed) fehlgeschlagen"))
                                .foregroundStyle(.red)
                        }
                    }
                    ProgressView(value: progress.fraction)
                        .tint(themeColor)
                    HStack {
                        Spacer()
                        Button(tr("Cancel download", "Download abbrechen")) {
                            Task { await DownloadService.shared.cancelBatch() }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .font(.caption)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Replace progress block and remove downloadStore from DownloadsTab**

In `DownloadsTab`:
1. Remove the line `@ObservedObject var downloadStore = DownloadStore.shared`
2. Find the `if let progress = downloadStore.batchProgress { Section(...) { ... } }` block and replace it with: `BatchProgressSection()`

- [ ] **Step 4: Build and verify**

Build Shelv Desktop. Open Settings → Downloads. Trigger a bulk download:
- Confirm the progress bar, counter, and Cancel button appear under "Active Downloads"
- Confirm the tab icons (Recap, Downloads, Cache) do NOT jitter while the download is running
- Confirm the section disappears when the download completes

- [ ] **Step 5: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add "Shelv Desktop/Views/DownloadsTab.swift"
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "fix: isolate download progress observer to stop settings tab icon jitter"
```

---

### Task 4: macOS Sidebar — download progress bar

**Files:**
- Modify: `Shelv Desktop/Views/SidebarView.swift`

**Context:** `downloadsFooter` currently shows either the offline mode indicator or the Downloads-only toggle, but no active download progress. Users must open Settings to see progress or cancel a running bulk download. An isolated `SidebarBatchProgress` sub-view observes `downloadStore` independently so the main `SidebarView` (which handles navigation state) is not affected by download tick updates.

- [ ] **Step 1: Add SidebarBatchProgress struct**

In `SidebarView.swift`, before the `#Preview` block at the bottom of the file, add:

```swift
private struct SidebarBatchProgress: View {
    @ObservedObject private var downloadStore = DownloadStore.shared
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        if let progress = downloadStore.batchProgress {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(themeColor)
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await DownloadService.shared.cancelBatch() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Cancel download", "Download abbrechen"))
                }
                ProgressView(value: progress.fraction)
                    .tint(themeColor)
                    .scaleEffect(y: 0.7, anchor: .center)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
```

- [ ] **Step 2: Insert SidebarBatchProgress in the downloads footer block**

In `SidebarView.body`, find the `if enableDownloads {` block (around line 102):
```swift
if enableDownloads {
    Divider()
    downloadsFooter
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
}
```
Replace with:
```swift
if enableDownloads {
    Divider()
    SidebarBatchProgress()
    downloadsFooter
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
}
```

- [ ] **Step 3: Build and verify**

Build Shelv Desktop. With Downloads enabled, start a bulk download:
- Confirm a compact progress bar with download icon, counter, and cancel (×) button appears in the sidebar footer above the Downloads-only toggle
- Cancel via the × button → bar disappears and download stops
- Download completes normally → bar disappears

- [ ] **Step 4: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add "Shelv Desktop/Views/SidebarView.swift"
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "feat: show active download progress in sidebar"
```

---

### Task 5: macOS Menu Bar — Offline Mode toggle

**Files:**
- Modify: `Shelv Desktop/Shelv_DesktopApp.swift`

**Context:** The View menu (implemented as `CommandGroup(after: .sidebar)`) has toggles for Favorites and Playlists but no offline mode control. Pattern: small View structs for menu items (see `CrossfadeMenuItem`, `LyricsSettingsMenuItem`). `OfflineModeMenuItem` follows the same pattern, observing `OfflineModeService.shared` directly so the toggle reflects live state.

- [ ] **Step 1: Add OfflineModeMenuItem struct**

In `Shelv_DesktopApp.swift`, after the `RecapMenuItem` struct (at the bottom of the file), add:

```swift
struct OfflineModeMenuItem: View {
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("enableDownloads") private var enableDownloads = false

    var body: some View {
        Toggle(
            tr("Offline Mode", "Offline-Modus"),
            isOn: Binding(
                get: { offlineMode.isOffline },
                set: { if $0 { offlineMode.enterOfflineMode() } else { offlineMode.exitOfflineMode() } }
            )
        )
        .disabled(!enableDownloads)
    }
}
```

- [ ] **Step 2: Wire into CommandGroup(after: .sidebar)**

In `Shelv_DesktopApp.body` → `.commands {}`, find the `CommandGroup(after: .sidebar)` block:
```swift
CommandGroup(after: .sidebar) {
    Divider()
    Toggle(isOn: Binding(get: { enableFavorites }, set: { enableFavorites = $0 })) {
        Text(tr("Show Favorites", "Favoriten anzeigen"))
    }
    Toggle(isOn: Binding(get: { enablePlaylists }, set: { enablePlaylists = $0 })) {
        Text(tr("Show Playlists", "Wiedergabelisten anzeigen"))
    }
}
```
Replace with:
```swift
CommandGroup(after: .sidebar) {
    Divider()
    Toggle(isOn: Binding(get: { enableFavorites }, set: { enableFavorites = $0 })) {
        Text(tr("Show Favorites", "Favoriten anzeigen"))
    }
    Toggle(isOn: Binding(get: { enablePlaylists }, set: { enablePlaylists = $0 })) {
        Text(tr("Show Playlists", "Wiedergabelisten anzeigen"))
    }
    Divider()
    OfflineModeMenuItem()
}
```

- [ ] **Step 3: Build and verify**

Build Shelv Desktop. Open the View menu (macOS menu bar):
- "Offline-Modus" toggle appears below a divider after the Playlists toggle
- With Downloads disabled: toggle is greyed out
- With Downloads enabled: toggle is interactive; checking it enters offline mode (sidebar shows wifi.slash indicator), unchecking exits it
- State is reflected correctly if offline mode was set via the sidebar button

- [ ] **Step 4: Commit**

```bash
git -C "/Users/vasco/Repositorys/Shelv Desktop" add "Shelv Desktop/Shelv_DesktopApp.swift"
git -C "/Users/vasco/Repositorys/Shelv Desktop" commit -m "feat: add offline mode toggle to View menu"
```
