# Pre-Cache & Gapless Playback

## Overview

Shelv preloads a sliding window of upcoming songs in the background so they are ready immediately — either for a fast skip or a seamless transition (gapless). The current song is cached before playback when required; upcoming songs are filled from the 5 s playback marker via the 0.5 s time observer in `AudioPlayerService`.

---

## Prefetch Window

Once the current song reaches the 5 s playback marker, `AudioPlayerService` fills a managed stream-cache window via `StreamCacheService`. Downloads outside the current window are cancelled and removed.

| Situation | Behaviour |
|-----------|-----------|
| Transcoded remote stream + `streamPreCacheEnabled = false` | Current song is cached before playback; 1 upcoming transcoded song is cached after the 5 s marker |
| Transcoded remote stream + `streamPreCacheEnabled = true` | Current song is cached before playback; the selected upcoming count is cached after the 5 s marker |
| Raw remote stream + `streamPreCacheEnabled = true` | Current song is cached before playback; the selected upcoming count is cached after the 5 s marker |
| Raw remote stream + `streamPreCacheEnabled = false` | No upcoming cache — AVPlayer will stream directly later |
| Network becomes unavailable | No new prefetch jobs start; completed files in the logical cache window stay available and missing jobs resume after reconnect |
| Local file (downloaded) | Nothing needed — file already on disk |

The managed cache window prevents the same song from being started twice and keeps the current song plus the relevant upcoming songs alive. On track change (skip, stop) cache files outside the window are cancelled and deleted; newly needed upcoming songs are added when the new current song reaches the 5 s marker.

Two conditions skip the entire block:
- Song duration ≤ 11 s — too short to prefetch meaningfully
- `repeatMode == .one` with an empty `playNextQueue` — no next song to preload

---

## StreamCacheService

`StreamCacheService` (Swift `actor`) manages temporary files under `FileManager.temporaryDirectory`:

- File name: `shelv_stream_<songId>.<ext>` (e.g. `shelv_stream_abc123.opus`)
- 3 download attempts with 1 s pause between them; no retry on timeout
- Already running or completed caches are not started twice (`prefetch()` is idempotent)
- Window preloads are run sequentially to avoid starting multiple full-song downloads at once
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
| `transcodingEnabled` | `false` | Settings → Playback. Enables server-side transcoding; pre-cache always runs in this mode |
| `streamPreCacheEnabled` | `false` | Settings → Cache. Pre-cache for raw remote streams; required for reliable gapless without transcoding |
| `streamPreCacheAheadCount` | `1` | Settings → Cache. Number of upcoming songs to keep cached when pre-cache is enabled (`1` through `5`) |
| `gaplessEnabled` | `false` | Settings → Playback. Activates the gapless preload in Phase 2 |

> **Gapless with RAW files:** `gaplessEnabled` alone is not enough. AVPlayer reinitialises internally for a remote URL and produces a small gap. With `streamPreCacheEnabled = true`, gapless waits for the completed local file and hands that to AVQueuePlayer — making the transition truly seamless.

---

## Trade-offs

### Transcoded stream (pre-cache always active for current song)

| Pros | Cons |
|------|------|
| Gapless works reliably | Entire current song downloaded before playback starts → higher initial latency |
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

- `managedStreamCacheSongIds` and `gaplessPreloadTriggered` are reset or trimmed on every song start and stop — no state leaks between tracks.
- The cache window ensures the correct cache files are retained or cancelled on skip.
- Retention is based on the logical queue window, not on whether new network jobs can currently be scheduled; losing connectivity must never collapse a populated window.
- The gapless swap only fires when `peekNextSong()?.id == gaplessPreloadSong?.id` — queue changes inside the preload window are handled correctly.
