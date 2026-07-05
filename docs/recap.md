# Shelv Recap

Recap automatically creates playlists of your most-played songs — weekly, monthly, and yearly. With iCloud Play History sync enabled, your listening history stays in sync across all your devices.

---

## How it works

### Tracking what you listen to

Shelv watches how much of each song you actually listen to. When a song ends or you skip to the next one, Shelv checks whether you heard enough of it to count. "Enough" is configurable in Settings → Playback → Scrobble — the default is 30%, adjustable between 10% and 50%.

If the threshold is met, the play is recorded locally in a small database on your device. This database stores:

- **Which song** was played (by its ID on the Navidrome server)
- **Which account and server** the play belongs to (so plays from different Navidrome servers don't mix)
- **When** it was played (timestamp)
- **How long** the song is

Tracking only runs while playback is active — seeking forward doesn't inflate the count, and pausing doesn't break the accumulation.

### Syncing between devices via iCloud

When global iCloud sync and the Play History sync category are enabled, every recorded play is uploaded to iCloud. If you're offline, it queues the upload and retries as soon as the network is available again.

When you open the app on another device — or switch back to it — Shelv downloads any new plays from iCloud that it hasn't seen yet. This means that even if you listened on your iPhone while offline and only connected later, those plays will eventually appear on your Mac and vice versa, as long as Play History sync is enabled on those devices.

The sync uses iCloud's private database, so your listening history is only visible to you and your own devices.

#### iCloud Sync toggle

You can disable iCloud sync in Settings → iCloud. The page has a global iCloud Sync toggle and separate categories for Play History, Recap, Lyrics Server, and Radio Stations.

When the global toggle is off:

- Plays stay only on this device
- No enabled iCloud categories upload or download records
- Multiple devices can create independent Recap playlists with the same name
- Backups must be handled manually via export/import

When only Play History is off, plays stay local but Recap markers can still sync if the Recap category is on. When only Recap is off, listening history can still sync but Recap playlist markers and shared retention settings stay local, so multiple devices may create duplicate Recap playlists.

When turning the global iCloud Sync toggle back on, Shelv treats the local database as the source of truth: it deletes the Shelv iCloud zone, marks local plays and recap markers for re-upload, then uploads the local state again. Other devices recover from the missing zone on their next sync and re-upload their local state as well. This avoids adopting stale recap markers from periods where sync was disabled. Changing individual sync categories does not purge the zone.

#### Cross-device identity

For plays to be correctly attributed across devices, Shelv links each server connection to a stable user ID from your Navidrome account. This ID is fetched once when you add the server and stored alongside your credentials. Devices that connect to the same Navidrome account with the same user will share a unified play history.

---

## Recap generation

### When a Recap is created

After a period ends (week, month, or year), Shelv waits a short grace period before generating the Recap — this gives devices that were offline time to sync their plays before the top list is finalised. The grace period is 6 hours for weekly, monthly, and yearly Recaps.

Once the grace period has passed, Shelv generates the Recap on the next app start or sync cycle.

### What the Recap contains

Shelv counts how many times each song was played during the period and picks the top songs — up to 25 songs for weekly Recaps, and up to 50 for monthly and yearly ones. The songs are ranked by play count.

This top list is then created as a playlist directly on your Navidrome server, named after the period (e.g. *Mai 2025* or *2.–8. Jun 2025*). The playlist is tagged with the comment `Shelv Recap` so it can be identified later.

The Recap is a **snapshot** at creation time — adding more plays later (for example by syncing an offline device that had plays for the same period) doesn't change an existing Recap playlist. Use the *Sync with Navidrome* button if you want to re-align an existing Recap with your current play counts.

### Avoiding duplicate Recaps across devices

When a Recap playlist is created and Recap sync is enabled, a marker is written to iCloud. If another device tries to generate the same Recap — because it synced the plays too — it sees the marker and uses the existing playlist instead of creating a duplicate. If there's a race condition and both devices create a playlist at the same moment, the one that "loses" deletes its own playlist and adopts the other's.

### Retention

Shelv keeps a configurable number of Recaps per period type. Once the limit is exceeded, the oldest Recap — its Navidrome playlist, its local registry entry, and its iCloud marker — is deleted automatically. The default limits are:

| Period | Default |
|--------|---------|
| Weekly | 1 |
| Monthly | 12 |
| Yearly | 3 |

You can change these limits in Recap Settings. Retention changes are synced through iCloud when the Recap sync category is enabled.

### Missing playlists

If you delete a Recap playlist directly on your Navidrome server (for example through the web interface), Shelv does not automatically delete the local registry entry or iCloud marker. The UI marks the entry as missing, and you can decide whether to recreate the playlist, update it, or remove only the registry entry. This avoids accidental delete cascades caused by temporary server/API failures.

---

## Sync with Navidrome

The *Sync with Navidrome* button checks whether the Recap playlists in Shelv's local database still match what's actually on the Navidrome server. This is useful if:

- You manually edited a Recap playlist on Navidrome (renamed it, reordered songs)
- You want to re-align a Recap's song list with your current play counts after merging histories from multiple devices

For each Recap in the local registry, Shelv fetches the corresponding playlist from Navidrome and compares:

- **Name** — does the playlist still have the expected name?
- **Comment** — is the `Shelv Recap` comment present?
- **Songs** — are all expected songs present, and no unexpected ones?
- **Order** — are the songs in the correct order (ranked by play count)?

If any discrepancy is found, it's shown in a list. For each affected playlist you can choose:

- **Apply** — update the existing playlist to match what the database expects (corrects name, comment, adds missing songs, removes extra ones, restores order)
- **Create new** — leave the existing playlist untouched and create a fresh one that matches the database exactly

If a playlist has been deleted from Navidrome entirely, only *Create new* is offered.

This is a manual tool only — it is not triggered automatically by any other operation.

---

## Managing data

Beyond the main settings, Shelv splits Recap-related tools across Recap Settings, Database, and iCloud.

### Recap Settings

Recap Settings contains:

- **Periods** — enable or disable weekly, monthly, and yearly Recaps, and choose how many playlists to keep for each period type.
- **Registry** — all active Recap playlist entries, with per-entry delete (deletes the Navidrome playlist + local entry + iCloud marker).
- **Recap log** — generation/debug output for automatic and manual Recap creation.
- **Autogen markers** — shows which recent periods are already marked as processed.
- **Sync with Navidrome** — opens the manual verification tool described above.
- **Advanced** — test and reset tools for Recap generation.

### Advanced

- **Generate test recap** — creates a test weekly Recap for the current calendar week so far. Useful for testing the end-to-end flow.
- **Reset latest weekly/monthly/yearly Recap** — deletes the newest playlist, local registry entry, and iCloud marker for that period type, and clears its processed marker so it can be generated again later.

### Database

Settings → Database contains:

- **Export database** and **Import database** — file-based backup and restore for the local play log database.
- **Recent plays** — the last 100 plays, with per-entry delete. Useful for spot-checking what's being counted.
- **Database errors** — local database error log.
- **Database cleanup** — checks logged songs against the server and removes entries for songs that definitely no longer exist.
- **Reset local database** — clears only the local play log and local Recap registry for the current server. Nothing on iCloud or Navidrome is touched. On the next sync, the local database can be re-filled from iCloud if sync is enabled.
- **Delete iCloud data** — wipes the Shelv iCloud zone, keeps local databases and Navidrome playlists intact, and marks local data for re-upload.
- **Delete everything** — removes Navidrome Recap playlists known to this device, the local play log, the local Recap registry, local scrobbles, and the Shelv iCloud zone. Other devices may still have local plays and can re-upload them on their next sync, so this is not a cross-device wipe unless repeated everywhere.

### iCloud

Settings → iCloud contains the global iCloud Sync toggle, per-category sync toggles, manual Sync Now, pending upload count, and the verbose Sync log.

---

## Settings reference

| Setting | Description |
|---------|-------------|
| Recap enabled | Master switch for Recap playlist generation and Recap UI. Play logging and scrobbling still run because mixes, insights, and sync also consume the play log. |
| iCloud Sync | Global iCloud switch in Settings → iCloud. When off, all iCloud-backed categories stay local. |
| Play History Sync | Category toggle in Settings → iCloud. Enables automatic sync of play log records. |
| Recap Sync | Category toggle in Settings → iCloud. Enables sync of Recap markers and shared retention settings. |
| Play threshold | How much of a song must be heard for it to count (10–50%), configured in Settings → Playback → Scrobble. |
| Weekly Recap | Generates a playlist for each completed calendar week (Monday–Sunday). |
| Monthly Recap | Generates a playlist for each completed calendar month. |
| Yearly Recap | Generates a playlist for each completed calendar year. |
| Weekly retention | How many weekly Recap playlists to keep. |
| Monthly retention | How many monthly Recap playlists to keep. |
| Yearly retention | How many yearly Recap playlists to keep. |

---

## Database import and export

Shelv can export its local play log database as a file and import it on another device. This is useful when setting up a new device and you want to bring your full history along without waiting for iCloud sync to deliver everything, or for keeping a local backup independent of iCloud.

### On import

Shelv replaces the local database with the imported one, then automatically:

1. Rewrites all entries to belong to the currently active server account
2. Uploads any plays that iCloud doesn't have yet
3. Downloads any plays from iCloud that weren't in the imported database
4. Checks registry entries against Navidrome and automatically recreates missing Recap playlists when the imported play log still has enough data for them

Existing Navidrome playlists are not deleted during import. If the backup contains plays from a different Navidrome account, they're reassigned to the current account, since the intention of importing is always to bring your history to the current user.
