# Pre-Cache & Gapless Playback

## Overview

Shelv preloads the next song in the background so it is ready immediately — either for a fast skip or a seamless transition (gapless). The logic runs in two phases, triggered every 0.5 s by the time observer in `AudioPlayerService`.

---

## Prefetch — 5 s after song start

5 seconds into a song, `checkGaplessTrigger` starts downloading the next song in the background via `StreamCacheService`. By the time the current song ends, the file is already on disk.

| Situation | Behaviour |
|-----------|-----------|
| Transcoded remote stream | `StreamCacheService.prefetch()` starts immediately (no toggle needed) |
| Raw remote stream + `streamPreCacheEnabled = true` | `StreamCacheService.prefetch()` starts |
| Raw remote stream + `streamPreCacheEnabled = false` | Nothing — AVPlayer will stream directly later |
| Local file (downloaded) | Nothing needed — file already on disk |

The `prefetchScheduled` flag prevents the prefetch from starting more than once per song. On track change (skip, stop) the cache for the no-longer-needed song is cancelled and the temp file deleted.

Two conditions skip the entire block:
- Song duration ≤ 11 s — too short to prefetch meaningfully
- `repeatMode == .one` with an empty `playNextQueue` — no next song to preload

---

## StreamCacheService

`StreamCacheService` (Swift `actor`) manages temporary files under `FileManager.temporaryDirectory`:

- File name: `shelv_stream_<songId>.<ext>` (e.g. `shelv_stream_abc123.opus`)
- 3 download attempts with 1 s pause between them; no retry on timeout
- Already running or completed caches are not started twice (`prefetch()` is idempotent)
- `cancel(songId:)` cancels the task and deletes the temp file
- `cleanupOldFiles()` removes stale `shelv_stream_*` files on app launch

---

## Gapless Preload — 10 s before end

When `gaplessEnabled = true` and `currentTime >= duration - 10`, the cached file (already downloaded since the 5 s mark) is handed to `AVQueuePlayer` via `engine.preloadForGapless(url:)`.

| Situation | Behaviour |
|-----------|-----------|
| Local file (downloaded or stream cache ready) | `engine.preloadForGapless(url:)` immediately |
| Transcoded stream (cache still in progress) | Poll every 200 ms, up to 8 s; hand off once ready |
| Raw remote stream + `streamPreCacheEnabled = true` | Same — waits for the completed cache file |
| Raw remote stream + `streamPreCacheEnabled = false` | Remote URL handed directly to AVQueuePlayer — best-effort, gap possible |

If the cache is not ready within 8 s, all flags are reset and no gapless swap is triggered — the transition falls back to the normal `next()` path.

---

## Current Song Playback (startPlayback)

The same cache logic applies when starting the current song:

1. **Transcoded stream** — stop engine, call `StreamCacheService.prefetch()`, poll every 200 ms (up to 60 s), play from local file. Timeout fallback: raw stream URL directly.
2. **Raw remote stream + `streamPreCacheEnabled = true`** — same as above, no codec change.
3. **Local file or raw stream (no pre-cache)** — URL handed to AVPlayer directly.

---

## Toggles

| AppStorage key | Default | Effect |
|----------------|---------|--------|
| `transcodingEnabled` | `false` | Enables server-side transcoding; pre-cache always runs in this mode |
| `streamPreCacheEnabled` | `false` | Pre-cache for raw remote streams; required for reliable gapless without transcoding |
| `gaplessEnabled` | `false` | Activates the gapless preload in Phase 2 |

> **Gapless with RAW files:** `gaplessEnabled` alone is not enough. AVPlayer reinitialises internally for a remote URL and produces a small gap. With `streamPreCacheEnabled = true`, gapless waits for the completed local file and hands that to AVQueuePlayer — making the transition truly seamless.

---

## Trade-offs

### Transcoded stream (pre-cache always active)

| Pros | Cons |
|------|------|
| Gapless works reliably | Entire song downloaded before playback starts → higher initial latency |
| Precise duration via `AVURLAsset.load(.duration)` | Higher data usage — full file downloaded upfront |
| No AVPlayer buffer stall on slow connections | Requires free space in the temp directory |

### Raw stream + `streamPreCacheEnabled`

| Pros | Cons |
|------|------|
| Gapless works for RAW files too | Toggle must be explicitly enabled |
| Skip to next song is instant (file already cached) | Same storage and latency trade-offs as above |

### No pre-cache (default raw stream)

| Pros | Cons |
|------|------|
| No extra download, minimal data usage | Gapless is best-effort only (AVPlayer gets a remote URL) |
| Playback starts immediately | Small gap between songs possible |

---

## Critical Invariants

- `prefetchScheduled` and `gaplessPreloadTriggered` are reset on every song start and stop — no state leaks between tracks.
- `prefetchedSongId` ensures the correct cache is cancelled on skip.
- The gapless swap only fires when `peekNextSong()?.id == gaplessPreloadSong?.id` — queue changes inside the preload window are handled correctly.
