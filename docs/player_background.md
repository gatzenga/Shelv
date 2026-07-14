# Player Background Palette

The player derives its background from the current cover. The goal is to keep
the cover's dominant colors while preventing black backgrounds, white text, or
small colored details from controlling the gradient.

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

The hue bucket with the most pixels becomes the primary color.

A secondary bucket is eligible when it contains at least 10% as many pixels as
the primary bucket. The 10% threshold is relative to the primary color, not to
the entire cover.

From all eligible secondary buckets, the algorithm selects the one with the
greatest hue distance from the primary color. If multiple buckets have the same
hue distance, the bucket with more pixels wins.

If no secondary bucket reaches the 10% threshold, the background remains
effectively single-colored.

### Examples

- If blue occupies 90% of a cover and red occupies 10%, the secondary threshold
  is 9% of the cover. Red qualifies and the result is a blue-red gradient.
- If a mostly blue cover contains only a small yellow star or red logo, those
  details normally stay below the threshold and do not affect the background.
- If several blue shades and an orange area all qualify, orange is preferred
  because it has the greatest hue distance from the primary blue.

## 3. Final player appearance

The full-screen player always uses its dark presentation, independently of the
app's Light or Dark Mode setting. This keeps the cover background, controls,
and accent color visually consistent:

- Displayed background brightness is limited to approximately 26–72%.
- Saturation is increased and capped at 90%.
- The secondary color is slightly darker and receives a small additional
  saturation reduction. If no separate secondary hue qualifies, this creates a
  subtle tonal gradient from the primary color instead of a completely flat
  background.
- Text, progress elements, and inactive controls stay light instead of changing
  to black with the rest of the app.
- Native Lyrics uses the same dark presentation. The standard Lyrics view still
  follows the app's Light or Dark Mode setting.

This keeps the background within a controlled visual range. It is a brightness
clamp, not a measured contrast test against every label or button.

## 4. Caching and platforms

The extracted palette is cached for the current app session so the same cover
can reuse its background immediately. iPhone, iPad, and Apple TV use the same
selection rules.
