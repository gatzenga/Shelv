# Background Task Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap song downloads and lyrics bulk-download in BGContinuedProcessingTask (iOS 26) resp. BGProcessingTask (iOS 18) so they complete reliably even when the user backgrounds the app.

**Architecture:** A new `BackgroundTaskService` registers all BGTask identifiers at app launch and provides a submission helper with `#available` branching. DownloadService and LyricsStore delegate their long-running work through this service. The underlying network transfers for songs continue to use Background-URLSession (already fixed); the BGTask wrapper ensures the app has runtime to process completions and write to SQLite.

**Tech Stack:** Swift, BackgroundTasks framework (`BGContinuedProcessingTask` iOS 26+, `BGProcessingTask` iOS 13+), existing DownloadService actor, existing LyricsStore `@MainActor`.

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `Info.plist` | Add `processing` UIBackgroundMode + BGTaskSchedulerPermittedIdentifiers |
| Modify | `Shelv/ShelvApp.swift` | Register BGTask identifiers in `application(_:didFinishLaunchingWithOptions:)` |
| Create | `Shelv/Services/BackgroundTaskService.swift` | Submit helper with `#available` branching |
| Modify | `Shelv/Services/DownloadService.swift` | Start/end BGTask around batch lifecycle |
| Modify | `Shelv/ViewModels/LyricsStore.swift` | Wrap `startBulkDownload` work in BGTask |

---

## Task 1: Info.plist — Background modes + task identifiers

**Files:**
- Modify: `Info.plist`

- [ ] **Step 1: Add `processing` to UIBackgroundModes**

In `Info.plist`, find the existing `UIBackgroundModes` array (currently contains `audio`) and add `processing`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>processing</string>
</array>
```

- [ ] **Step 2: Add BGTaskSchedulerPermittedIdentifiers**

Directly after the `UIBackgroundModes` block, add:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>ch.vkugler.Shelv.download</string>
    <string>ch.vkugler.Shelv.lyrics</string>
</array>
```

- [ ] **Step 3: Build and confirm no errors**

```bash
xcodebuild -scheme Shelv -destination "generic/platform=iOS Simulator" -quiet 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Info.plist
git commit -m "config: add background processing mode and BGTask identifiers"
```

---

## Task 2: BackgroundTaskService

**Files:**
- Create: `Shelv/Services/BackgroundTaskService.swift`

This service is the single place that knows about BGTask identifiers and handles `#available` branching. DownloadService and LyricsStore call it to run work under a background task.

- [ ] **Step 1: Create the file**

```swift
import BackgroundTasks

actor BackgroundTaskService {
    static let shared = BackgroundTaskService()

    static let downloadIdentifier = "ch.vkugler.Shelv.download"
    static let lyricsIdentifier   = "ch.vkugler.Shelv.lyrics"

    // MARK: - Submission

    /// Runs `work` under a BGContinuedProcessingTask (iOS 26+) or BGProcessingTask (iOS 18).
    /// `work` receives a Progress object to update and a cancellation flag to check.
    /// Call this from the foreground in response to a user action.
    func runWithBackgroundTask(
        identifier: String,
        title: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        if #available(iOS 26, *) {
            runContinued(identifier: identifier, title: title, work: work)
        } else {
            runProcessing(identifier: identifier, work: work)
        }
    }

    // MARK: - iOS 26

    @available(iOS 26, *)
    private func runContinued(
        identifier: String,
        title: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: ""
        )
        try? BGTaskScheduler.shared.submit(request)
        // Registered handler (see AppDelegate) will call the stored work closure.
        storeWork(identifier: identifier, work: work)
    }

    // MARK: - iOS 18

    private func runProcessing(
        identifier: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
        storeWork(identifier: identifier, work: work)
    }

    // MARK: - Work storage (bridges submission → handler)

    private var pendingWork: [String: (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void] = [:]

    func storeWork(
        identifier: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        pendingWork[identifier] = work
    }

    func handleBGTask(_ bgTask: BGTask) {
        guard let work = pendingWork[bgTask.identifier] else {
            bgTask.setTaskCompleted(success: false)
            return
        }
        pendingWork.removeValue(forKey: bgTask.identifier)

        var cancelled = false
        bgTask.expirationHandler = { cancelled = true }

        let progress = Progress(totalUnitCount: 100)

        // For BGContinuedProcessingTask, set task.progress (iOS 26 only)
        if #available(iOS 26, *), let continuedTask = bgTask as? BGContinuedProcessingTask {
            continuedTask.progress.addChild(progress, withPendingUnitCount: 100)
        }

        Task {
            await work(progress) { cancelled }
            bgTask.setTaskCompleted(success: !cancelled)
        }
    }
}
```

- [ ] **Step 2: Build and confirm no errors**

```bash
xcodebuild -scheme Shelv -destination "generic/platform=iOS Simulator" -quiet 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Shelv/Services/BackgroundTaskService.swift
git commit -m "feat: add BackgroundTaskService with iOS 26/18 branching"
```

---

## Task 3: Register identifiers at app launch

**Files:**
- Modify: `Shelv/ShelvApp.swift`

BGTask identifiers MUST be registered before `applicationDidFinishLaunching` returns. The existing `AppDelegate` in `ShelvApp.swift` only handles `handleEventsForBackgroundURLSession`. We add `application(_:didFinishLaunchingWithOptions:)` here.

- [ ] **Step 1: Add import and registration to AppDelegate**

In `ShelvApp.swift`, add `import BackgroundTasks` at the top, then add the new method to `AppDelegate`:

```swift
import BackgroundTasks  // add at top of file
```

Inside `final class AppDelegate: NSObject, UIApplicationDelegate {`, add after the existing method:

```swift
func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: BackgroundTaskService.downloadIdentifier,
        using: nil
    ) { task in
        Task { await BackgroundTaskService.shared.handleBGTask(task) }
    }
    BGTaskScheduler.shared.register(
        forTaskWithIdentifier: BackgroundTaskService.lyricsIdentifier,
        using: nil
    ) { task in
        Task { await BackgroundTaskService.shared.handleBGTask(task) }
    }
    return true
}
```

- [ ] **Step 2: Build and confirm no errors**

```bash
xcodebuild -scheme Shelv -destination "generic/platform=iOS Simulator" -quiet 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Shelv/ShelvApp.swift
git commit -m "feat: register BGTask identifiers at app launch"
```

---

## Task 4: DownloadService — BGTask lifecycle around batch

**Files:**
- Modify: `Shelv/Services/DownloadService.swift`

The BGTask should be active as long as a download batch is running. It starts when the first songs are enqueued into a new batch, and ends when the batch completes (all songs done/failed/cancelled).

- [ ] **Step 1: Add batch BGTask start to `incrementBatchTotal`**

Find `private func incrementBatchTotal(by count: Int)` (or wherever `batchTotal` is first incremented for a new batch). Add the background task submission when a fresh batch begins (i.e. when `batchTotal` goes from 0 to > 0):

Locate the `incrementBatchTotal` function:

```swift
private func incrementBatchTotal(by count: Int) {
    let wasIdle = batchTotal == 0
    batchTotal += count
    publishBatch()
    if wasIdle {
        Task {
            await BackgroundTaskService.shared.runWithBackgroundTask(
                identifier: BackgroundTaskService.downloadIdentifier,
                title: String(localized: "downloading")
            ) { [weak self] progress, isCancelled in
                await self?.waitForBatchCompletion(progress: progress, isCancelled: isCancelled)
            }
        }
    }
}
```

- [ ] **Step 2: Add `waitForBatchCompletion` helper to DownloadService**

This method polls until the batch is done or the task is cancelled. Add it inside `actor DownloadService`:

```swift
private func waitForBatchCompletion(
    progress: Progress,
    isCancelled: @escaping () -> Bool
) async {
    while batchTotal > 0 && !isCancelled() {
        let completed = batchCompleted + batchFailed
        let total = batchTotal
        if total > 0 {
            progress.completedUnitCount = Int64(Double(completed) / Double(total) * 100)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s poll
    }
    progress.completedUnitCount = 100
}
```

- [ ] **Step 3: Build and confirm no errors**

```bash
xcodebuild -scheme Shelv -destination "generic/platform=iOS Simulator" -quiet 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Shelv/Services/DownloadService.swift
git commit -m "feat: wrap download batch in BGTask for background reliability"
```

---

## Task 5: LyricsStore — BGTask around bulk download

**Files:**
- Modify: `Shelv/ViewModels/LyricsStore.swift`

The existing `startBulkDownload()` uses `Task.detached`. We wrap this in a BGTask so iOS keeps the app alive for the duration.

- [ ] **Step 1: Add import BackgroundTasks**

At the top of `LyricsStore.swift`:

```swift
import BackgroundTasks
```

- [ ] **Step 2: Replace the Task.detached in `startBulkDownload` with BGTask submission**

Replace the `downloadTask = Task.detached(priority: .utility) { ... }` block in `startBulkDownload(serverId:)` with:

```swift
func startBulkDownload(serverId: String) {
    guard !isDownloading else { return }
    isDownloading = true
    downloadFetched = 0
    downloadTotal = 0
    currentDownloadServerId = serverId

    Task {
        await BackgroundTaskService.shared.runWithBackgroundTask(
            identifier: BackgroundTaskService.lyricsIdentifier,
            title: String(localized: "downloading_lyrics")
        ) { [weak self] progress, isCancelled in
            await self?.runBulkDownloadWork(
                serverId: serverId,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }
}
```

- [ ] **Step 3: Extract work into `runBulkDownloadWork`**

Move the existing `Task.detached` body into a new method. Replace the old body exactly — do not change the download logic itself, only lift it into a named method that accepts `progress` and `isCancelled`:

```swift
private func runBulkDownloadWork(
    serverId: String,
    progress: Progress,
    isCancelled: @escaping () -> Bool
) async {
    defer {
        Task { @MainActor [weak self] in
            self?.isDownloading = false
            self?.refreshDbSize()
            Task { await self?.refreshFetchedCount(serverId: serverId) }
        }
    }

    let api = SubsonicAPIService.shared
    let svc = LyricsService.shared

    var albums: [Album] = []
    var offset = 0
    let pageSize = 500
    while true {
        guard !isCancelled() else { return }
        guard let page = try? await api.getAllAlbums(size: pageSize, offset: offset) else { break }
        albums.append(contentsOf: page)
        if page.count < pageSize { break }
        offset += pageSize
    }
    guard !isCancelled() else { return }

    let allSongs: [Song] = await withTaskGroup(of: [Song].self) { group -> [Song] in
        let maxConcurrent = 10
        var iterator = albums.makeIterator()
        var active = 0
        while active < maxConcurrent, let album = iterator.next() {
            group.addTask { (try? await api.getAlbum(id: album.id))?.song ?? [] }
            active += 1
        }
        var collected: [Song] = []
        while let songs = await group.next() {
            collected.append(contentsOf: songs)
            if let next = iterator.next() {
                group.addTask { (try? await api.getAlbum(id: next.id))?.song ?? [] }
            }
        }
        return collected
    }
    guard !isCancelled() else { return }

    let totalCount = allSongs.count
    await MainActor.run { [weak self] in
        self?.downloadTotal = totalCount
        progress.totalUnitCount = Int64(totalCount)
    }

    await withTaskGroup(of: Void.self) { group in
        let maxConcurrent = 5
        var iterator = allSongs.makeIterator()
        var active = 0
        while active < maxConcurrent, let song = iterator.next() {
            group.addTask { _ = await svc.fetchAndSave(song: song, serverId: serverId) }
            active += 1
        }
        var fetched = 0
        var lastPublished = Date.distantPast
        while await group.next() != nil {
            if isCancelled() { group.cancelAll(); return }
            fetched += 1
            progress.completedUnitCount = Int64(fetched)
            let now = Date()
            if now.timeIntervalSince(lastPublished) >= 0.5 {
                lastPublished = now
                let f = fetched
                await MainActor.run { [weak self] in self?.downloadFetched = f }
            }
            if let next = iterator.next() {
                group.addTask { _ = await svc.fetchAndSave(song: next, serverId: serverId) }
            }
        }
        let finalCount = fetched
        await MainActor.run { [weak self] in self?.downloadFetched = finalCount }
    }
}
```

- [ ] **Step 4: Update `cancelBulkDownload` to also cancel the BGTask**

`cancelBulkDownload` previously cancelled a `Task`. Now the work runs inside the BGTask handler. We cancel the stored BGTask work by removing it, and cancel the underlying BGTask:

```swift
func cancelBulkDownload() {
    downloadTask?.cancel()
    downloadTask = nil
    isDownloading = false
    Task {
        await BackgroundTaskService.shared.cancelTask(
            identifier: BackgroundTaskService.lyricsIdentifier
        )
    }
    if let sid = currentDownloadServerId {
        Task { await self.refreshFetchedCount(serverId: sid) }
    }
}
```

- [ ] **Step 5: Add `cancelTask` to BackgroundTaskService**

In `BackgroundTaskService.swift`, add:

```swift
func cancelTask(identifier: String) {
    pendingWork.removeValue(forKey: identifier)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
}
```

- [ ] **Step 6: Add localisation key `downloading_lyrics`**

In `en.lproj/Localizable.strings`:
```
"downloading_lyrics" = "Downloading Lyrics";
```

In `de.lproj/Localizable.strings`:
```
"downloading_lyrics" = "Texte laden";
```

- [ ] **Step 7: Build and confirm no errors**

```bash
xcodebuild -scheme Shelv -destination "generic/platform=iOS Simulator" -quiet 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add Shelv/ViewModels/LyricsStore.swift Shelv/Services/BackgroundTaskService.swift Shelv/en.lproj/Localizable.strings Shelv/de.lproj/Localizable.strings
git commit -m "feat: wrap lyrics bulk download in BGTask for background reliability"
```

---

## Task 6: Add `downloading` localisation key (DownloadService)

**Files:**
- Modify: `Shelv/en.lproj/Localizable.strings`
- Modify: `Shelv/de.lproj/Localizable.strings`

- [ ] **Step 1: Add key in en.lproj**

```
"downloading" = "Downloading";
```

- [ ] **Step 2: Add key in de.lproj**

```
"downloading" = "Laden";
```

- [ ] **Step 3: Commit**

```bash
git add Shelv/en.lproj/Localizable.strings Shelv/de.lproj/Localizable.strings
git commit -m "i18n: add downloading localisation key"
```

---

## Self-Review

**Spec coverage:**
- ✅ iOS 26: BGContinuedProcessingTask for song downloads + lyrics
- ✅ iOS 18: BGProcessingTask for song downloads + lyrics  
- ✅ `#available(iOS 26, *)` branching
- ✅ Info.plist registrations
- ✅ Registration at app launch before `didFinishLaunching` returns
- ✅ Progress reporting
- ✅ Expiration/cancellation handling
- ✅ Localisation keys

**Notes:**
- BGProcessingTask on iOS 18 does not start immediately — iOS schedules it when resources are available (often when plugged in). Song downloads via Background-URLSession continue to work independently; the BGTask gives the app extra runtime to process completions and DB writes.
- On iOS 26, BGContinuedProcessingTask starts immediately in the foreground and shows a Live Activity automatically.
- `cancelBulkDownload` removes pending work from BackgroundTaskService so an already-queued BGProcessingTask does nothing when iOS eventually runs it.
