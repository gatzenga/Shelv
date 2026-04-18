# Shelv Recap

Recap automatically creates playlists of your most-played songs — weekly, monthly, and yearly. It works across all your devices via iCloud, so your listening history is always complete no matter which device you use.

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

Every time a play is recorded, Shelv immediately tries to upload it to iCloud. If you're offline, it queues the upload and retries as soon as the network is available again.

When you open the app on another device — or switch back to it — Shelv downloads any new plays from iCloud that it hasn't seen yet. This means that even if you listened on your iPhone while offline and only connected later, those plays will eventually appear on your Mac and vice versa.

The sync uses iCloud's private database, so your listening history is only visible to you and your own devices.

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

### Avoiding duplicate Recaps across devices

When a Recap playlist is created, a marker is written to iCloud. If another device tries to generate the same Recap — because it synced the plays too — it sees the marker and uses the existing playlist instead of creating a duplicate. If there's a race condition and both devices create a playlist at the same moment, the one that "loses" deletes its own playlist and adopts the other's.

### Retention

Shelv keeps a configurable number of Recaps per period type. Once the limit is exceeded, the oldest Recap — both the local registry entry and the Navidrome playlist — is deleted automatically. The default limits are:

| Period | Default |
|--------|---------|
| Weekly | 1 |
| Monthly | 12 |
| Yearly | 3 |

You can change these limits in Settings.

---

## Playlog Sync with Navidrome

The *Playlog Sync* function checks whether the Recap playlists that exist in Shelv's local database still match what's actually on the Navidrome server. This is useful after importing a database from another device, or if playlists were manually edited or deleted on the server.

For each Recap in the local registry, Shelv fetches the corresponding playlist from Navidrome and compares:

- **Name** — does the playlist still have the expected name?
- **Comment** — is the `Shelv Recap` comment present?
- **Songs** — are all expected songs present, and no unexpected ones?
- **Order** — are the songs in the correct order (ranked by play count)?

If any discrepancy is found, it's shown in a list. For each affected playlist you can choose:

- **Apply** — update the existing playlist to match what the database expects (corrects name, comment, adds missing songs, removes extra ones, restores order)
- **Create new** — leave the existing playlist untouched and create a fresh one that matches the database exactly

If a playlist has been deleted from Navidrome entirely, only *Create new* is offered.

If everything matches, the view shows a confirmation that all Recaps are in sync.

---

## Settings reference

| Setting | Description |
|---------|-------------|
| Recap enabled | Master switch. When off, no plays are recorded and no Recaps are generated. |
| Play threshold | How much of a song must be heard for it to count (10–50%). |
| Weekly Recap | Generates a playlist for each completed calendar week (Monday–Sunday). |
| Monthly Recap | Generates a playlist for each completed calendar month. |
| Yearly Recap | Generates a playlist for each completed calendar year. |
| Weekly retention | How many weekly Recap playlists to keep. |
| Monthly retention | How many monthly Recap playlists to keep. |
| Yearly retention | How many yearly Recap playlists to keep. |

---

## Database import and export

Shelv can export its local play log database as a file and import it on another device. This is useful when setting up a new device and you want to bring your full history along without waiting for iCloud sync to deliver everything.

After an import, Shelv automatically runs a Playlog Sync to check whether the imported Recap playlists still exist on the Navidrome server and whether they match. You can resolve any discrepancies before the import is finalised.

If you cancel out of the sync screen after an import, the import is rolled back and your previous database is restored.
