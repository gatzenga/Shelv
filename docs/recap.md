# Shelv Recap

Recap automatically creates playlists of your most-played songs — weekly, monthly, and yearly. With iCloud sync enabled, your listening history stays in sync across all your devices.

---

## How it works

### Tracking what you listen to

Shelv watches how much of each song you actually listen to. When a song ends or you skip to the next one, Shelv checks whether you heard enough of it to count. "Enough" is configurable — the default is 30%, but you can adjust this in Settings between 10% and 50%.

If the threshold is met, the play is recorded locally in a small database on your device. This database stores:

- **Which song** was played (by its ID on the Navidrome server)
- **Which account and server** the play belongs to (so plays from different Navidrome servers don't mix)
- **When** it was played (timestamp)
- **How long** the song is

Tracking only runs while playback is active — seeking forward doesn't inflate the count, and pausing doesn't break the accumulation.

### Syncing between devices via iCloud

When iCloud sync is enabled, every recorded play is immediately uploaded to iCloud. If you're offline, it queues the upload and retries as soon as the network is available again.

When you open the app on another device — or switch back to it — Shelv downloads any new plays from iCloud that it hasn't seen yet. This means that even if you listened on your iPhone while offline and only connected later, those plays will eventually appear on your Mac and vice versa.

The sync uses iCloud's private database, so your listening history is only visible to you and your own devices.

#### iCloud Sync toggle

You can disable iCloud sync in Settings → Recap. When off:

- Plays stay only on this device
- No records are uploaded or downloaded
- Multiple devices can create independent Recap playlists with the same name
- Backups must be handled manually via export/import

When turning iCloud sync back on, Shelv merges the local database with iCloud (pending plays go up, missing records come down). Nothing is deleted automatically.

#### Cross-device identity

For plays to be correctly attributed across devices, Shelv links each server connection to a stable user ID from your Navidrome account. This ID is fetched once when you add the server and stored alongside your credentials. Devices that connect to the same Navidrome account with the same user will share a unified play history.

---

## Recap generation

### When a Recap is created

After a period ends (week, month, or year), Shelv waits a short grace period before generating the Recap — this gives devices that were offline time to sync their plays before the top list is finalised. The grace period is 24 hours for weekly, 48 hours for monthly, and 96 hours for yearly Recaps.

Once the grace period has passed, Shelv generates the Recap on the next app start or sync cycle.

### What the Recap contains

Shelv counts how many times each song was played during the period and picks the top songs — up to 25 songs for weekly Recaps, and up to 50 for monthly and yearly ones. The songs are ranked by play count.

This top list is then created as a playlist directly on your Navidrome server, named after the period (e.g. *Mai 2025* or *2.–8. Jun 2025*). The playlist is tagged with the comment `Shelv Recap` so it can be identified later.

The Recap is a **snapshot** at creation time — adding more plays later (for example by syncing an offline device that had plays for the same period) doesn't change an existing Recap playlist. Use the *Sync with Navidrome* button if you want to re-align an existing Recap with your current play counts.

### Avoiding duplicate Recaps across devices

When a Recap playlist is created, a marker is written to iCloud. If another device tries to generate the same Recap — because it synced the plays too — it sees the marker and uses the existing playlist instead of creating a duplicate. If there's a race condition and both devices create a playlist at the same moment, the one that "loses" deletes its own playlist and adopts the other's.

### Retention

Shelv keeps a configurable number of Recaps per period type. Once the limit is exceeded, the oldest Recap — its Navidrome playlist, its local registry entry, and its iCloud marker — is deleted automatically. The default limits are:

| Period | Default |
|--------|---------|
| Weekly | 1 |
| Monthly | 12 |
| Yearly | 3 |

You can change these limits in Settings.

### Automatic cleanup when playlists go missing

If you delete a Recap playlist directly on your Navidrome server (for example through the web interface), Shelv detects this on the next refresh and automatically removes the corresponding registry entry from the local database and iCloud. This cleanup only runs after a successful server response, so being offline won't accidentally trigger it.

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

Beyond the main settings, Shelv offers several tools in *Recap Settings*:

### Logs

- **Recent plays** — the last 100 plays, with per-entry delete. Useful for spot-checking what's being counted.
- **Registry** — all active Recap playlist entries, with per-entry delete (deletes the Navidrome playlist + local entry + iCloud marker).
- **Sync log** — verbose CloudKit debug output, useful when troubleshooting sync behaviour.

### Advanced (destructive)

Three clearly separated reset options, each with confirmation:

- **Reset local database** — clears only the local cache on this device. Nothing on iCloud or Navidrome is touched. On the next sync, the local database is re-filled from iCloud.
- **Delete iCloud data** — wipes all Recap data from iCloud for the current server. Local databases and Navidrome playlists stay intact on every device. On the next sync, each device automatically re-uploads its local plays, so iCloud refills with the union of all devices' histories. Useful when iCloud's state is corrupted or you want to start the cloud side fresh without losing anything.
- **Delete everything** — removes the Navidrome Recap playlists, the local database, and the iCloud data — **on this device**. Other devices keep their local plays and will re-upload them on the next sync, and those plays then flow back down to this device. This is not a cross-device wipe; to fully clear history across all devices, run *Delete everything* on each device. Bypasses the iCloud sync toggle.

### Generate test recap

A manual trigger for creating a Recap from the last 7 days' plays. Useful for testing the end-to-end flow.

---

## Settings reference

| Setting | Description |
|---------|-------------|
| Recap enabled | Master switch. When off, no plays are recorded and no Recaps are generated. |
| iCloud Sync | Enables automatic sync of plays and Recap markers across your devices via iCloud. When off, data stays local. |
| Play threshold | How much of a song must be heard for it to count (10–50%). |
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
4. Recreates missing Recap playlists on Navidrome (if the registry references playlists that no longer exist on the server)

Nothing is deleted during import — only uploaded and downloaded. If the backup contains plays from a different Navidrome account, they're reassigned to the current account, since the intention of importing is always to bring your history to the current user.
