# Player Background Palette

The player derives its background from the current cover. The goal is to keep
the cover's dominant colors while preventing black areas, white areas, or small
colored details from controlling the gradient.

## 1. Color analysis

The cover is downscaled to 32×32 pixels and every pixel is classified by its
HSV saturation and brightness:

- **Too dark:** brightness below 15%. These pixels are treated as black/dark
  content and cannot become the primary or secondary color.
- **Near-white:** brightness above 85% and saturation below 12%. These pixels
  are treated as white/light-neutral content and cannot become the primary or
  secondary color.
- **Usable color:** saturation of at least 15% and brightness of at least 15%.
  Usable colors are grouped into 12 hue buckets of 30° each.
- **Other neutral pixels:** low-saturation gray or beige mid-tones are ignored.

There is intentionally no general maximum brightness for a colorful pixel. A
bright, saturated yellow or blue may still be selected. The upper brightness
filter only removes bright pixels that are nearly neutral, such as white or
light gray.

Black, white, and neutral gray buckets are never used as gradient colors. If a
cover contains no usable chromatic color, the background falls back to a
neutral gray with 28% brightness.

## 2. Primary and secondary color

The hue bucket with the most pixels becomes the primary color. Selecting a
secondary color then happens in two separate steps:

1. **Minimum size:** A bucket is eligible when its pixel count is at least
   `max(3, primaryCount / 10)`. In normal-sized buckets this is approximately
   10% of the primary bucket, not 10% of the entire cover. The minimum of three
   pixels prevents tiny rounding results from admitting isolated details.
2. **Largest hue difference:** From the eligible buckets, the algorithm selects
   the one with the greatest circular hue-bucket distance from the primary. If
   multiple buckets have the same distance, the bucket with more pixels wins.

There is deliberately no fixed minimum hue distance such as 60°. A color that
is only one 30° bucket away may still become the secondary color when it occurs
often enough. The size rule decides whether a color is significant; the hue
distance only decides which significant color is the best secondary.

If no second chromatic bucket reaches the minimum size, the algorithm makes one
additional attempt within the primary hue bucket. It sorts that bucket's
original pixels by HSV brightness, splits them into the darker and lighter
halves, and averages each half separately. Both halves must still contain at
least `max(3, primaryCount / 10)` pixels. The two actual cover colors are used
only when their averaged brightness values differ by at least 10 percentage
points; the lighter average becomes the primary and the darker average becomes
the secondary.

This brightness split is only a fallback. It cannot replace a qualifying
secondary hue and therefore does not change existing multi-color gradients. If
the split is too small, no separate secondary color is extracted and the
rendered gradient continues to derive a slightly darker, slightly less
saturated second tone from the original primary color.

### Examples

- If the primary blue bucket contains 900 pixels, another bucket needs at least
  `max(3, 900 / 10) = 90` pixels to qualify.
- A nearby cyan bucket with 120 pixels qualifies even though it is less than
  60° away. It can create a blue-cyan gradient instead of being discarded.
- A distant orange detail with only 20 pixels does not qualify, despite its
  strong hue contrast, because it is too small to represent the cover.
- If cyan and orange both qualify, orange is selected because its hue is farther
  from the primary blue. If two qualifying buckets are equally far away, the
  larger bucket wins.
- If no other hue qualifies but one blue bucket contains clearly separated
  light and dark shades, those halves create a blue-to-blue gradient when their
  averaged brightness differs by at least 10 percentage points.

## 3. Final player appearance

The full-screen player always uses its dark presentation, independently of the
app's Light or Dark Mode setting. This keeps the cover background, controls,
and accent color visually consistent:

- Displayed background brightness is limited to approximately 26–72%.
- Saturation is increased and capped at 90%.
- The secondary color is slightly darker and receives a small additional
  saturation reduction. If neither a secondary hue nor the same-hue brightness
  split qualifies, this creates a subtle tonal gradient from the primary color
  instead of a completely flat background.
- Text, progress elements, and inactive controls stay light instead of changing
  to black with the rest of the app.
- The native navigation bar uses a dark toolbar appearance so its glass and
  controls blend with the player background in both app modes.
- Native Lyrics uses the same dark presentation. The standard Lyrics view still
  follows the app's Light or Dark Mode setting.

This keeps the background within a controlled visual range. It is a brightness
clamp, not a measured contrast test against every label or button.

## 4. Caching and platforms

The extracted palette is cached for the current app session so the same cover
can reuse its background immediately. iPhone, iPad, and Apple TV use the same
selection rules.
