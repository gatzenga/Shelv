# mixes

Shelv offers curated mixes in both online and offline mode. All mixes start playback immediately. Online Smart Mixes are shown from the Discover tab in the app and from Discover in CarPlay, unless the user hides individual Smart Mixes in UI Customizations. CarPlay mirrors the same Discover customization and uses the exact same mix logic as the in-app Discover page.

The local play log (SQLite) is independent of Recap — it records plays whenever a track passes the listening threshold, regardless of whether the Recap feature is enabled. Recap is just one of several consumers of that database.

**Mixes from database (toggle):** A setting in Settings → Database (`mixUseDatabase`, **default off**) decides whether **Frequently Played** and **Recently Played** are built from your local play log or from the server. When on, the database is only used if it holds **at least 50 unique songs**; otherwise the server method is used (so early on, before enough has been logged, mixes still work). **Newest Tracks** and **Shuffle All** ignore this toggle entirely.

---

## Online mixes

Requires an active server connection. All online mixes shuffle the resulting track list before playback.

### Newest Tracks
Fetches the **10 most recently added albums** from Navidrome, then loads all songs from each of those albums. The total track count varies depending on album size. Shuffled before playback. (Not affected by the database toggle.)

### Frequently Played
Source depends on the **Mixes from database** setting:

- **Off (default):** Server-side, like Insights. Fetches the **500 most-played albums**, sorts by play count, keeps every album above a dynamic threshold (`max(playCount) / 50`, clamped to 30–80 albums), loads their songs, and takes the **top 50 tracks** by play count.
- **On (and ≥ 50 unique songs logged):** Uses the local play log — the **50 most-played unique songs of all time**, fetched individually for full metadata. Below 50 unique songs it falls back to the server method above.

Shuffled before playback.

### Recently Played
Source depends on the **Mixes from database** setting:

- **Off (default):** Server-side via `getRecentSongs` — the **30 most recently played albums**, first **50 tracks** in album order. May include songs you have not actually played.
- **On (and ≥ 50 unique songs logged):** Uses the local play log — the **50 most recently played unique songs**, ordered by last played date, fetched individually for full metadata. Below 50 unique songs it falls back to the server method above.

Shuffled before playback.

### Shuffle All
Requests **500 random tracks** directly from the server (`getRandomSongs`). The server picks the tracks — every tap produces a different selection. Shuffled before playback. (Not affected by the database toggle.)

---

## Offline mixes

Available when offline mode is active and at least one song has been downloaded. Offline mixes operate entirely on the local download database.

### Play All Downloads
Takes **all downloaded songs**, sorts them by artist → album → disc → track number, and plays up to **500 tracks** in order.

### Shuffle All Downloads
Takes **all downloaded songs**, shuffles them randomly, and plays up to **500 tracks** as a shuffle queue.

### Latest Downloads
Takes the **100 most recently downloaded songs** (sorted by download date, newest first) and plays them as a shuffled mix.
