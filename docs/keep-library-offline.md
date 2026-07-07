# Keep Library Offline

Keep Library Offline keeps the active Navidrome library downloaded on the device. It is the automatic version of **Download Everything**: instead of using a fixed GB limit once, Shelv checks the library again on app start, server changes, and foreground activation, then downloads whatever is still missing.

It is not the same as **Offline Mode**. Keep Library Offline needs the server and fills the local download library. Offline Mode uses that local library later and stops Shelv from making server requests.

---

## Enabling the feature

Downloads must be enabled first in **Settings -> Downloads**. After that, **Keep Library Offline** appears in the same section on iOS and macOS.

Turning it on opens the bulk download sheet. Shelv calculates the missing songs, shows the estimated size and available storage, and waits for **Start**. If the sheet is closed without starting, the toggle stays off.

The toggle is disabled while Offline Mode is active, because the feature needs a server connection.

Turning it off cancels the current batch, clears the stored storage pause for that server, and hides the low-storage banner. Disabling Downloads also disables Keep Library Offline, exits Offline Mode if needed, cancels active downloads, and removes the local download library.

---

## Automatic checks

Once enabled, Shelv checks the library automatically when:

- The app starts and the active server is prepared
- The active server changes
- The app returns to the foreground
- The macOS app becomes active

Before the check, Shelv waits for restored background download tasks, loads the album list, and reads the current Favorites and Recap settings.

A check does not run when:

- Downloads are disabled
- Keep Library Offline is off for the active server
- Offline Mode is active
- No albums are loaded
- Another Keep Library Offline check is already running

The setting is stored per server ID. Enabling it for one Navidrome server does not enable it for another.

---

## What Gets Downloaded

Keep Library Offline uses the same planner as **Download Everything**, but it does not scan the full library blindly every time.

For normal automatic checks, Shelv only looks at candidate albums:

- Albums without a known `songCount`
- Albums where the local downloaded song count is lower than the album's `songCount`

Albums that already have the expected number of local songs are skipped. This keeps foreground checks cheap.

### Download order

Missing songs are planned in this order:

1. Frequently played albums (`frequent`, up to 20)
2. Recently played albums (`recent`, up to 20)
3. Starred / favourited albums, when Favorites are enabled
4. Recently added albums (`newest`, up to 50)
5. Recap playlists, when Recap is enabled
6. Normal playlists
7. Remaining albums, sorted by artist -> album

Recap playlists only get their own priority bucket when Recap is enabled. If Recap is off, Shelv does not pass those IDs as special Recap units; any playlist returned by the server is handled with the normal playlist group.

Album songs are sorted by disc, track, then title. Playlist songs keep the server order.

Already downloaded songs are skipped. Songs already added earlier in the same plan are not queued twice.

### Size estimates

The planner estimates song size before queueing:

- Download transcoding on: selected download bitrate
- Download transcoding off: song bitrate from the server
- Missing metadata: 192 kbps and 200 seconds

The estimate only decides what fits. The real byte count is saved after the file lands on disk.

---

## Storage Reserve

Keep Library Offline ignores the manual **Max Storage** setting. That setting belongs to **Download Everything**.

Instead, Shelv keeps a 15% free-space reserve:

| Value | Meaning |
|-------|---------|
| Available bytes | Free disk space reported by the system |
| Downloaded bytes | Current Shelv downloads for the active server |
| Managed pool | Available bytes + downloaded bytes |
| Reserve | 15% of the managed pool, rounded up |
| Budget | Available bytes - reserve |

If free-space information is unavailable, the budget is `0`. tvOS does not expose this storage value and does not show Keep Library Offline.

---

## Storage Pauses

Shelv records a storage pause when the plan cannot fit everything inside the 15% reserve, or when a download for a server with Keep Library Offline enabled hits an out-of-space error.

There are two cases:

| Case | Behaviour |
|------|-----------|
| Some songs fit | Shelv downloads the songs that fit and remembers the skipped songs for later. |
| Nothing fits | Status becomes **Paused: not enough storage**, the banner is shown, and no batch starts. |
| Disk fills during download | Status becomes **Paused: not enough storage**, the banner is shown, and the active batch is cancelled. |

The retry rule is deliberately conservative: after a storage pause, Shelv will not try again until free space has improved by at least **1 GB** compared with the stored pause floor. This avoids tiny retry loops where the system frees 30 MB, Shelv plans again, downloads one small file, and immediately lands back in the same storage pause.

Once that 1 GB threshold is reached, the next check can use the newly freed space, still capped by the normal 15% reserve. Until then, automatic checks stay paused instead of re-queuing the same failing plan.

If the disk fills during a download, the next eligible check records the planned song signature before pausing again. That prevents the same batch from being retried immediately without a real storage change.

The low-storage banner is shown when no batch can start or when a running download hits the storage error. Partial plans that still download some songs only remember the skipped songs for later. When the banner appears, it dismisses itself after 5 seconds and can also be closed manually. Clearing the pause, disabling Keep Library Offline, or reaching a clean plan with no skipped songs resets the banner state.

---

## Download Lifecycle

When a plan starts, the status moves from **Checking** to **Downloading** and the planned songs are queued through the normal download pipeline.

Downloads behave like regular Shelv downloads:

- iOS uses a background `URLSession`
- macOS uses a normal `URLSession`
- Up to 5 downloads run at once
- Transcoded downloads run one at a time
- Files are validated before they are moved into the download folder
- Failed downloads retry up to 3 times with backoff
- Transcoded downloads can fall back to raw/original files

Audio files are stored in Application Support under Shelv's download directory, grouped by server ID. Covers and artist/album artwork are saved next to the downloads and indexed for offline playback.

Cancelling the batch removes pending jobs and cancels in-flight jobs. If the user cancels while a Keep Library Offline check is still planning, that run goes back to **Ready** instead of queueing the cancelled plan.

---

## Playlist and Recap Markers

Offline Mode only shows playlists and Recaps that have an offline marker. Keep Library Offline keeps those markers in sync while it plans downloads.

When a playlist is fully covered by already downloaded songs plus songs accepted into the current plan, Shelv marks it as downloaded. Recap playlists are handled before normal playlists, so Recaps can stay visible offline once their songs are local.

Markers include the playlist ID and song IDs. On reload, Shelv removes a marker only when none of its saved songs are still local. A partially downloaded playlist keeps its marker, so the UI can still offer the remaining songs.

iOS stores playlist markers in `UserDefaults` and protects a newly marked playlist until at least one of its saved songs is local. macOS stores downloaded playlist IDs in the download database, keeps playlist song IDs in `UserDefaults`, and protects the marker while the database write is still pending.

---

## Offline Mode

Keep Library Offline never runs while Offline Mode is active. It needs the server for album details, playlists, artwork, and download URLs.

Offline Mode uses the result:

- The library shows only downloaded albums and artists
- Playlists and Recaps are filtered by offline markers
- Playback uses the local download database
- Server-only actions are hidden or skipped

Leaving Offline Mode does not change the Keep Library Offline toggle. If it is enabled, the next normal check can continue downloading missing content.

---

## Status Reference

| Status | Meaning |
|--------|---------|
| Inactive | Off for the active server |
| Ready | Enabled and waiting for the next check |
| Checking | Building a plan |
| Downloading | Planned songs are queued or running |
| Nothing to do | Nothing new is missing in the current scope |
| Paused: not enough storage | Storage reserve or disk capacity stopped the run |
| Failed | Service error text |

---

## Settings Reference

| Setting | Effect |
|---------|--------|
| Enable Downloads | Required before Keep Library Offline can be used. |
| Keep Library Offline | Turns on automatic missing-library downloads for the active server. |
| Offline Mode | Blocks Keep Library Offline checks because server access is disabled. |
| Download format / bitrate | Controls the files saved by Keep Library Offline. |
| Favorites | Adds starred/favourited albums to the priority order. |
| Recap | Adds Recap playlists to the priority order and offline marker handling. |
| Max Storage | Used by Download Everything only. Keep Library Offline uses the 15% reserve. |
| Delete All Downloads | Clears downloaded files and playlist markers, and cancels active downloads. |

---

## Critical Invariants

- The setting is per server.
- Checks never run in Offline Mode.
- Only one check runs at a time.
- The planner keeps the 15% storage reserve.
- A storage pause needs at least **1 GB** more free space before retrying.
- Already downloaded or already planned songs are not queued twice.
- Playlist markers are kept only while at least one saved song is local, except during the short protected window for newly planned playlists.
- Normal automatic checks use album `songCount` to avoid fetching every album detail again.
