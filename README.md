<picture>
  <source media="(prefers-color-scheme: dark)" srcset="dark.png">
  <img src="light.png" alt="Shelv" width="128">
</picture>

# Shelv

A native, album and artist focused iOS, iPadOS, macOS, and tvOS client for [Navidrome](https://www.navidrome.org/) and Subsonic-compatible music servers, built with SwiftUI. Includes **Recap** — automatic weekly, monthly, and yearly playlists of your most-played songs, with optional iCloud sync across iPhone, iPad, Mac, and Apple TV.

[![Download on the App Store](https://developer.apple.com/app-store/marketing/guidelines/images/badge-download-on-the-app-store.svg)](https://apps.apple.com/us/app/shelv-player/id6762255865)

[![TestFlight](https://img.shields.io/badge/TestFlight-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/5y4tN6NB)

[![Discord](https://img.shields.io/badge/Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/UdJK5mpmZu)

[![Website](https://img.shields.io/badge/Website-000000?style=for-the-badge&logo=safari&logoColor=white)](https://vkugler.app)

![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS%20%7C%20macOS%20%7C%20tvOS-lightgrey)
![Swift](https://img.shields.io/badge/swift-5-orange)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

## Features

### Library
- **Albums and Artists** — Browse your full library with an alphabetical index bar; switch between grid and list layout
- **Quick actions** — Long-press any album or artist in the grid for a context menu (Play, Shuffle, Play Next, Add to Queue); swipe left or right on any row in list view for the same actions
- **Artist detail** — Dedicated Play and Shuffle buttons on the artist page load all tracks in parallel and start playback immediately
- **Album detail** — Full tracklist with swipe actions per track: swipe right to play next or add to queue, swipe left to favorite or add to a playlist

### Discover
- **Shelves** — Recently added, recently played, frequently played, and random albums in horizontal scroll sections
- **Smart Mixes** — Three one-tap buttons that build a shuffled queue from your newest tracks, most played tracks, or recently played tracks
- **Random Albums** — A dedicated section with a shuffle button to load a fresh random selection at any time
- **Insights** — A ranked overview of your most played artists, albums, and songs, pulled directly from your server's play count data. The top three entries are highlighted; play counts are shown as badges next to each entry. Accessible via the chart icon in the top-right corner of Discover

### Playback
- **Full player** — Play, pause, seek, previous, next, shuffle, and three repeat modes (Off / All / One)
- **Gapless playback** — Lossless back-to-back playback with no silence between tracks; enable in Settings
- **AirPlay** — Stream to any AirPlay-compatible device directly from the player
- **Lock screen and media keys** — Full remote control integration via MPRemoteCommandCenter
- **iPad layout** — Optimised player layout for iPad with larger cover art and controls; mini-player anchored correctly at the bottom via `safeAreaInset`

### Queue
- **Three-tier queue** — Play Next (highest priority), Album queue (current context), and User Queue (backlog); all unlimited
- **Reorder and delete** — Drag to reorder or swipe to delete any track in any queue section
- **Shuffle** — Merges all three queues into one shuffled list; a snapshot preserves the original order so it can be fully restored when shuffle is turned off. When an album or artist is started via Shuffle, the shuffled order itself becomes the reference — disabling shuffle mid-playback keeps the same shuffled sequence without losing any tracks
- **Persistent state** — Queue, current track, playback position, shuffle state, and repeat mode all survive app restarts
- **Queue Sync** — Optionally sync the current queue through iCloud or Subsonic, with a takeover prompt when another device has a newer queue

### Favorites *(optional)*
- Star songs, albums, and artists — synced to the server via the Subsonic API
- A dedicated Favorites tab in the Library groups starred songs, albums, and artists
- Favorites can be enabled or disabled in Settings; when disabled, all related UI elements are hidden

### Playlists *(optional)*
- Add songs or full albums to existing server playlists, or create a new one on the fly
- Available via context menus, swipe actions, and the full-screen player
- Playlists can be enabled or disabled in Settings; when disabled, all related UI elements are hidden

### Lyrics
- Synced and plain-text lyrics displayed in the full-screen player, with automatic line highlighting and scrolling for time-coded tracks
- Lyrics are fetched from your Navidrome server first; if none are stored there, Shelv falls back to [lrclib.net](https://lrclib.net) automatically
- Custom LRCLIB-compatible servers are supported, and the server setting can be synced through iCloud
- Each song's lyrics are cached locally so they load instantly after the first fetch
- **Auto-load** — when enabled in Settings, lyrics are fetched in the background as soon as a song starts playing
- **Bulk download** — a one-tap option in Settings pre-fetches lyrics for your entire library in the background, with a live progress counter

### Downloads & Offline Mode *(optional, iOS/iPadOS/macOS)*
- Download albums and artists to your device for playback without a network connection
- **Bulk download** — queue your entire library in one tap; Shelv prioritises frequently played, recently played, and starred content first
- Configurable storage limit; download badges on album covers show full or partial download status
- **Offline Mode** — when active, the app plays exclusively from local downloads with no server requests; library views show only downloaded content
- Downloads continue in the background when you switch apps or lock your screen
- Can be enabled or disabled in Settings; when disabled, all download UI is hidden

### Transcoding *(optional)*
- Set audio format and bitrate policies for streaming and downloads; iOS, iPadOS, and macOS support separate Wi-Fi, cellular, and download profiles, while tvOS uses one streaming profile
- Supported formats: `raw` (original file), `mp3`, `opus`
- Useful for saving storage on downloaded files or reducing cellular data usage
- Falls back to `raw` automatically if the server doesn't support the chosen format
- Can be enabled or disabled independently of Downloads

### Recap
- Automatic weekly, monthly, and yearly playlists of your most-played songs, created directly on your Navidrome server
- Configurable play threshold (10–50%): a track only counts once you've heard enough of it
- Plays are recorded locally and can be synced across your devices via iCloud — offline plays are queued and uploaded as soon as the network is available
- Duplicate-safe: an iCloud marker prevents multiple devices from creating the same Recap playlist when Recap sync is enabled
- **Playlog Sync** — checks whether existing Recap playlists on the server still match the database and lets you apply fixes or create a new playlist
- Database can be exported and imported; after an import a sync check runs automatically with rollback on cancel

### CarPlay
- Browse Discover, Library, Playlists, Favorites, Recaps, and the current queue from CarPlay
- Play, shuffle, queue, favorite, and open Now Playing using CarPlay-native templates
- Cover art is streamed in small batches so lists stay responsive while artwork loads

### Search
- Global search across artists, albums, and tracks on your server; also searches locally cached lyrics
- Debounced live results with task cancellation — no redundant network requests

### Settings
- **Servers** — Add, edit, and switch between multiple Subsonic/Navidrome servers; run a full library scan with progress indicator and last-sync timestamp per server
- **Appearance** — Choose between Light, Dark, and System mode; pick one of ten accent colors
- **Cache** — See the current cover art cache size and clear it with a single tap
- **Downloads** — Enable downloads, set storage limit, run a bulk download, toggle Offline Mode, manage downloaded content
- **Playback** — Configure gapless playback, transcoding, replay gain, scrobble threshold, lyrics, and Queue Sync
- **iCloud** — Enable iCloud sync and choose what to sync: Play History, Recap, and Lyrics Server
- **Recap** — Configure periods (weekly, monthly, yearly), retention, play threshold, and database export/import
- **Favorites & Playlists** — Toggle each feature on or off independently

### Cover Art
- Memory and disk cached artwork throughout the UI (NSCache + disk, never blocks the main thread)
- Automatic retry on failure with linear backoff; concurrent deduplication prevents redundant downloads

## Requirements

- iOS 18 or later / iPadOS 18 or later
- macOS 15.6 or later
- tvOS 18.6 or later
- Xcode 27 or later
- A running [Navidrome](https://www.navidrome.org/) or Subsonic-compatible server

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/gatzenga/Shelv.git
   ```
2. Open `Shelv.xcodeproj` in Xcode.
3. Select a simulator or connected device and hit **Run** (`⌘R`).
4. On first launch, enter your server URL and credentials.

> The project uses Swift Package Manager for GRDB. The resolved package state is tracked in `Package.resolved`.

## Architecture

```
ShelvApp  (@main)
├── ServerStore              — server list, active server, Keychain integration
├── LibraryStore  (@MainActor) — albums, artists, Discover data (disk + memory cache)
├── AudioPlayerService.shared — AVPlayer, 3-queue system, MPRemoteCommandCenter, AirPlay
├── QueueSyncService.shared   — optional iCloud/Subsonic queue handoff
└── CloudKitSyncService.shared — Play History, Recap, Lyrics Server, and Queue Sync records
```

All API communication goes through `SubsonicAPIService.shared` using MD5 token authentication. Cover art is handled exclusively by `ImageCacheService` (actor-isolated, NSCache + disk, concurrent deduplication) — `AsyncImage` is never used directly.

### Queue System

| Queue | Priority | Description |
|---|---|---|
| `playNextQueue` | Highest | Tracks queued via "Play Next" |
| `queue` | Normal | Current album / playback context |
| `userQueue` | Lowest | User backlog (unlimited) |

Playback order: `playNextQueue` → `queue[currentIndex+1...]` → `userQueue` (one track at a time, not as a block).

**Shuffle** — When enabled, all three queues are merged into a single shuffled list inside `queue`; `playNextQueue` and `userQueue` are cleared. A snapshot of the pre-shuffle state is saved. When shuffle is disabled, the original order is restored, keeping only the tracks that have not been played yet. Tracks added while shuffle is active are inserted at a random position and mirrored into the snapshot so they reappear in the correct section when shuffle is turned off. When playback is started via the Shuffle action on an album or artist, all tracks are shuffled upfront and the snapshot stores this shuffled order — so disabling shuffle mid-playback restores the same shuffled sequence without losing any tracks.

**Repeat**
- **Off** — Stops after the last track
- **All** — Wraps back to the start of the queue (reshuffled if shuffle is on)
- **One** — Replays the current track on natural end; a manual skip advances to the next track

**Jump** — Tapping any track in the queue removes it from its position, inserts it directly after the current track, and starts playback immediately. Nothing before it is discarded.

**Queue Sync** — The queue can stay local, sync through Subsonic's play queue endpoint, or sync through iCloud. Subsonic mode stores a flat queue that can interoperate with other clients; iCloud mode keeps Shelv's full queue structure, shuffle, and repeat state. Remote queues are offered as a takeover prompt instead of replacing local playback automatically.

### Caching Strategy

`LibraryStore` applies a stale-while-revalidate pattern: on launch it loads albums and artists from disk immediately, then silently refreshes from the server in the background. A loading spinner is only shown on the very first launch when no disk cache exists yet.

## Supported Audio Formats

By default Shelv streams in `format=raw` and relies on AVFoundation for decoding: MP3, AAC, M4A, ALAC, WAV, AIFF, FLAC, Opus. When transcoding is enabled, the server re-encodes to MP3 or Opus at a configurable bitrate before streaming.

## Authentication

Credentials are authenticated using the Subsonic API's token-based method: `MD5(password + salt)`. Passwords are stored in the system Keychain per server UUID and never sent in plain text.

## Contributing

Pull requests are welcome. For larger changes, please open an issue first to discuss what you'd like to change. Feature ideas, feedback, and general discussion are welcome on the [Discord server](https://discord.gg/UdJK5mpmZu).

### Translations

To add a new language, create a `<language-code>.lproj/Localizable.strings` file (e.g. `fr.lproj/Localizable.strings`) modelled after `en.lproj/Localizable.strings`. Submit it as a pull request.

## License

See [LICENSE](LICENSE) for details.

### iPhone

<table>
  <tr>
    <td><img src="screenshots_iPhone/home.png" width="220"/></td>
    <td><img src="screenshots_iPhone/recap.png" width="220"/></td>
    <td><img src="screenshots_iPhone/player.png" width="220"/></td>
  </tr>
  <tr>
    <td><img src="screenshots_iPhone/albums.png" width="220"/></td>
    <td><img src="screenshots_iPhone/artists.png" width="220"/></td>
    <td><img src="screenshots_iPhone/favorites.png" width="220"/></td>
  </tr>
</table>
<table align="center">
  <tr>
    <td><img src="screenshots_iPhone/album.png" width="220"/></td>
    <td><img src="screenshots_iPhone/playlists.png" width="220"/></td>
  </tr>
</table>

### iPad

<table>
  <tr>
    <td><img src="screenshots_iPad/home.png" width="220"/></td>
    <td><img src="screenshots_iPad/recap.png" width="220"/></td>
    <td><img src="screenshots_iPad/player.png" width="220"/></td>
  </tr>
  <tr>
    <td><img src="screenshots_iPad/albums.png" width="220"/></td>
    <td><img src="screenshots_iPad/artists.png" width="220"/></td>
    <td><img src="screenshots_iPad/favorites.png" width="220"/></td>
  </tr>
</table>
<table align="center">
  <tr>
    <td><img src="screenshots_iPad/album.png" width="220"/></td>
    <td><img src="screenshots_iPad/playlists.png" width="220"/></td>
  </tr>
</table>

### macOS

<table>
  <tr>
    <td><img src="screenshots_mac/home.png" width="360"/></td>
    <td><img src="screenshots_mac/recap.png" width="360"/></td>
  </tr>
  <tr>
    <td><img src="screenshots_mac/albums.png" width="360"/></td>
    <td><img src="screenshots_mac/artists.png" width="360"/></td>
  </tr>
  <tr>
    <td><img src="screenshots_mac/favorites.png" width="360"/></td>
    <td><img src="screenshots_mac/album.png" width="360"/></td>
  </tr>
</table>

### tvOS

<table>
  <tr>
    <td><img src="screenshots_TV/home.png" width="250"/></td>
    <td><img src="screenshots_TV/recap.png" width="250"/></td>
    <td><img src="screenshots_TV/player.png" width="250"/></td>
  </tr>
  <tr>
    <td><img src="screenshots_TV/albums.png" width="250"/></td>
    <td><img src="screenshots_TV/artists.png" width="250"/></td>
    <td><img src="screenshots_TV/favorites.png" width="250"/></td>
  </tr>
</table>
<table align="center">
  <tr>
    <td><img src="screenshots_TV/album.png" width="250"/></td>
    <td><img src="screenshots_TV/playlists.png" width="250"/></td>
  </tr>
</table>
