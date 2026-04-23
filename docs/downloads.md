# Shelv Downloads & Offline Mode

Downloads let you save music from your Navidrome server directly to your device so you can listen without a network connection. Once songs are downloaded, you can switch Shelv into Offline Mode — the app then plays exclusively from your local library without attempting any server requests.

---

## Enabling the feature

Downloads are disabled by default. Enable them in **Settings → Downloads**. Once enabled, download buttons appear throughout the app — on album detail pages, in context menus, and in the Artists view. The Offline Mode toggle also becomes available.

---

## Downloading music

### Albums and artists

Every album detail page has a download button. Tapping it queues all songs in the album. Once all songs are downloaded, the button changes to a delete option so you can free up the storage again.

From the Artists view, you can download or delete an entire artist's discography at once. Shelv fetches all albums for the artist first, then queues all songs.

A **download badge** (filled circle with arrow) appears on album covers throughout the app whenever at least one song in the album is stored locally. The album's context menu shows whether the download is partial — offering a **Download Remaining** option — or complete, showing only the delete option.

### Playlists

Every playlist detail page has a download button that saves all songs in the playlist to your device. Once a playlist is marked for offline use, the button changes to a delete option.

In Offline Mode, the Playlists tab shows **only** playlists that have been downloaded — playlists without a download marker are hidden entirely.

When you go back online, Shelv checks whether all songs in a marked playlist are still present. If any are missing the download marker is removed automatically and the download button reappears, so you can re-download the playlist.

### Bulk download

Settings → Downloads → **Bulk Download** queues your entire library for download in one step. Shelv prioritises which songs to download first based on what you actually listen to:

1. Albums you play most frequently
2. Albums you played most recently
3. Starred / favourited items
4. Everything else, alphabetically

A configurable storage limit (default: 10 GB) acts as a ceiling. Once the limit is reached, Shelv stops queuing new songs — already-queued downloads finish normally.

### Download queue

While a batch is in progress, a progress indicator appears at the top of the Downloads tab showing how many songs have completed out of the total. You can cancel the entire batch or individual songs at any time.

Downloads run in the background — you can switch to another app or lock your screen and they will continue. If the app is killed, any in-flight downloads resume automatically on next launch.

---

## Offline Mode

Switch into Offline Mode from **Settings → Downloads → Offline Mode** (or via the app menu). In Offline Mode:

- All playback comes from the local download database — no network requests are made
- The library view shows only downloaded albums and artists
- Sort options that require server data (Most Played, Recently Added) are hidden; albums and artists can be sorted by Name or Year
- Search is limited to locally cached content

Exit Offline Mode the same way to reconnect to the server and resume normal streaming. Shelv does not automatically leave Offline Mode when a connection becomes available.

---

## Transcoding

By default, Shelv requests audio from your Navidrome server in its original format (`raw`). If your server or connection can't handle lossless files well, you can enable transcoding in **Settings → Transcoding**.

Shelv applies separate policies for three situations:

| Situation | What it controls |
|-----------|-----------------|
| **Wi-Fi streaming** | Format and bitrate when streaming over Wi-Fi |
| **Cellular streaming** | Format and bitrate when streaming over mobile data |
| **Downloads** | Format and bitrate when saving songs to your device |

For each situation you can choose:
- **Format** — `raw` (original file, no re-encoding), `mp3`, or `opus`
- **Bitrate** — the target bitrate for the chosen format (only relevant if the format is not `raw`)

Setting the download format to something other than `raw` is useful if you want to save storage — a 192 kbps MP3 takes significantly less space than a lossless FLAC file.

Transcoding requires your Navidrome server to support it. If the server doesn't support the chosen format, Shelv falls back to `raw` automatically.

---

## Storage management

The Downloads tab shows:
- Total number of downloaded songs
- Total storage used by downloads
- A breakdown by artist and by album

Individual albums and artists can be deleted from the Downloads tab or from their detail pages. To clear all downloads at once, use **Settings → Downloads → Delete All Downloads**.

---

## Settings reference

| Setting | Description |
|---------|-------------|
| Enable Downloads | Master switch. When off, no download UI is shown anywhere in the app. |
| Offline Mode | When on, Shelv plays only from local downloads and hides all server-dependent UI. |
| Storage limit | Maximum storage Shelv will use for the bulk download queue. Songs already queued finish even if the limit is reached mid-batch. |
| Enable Transcoding | When off, all streams and downloads use the original file format from the server. |
| Wi-Fi format / bitrate | Codec and bitrate used when streaming over Wi-Fi (if transcoding is on). |
| Cellular format / bitrate | Codec and bitrate used when streaming over cellular (if transcoding is on). |
| Download format / bitrate | Codec and bitrate used when saving songs to the device (if transcoding is on). |
