<p align="left">
  <img src="icon.png" width="150" alt="App Logo"/>
</p>

# Shelv

A native, album and artist focused iOS and iPadOS client for [Navidrome](https://www.navidrome.org/) and Subsonic-compatible music servers, built with SwiftUI. Also available as a [native macOS app](https://github.com/gatzenga/Shelv-Desktop).

**TestFlight:** https://testflight.apple.com/join/5y4tN6NB  
**Discord:** https://discord.gg/zU3qv9v6Vn

![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey)
![Swift](https://img.shields.io/badge/swift-5-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

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
- **Crossfade** — Smooth crossfade between tracks with a configurable duration; enable and adjust it in Settings
- **AirPlay** — Stream to any AirPlay-compatible device directly from the player
- **Lock screen and media keys** — Full remote control integration via MPRemoteCommandCenter
- **iPad layout** — Optimised player layout for iPad with larger cover art and controls; mini-player anchored correctly at the bottom via `safeAreaInset`

### Queue
- **Three-tier queue** — Play Next (highest priority), Album queue (current context), and User Queue (backlog); all unlimited
- **Reorder and delete** — Drag to reorder or swipe to delete any track in any queue section
- **Shuffle** — Merges all three queues into one shuffled list; a snapshot preserves the original order so it can be fully restored when shuffle is turned off. When an album or artist is started via Shuffle, the shuffled order itself becomes the reference — disabling shuffle mid-playback keeps the same shuffled sequence without losing any tracks
- **Persistent state** — Queue, current track, playback position, shuffle state, and repeat mode all survive app restarts

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
- Each song's lyrics are cached locally so they load instantly after the first fetch
- **Auto-load** — when enabled in Settings, lyrics are fetched in the background as soon as a song starts playing
- **Bulk download** — a one-tap option in Settings pre-fetches lyrics for your entire library in the background, with a live progress counter

### Search
- Global search across artists, albums, and tracks on your server; also searches locally cached lyrics
- Debounced live results with task cancellation — no redundant network requests

### Settings
- **Servers** — Add, edit, and switch between multiple Subsonic/Navidrome servers; run a full library scan with progress indicator and last-sync timestamp per server
- **Appearance** — Choose between Light, Dark, and System mode; pick one of ten accent colors
- **Cache** — See the current cover art cache size and clear it with a single tap
- **Favorites & Playlists** — Toggle each feature on or off independently

### Cover Art
- Memory and disk cached artwork throughout the UI (NSCache + disk, never blocks the main thread)
- Automatic retry on failure with linear backoff; concurrent deduplication prevents redundant downloads

## Requirements

- iOS 18 or later / iPadOS 18 or later
- Xcode 16 or later
- A running [Navidrome](https://www.navidrome.org/) or Subsonic-compatible server

## Getting Started

1. Clone the repository:
   ```bash
   git clone https://github.com/gatzenga/Shelv.git
   ```
2. Open `Shelv.xcodeproj` in Xcode.
3. Select a simulator or connected device and hit **Run** (`⌘R`).
4. On first launch, enter your server URL and credentials.

> No external dependencies or Swift Package Manager packages are required — the project is fully self-contained.

## Architecture

```
ShelvApp  (@main)
├── ServerStore              — server list, active server, Keychain integration
├── LibraryStore  (@MainActor) — albums, artists, Discover data (disk + memory cache)
└── AudioPlayerService.shared — AVPlayer, 3-queue system, MPRemoteCommandCenter, AirPlay
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

### Caching Strategy

`LibraryStore` applies a stale-while-revalidate pattern: on launch it loads albums and artists from disk immediately, then silently refreshes from the server in the background. A loading spinner is only shown on the very first launch when no disk cache exists yet.

## Supported Audio Formats

Shelv streams audio using `format=raw` (no server-side transcoding) and relies on AVFoundation for decoding: MP3, AAC, M4A, ALAC, WAV, AIFF, FLAC, Opus.

## Authentication

Credentials are authenticated using the Subsonic API's token-based method: `MD5(password + salt)`. Passwords are stored in the system Keychain per server UUID and never sent in plain text.

## Contributing

Pull requests are welcome. For larger changes, please open an issue first to discuss what you'd like to change. Feature ideas, feedback, and general discussion are welcome on the [Discord server](https://discord.gg/zU3qv9v6Vn).

## License

See [LICENSE](LICENSE) for details.

## Screenshots

<p align="center">
  <img src="Screenshots/home.png" width="30%" alt="Home"/>
  <img src="Screenshots/player.png" width="30%" alt="Player"/>
  <img src="Screenshots/favourites.png" width="30%" alt="Favourites"/>
</p>
<p align="center">
  <img src="Screenshots/albums.png" width="30%" alt="Albums"/>
  <img src="Screenshots/artists.png" width="30%" alt="Artists"/>
  <img src="Screenshots/favourites.png" width="30%" alt="Favourites"/>
</p>
<p align="center">
  <img src="Screenshots/album.png" width="30%" alt="Album Detail"/>
</p>
