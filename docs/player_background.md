# Player Background Palette Algorithm

## How it works

Each pixel of the cover art (downscaled to 32×32) is assigned to one of 14 buckets:

- **Dark bucket** — `v < 0.20` (blacks, very dark colors)
- **Light bucket** — `v > 0.85` and `s < 0.12` (whites, neutral brights)
- **12 hue buckets** — `s ≥ 0.15`, split by hue in 30° steps
- **Ignored** — everything else (unsaturated mid-tones)

## Color selection

**Step 1: Find chromatic colors**
Sort all color buckets (0–11) by pixel count. The largest becomes the primary candidate.

**Step 2: Is there a second color?**
If it reaches ≥10% of the primary candidate's count, has ≥60° hue distance, → use both. The more frequent one = primary.

**Step 3: No second color above 10%?**
Fall back to dark or light (whichever has more pixels). Then compare: color vs. neutral → the more frequent one = primary, the other = secondary.

**Step 4: No dark or light either?**
Single color only → tonal gradient (darker variant of primary).

## Additional details

- Results are cached per `coverArtId` for the app session — same cover always produces the same colors.
- The source image is always loaded at 300px for consistency; 80px is used as offline fallback only.
- `adaptedColor()` adjusts saturation and brightness for dark/light mode after palette extraction.
