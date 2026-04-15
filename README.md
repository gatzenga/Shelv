<p align="left">
  <img src="icon.png" width="150" alt="App Logo"/>
</p>

# Shelv

A native iOS and iPadOS client for [Navidrome](https://www.navidrome.org/) and Subsonic-compatible music servers, built with SwiftUI. Also available as a [native macOS app](https://github.com/gatzenga/Shelv-Desktop).

![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey)
![Swift](https://img.shields.io/badge/swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

## Features

- **Browse your library** — Albums and Artists with alphabetical index bar and grid or list layout
- **Discover** — Recently added, recently played, and frequently played albums at a glance
- **Smart mixes** — One-tap shuffled queues based on newest, most played, or recently played tracks
- **Full playback control** — Play, pause, seek, skip with AirPlay support and lock screen integration
- **Smart queue system** — Play Next, Album queue, and a user backlog with drag-to-reorder and swipe-to-delete
- **Search** — Find artists, albums, and tracks on your server with debounced live results
- **Cover art** — Memory and disk cached artwork throughout the UI, never blocks the main thread
- **Multiple servers** — Manage and switch between Subsonic/Navidrome server configurations
- **Library sync** — Full scan with progress indicator and last-sync timestamp per server
- **Theming** — Choose an accent color to personalize the interface
- **Persistent player** — Queue and playback position survive app restarts

## Requirements

- iOS 17 or later / iPadOS 17 or later
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

Shelv follows a clean MVVM structure:

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
| `userQueue` | Lowest | User backlog, max 200 songs |

### Caching Strategy

`LibraryStore` applies a stale-while-revalidate pattern: on launch it loads albums and artists from disk immediately, then silently refreshes from the server in the background. A loading spinner is only shown on the very first launch when no disk cache exists yet.

## Authentication

Credentials are authenticated using the Subsonic API's token-based method: `MD5(password + salt)`. Passwords are stored in the system Keychain per server UUID and never sent in plain text.

## Contributing

Pull requests are welcome. For larger changes, please open an issue first to discuss what you'd like to change.

## License

See [LICENSE](LICENSE) for details.

## Screenshots

<p align="center">
  <img src="Screenshots/home.png" width="23%" alt="Home"/>
  <img src="Screenshots/albums.png" width="23%" alt="Albums"/>
  <img src="Screenshots/artists.png" width="23%" alt="Artists"/>
  <img src="Screenshots/player.png" width="23%" alt="Player"/>
</p>
<p align="center">
  <img src="Screenshots/album.png" width="23%" alt="Album Detail"/>
  <img src="Screenshots/artist.png" width="23%" alt="Artist Detail"/>
  <img src="Screenshots/search.png" width="23%" alt="Search"/>
</p>
