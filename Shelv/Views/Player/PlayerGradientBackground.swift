import SwiftUI
import UIKit

private func trimmedNonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

struct PlayerBackgroundPalette {
    let primary: UIColor
    let secondary: UIColor?
}

private struct PlayerPalettePixelSample {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let brightness: CGFloat
}

private final class PlayerBackgroundPaletteResult: NSObject {
    let palette: PlayerBackgroundPalette

    init(_ palette: PlayerBackgroundPalette) {
        self.palette = palette
    }
}

enum PlayerBackgroundPaletteStore {
    private static let paletteCache: NSCache<NSString, PlayerBackgroundPaletteResult> = {
        let cache = NSCache<NSString, PlayerBackgroundPaletteResult>()
        cache.countLimit = 200
        return cache
    }()

    static func identifier(for player: AudioPlayerService) -> String {
        if player.isRadioPlayback {
            guard let station = player.currentRadioStation else { return "radio-none" }
            if station.usesDynamicSongCover,
               let metadata = player.currentRadioMetadata,
               trimmedNonEmpty(metadata.artworkURL) != nil {
                return "radio-art-\(metadata.artworkRevisionToken)"
            }
            if let coverArt = trimmedNonEmpty(station.coverArt) {
                return "radio-cover-\(coverArt)"
            }
            return "radio-station-\(station.id)"
        }
        return player.currentSong?.coverArt ?? "song-none"
    }

    static func isEmptyIdentifier(_ identifier: String) -> Bool {
        identifier == "song-none" || identifier == "radio-none"
    }

    static func cachedPalette(for identifier: String) -> PlayerBackgroundPalette? {
        guard !isEmptyIdentifier(identifier) else { return nil }
        return paletteCache.object(forKey: identifier as NSString)?.palette
    }

    static func cache(_ palette: PlayerBackgroundPalette, for identifier: String) {
        guard !isEmptyIdentifier(identifier) else { return }
        paletteCache.setObject(PlayerBackgroundPaletteResult(palette), forKey: identifier as NSString)
    }

    static func adaptedColor(_ uiColor: UIColor, asSecondary: Bool, colorScheme: ColorScheme) -> Color {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var v: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let factor: CGFloat = asSecondary ? 0.88 : 1.0
        if colorScheme == .dark {
            let brightness = min(max(v, 0.35) * 0.82, 0.72)
            return Color(UIColor(
                hue: h,
                saturation: min(s * 1.2 * factor, 0.90),
                brightness: brightness * (asSecondary ? 0.92 : 1.0),
                alpha: 1
            ))
        } else {
            return Color(UIColor(
                hue: h,
                saturation: min(s * factor, 0.90),
                brightness: min(v * 0.45 + 0.58, 0.96),
                alpha: 1
            ))
        }
    }
}

struct PlayerGradientBackground: View {
    @ObservedObject private var player = AudioPlayerService.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var rawPrimary: UIColor?
    @State private var rawSecondary: UIColor?
    @State private var activeIdentifier: String?

    init() {
        let identifier = PlayerBackgroundPaletteStore.identifier(for: AudioPlayerService.shared)
        let palette = PlayerBackgroundPaletteStore.cachedPalette(for: identifier)
        _rawPrimary = State(initialValue: palette?.primary)
        _rawSecondary = State(initialValue: palette?.secondary)
        _activeIdentifier = State(initialValue: palette == nil ? nil : identifier)
    }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: primaryColor, location: 0.0),
                .init(color: primaryColor, location: 0.45),
                .init(color: secondaryColor, location: 0.75),
                .init(color: secondaryColor, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .task(id: backgroundLoadIdentifier) {
            await updateBackground()
        }
    }

    private var primaryColor: Color {
        guard let rawPrimary else { return Color(UIColor.systemBackground) }
        return PlayerBackgroundPaletteStore.adaptedColor(rawPrimary, asSecondary: false, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        guard let rawPrimary else { return Color(UIColor.systemBackground) }
        return PlayerBackgroundPaletteStore.adaptedColor(rawSecondary ?? rawPrimary, asSecondary: true, colorScheme: colorScheme)
    }

    private var backgroundIdentifier: String {
        PlayerBackgroundPaletteStore.identifier(for: player)
    }

    private var backgroundLoadIdentifier: String {
        guard player.isRadioPlayback else { return backgroundIdentifier }
        return "\(backgroundIdentifier)|\(player.artworkReloadToken.uuidString)"
    }

    private func updateBackground() async {
        let identifier = backgroundIdentifier
        guard !PlayerBackgroundPaletteStore.isEmptyIdentifier(identifier) else {
            activeIdentifier = nil
            rawPrimary = nil
            rawSecondary = nil
            return
        }

        let alreadyShowingIdentifier = activeIdentifier == identifier && rawPrimary != nil
        activeIdentifier = identifier

        if let hit = PlayerBackgroundPaletteStore.cachedPalette(for: identifier) {
            apply(hit, animated: !alreadyShowingIdentifier)
            return
        }

        let image = await loadBackgroundImage()
        guard !Task.isCancelled, activeIdentifier == identifier else { return }
        guard let image else {
            rawPrimary = nil
            rawSecondary = nil
            return
        }

        let (primary, secondary) = image.extractPlayerGradientPalette()
        guard !Task.isCancelled, activeIdentifier == identifier else { return }

        let palette = PlayerBackgroundPalette(primary: primary, secondary: secondary)
        PlayerBackgroundPaletteStore.cache(palette, for: identifier)
        apply(palette, animated: true)
    }

    private func apply(_ palette: PlayerBackgroundPalette, animated: Bool) {
        let update = {
            rawPrimary = palette.primary
            rawSecondary = palette.secondary
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.6), update)
        } else {
            update()
        }
    }

    private func loadBackgroundImage() async -> UIImage? {
        if player.isRadioPlayback {
            return await loadRadioBackgroundImage()
        }
        guard let coverArtId = player.currentSong?.coverArt else { return nil }
        return await loadSongBackgroundImage(coverArtId: coverArtId)
    }

    private func loadSongBackgroundImage(coverArtId: String) async -> UIImage? {
        let key300 = "\(coverArtId)_300"
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: 300)
        if let cached = ImageCacheService.shared.cachedImage(key: key300, fallbackSizes: fallbackSizes) {
            return cached
        }
        if let localPath = LocalArtworkIndex.shared.localPath(for: coverArtId),
           let local = UIImage(contentsOfFile: localPath) {
            return local
        }
        if let cached = await ImageCacheService.shared.diskOnlyImage(key: key300, fallbackSizes: fallbackSizes) {
            return cached
        }
        if let url = SubsonicAPIService.shared.coverArtURL(for: coverArtId, size: 300),
           let image = await ImageCacheService.shared.image(url: url, key: key300) {
            return image
        }
        if let url = SubsonicAPIService.shared.coverArtURL(for: coverArtId, size: 80) {
            return await ImageCacheService.shared.image(url: url, key: "\(coverArtId)_80")
        }
        return nil
    }

    private func loadRadioBackgroundImage() async -> UIImage? {
        guard let station = player.currentRadioStation else { return nil }
        if station.usesDynamicSongCover,
           let url = player.currentRadioMetadata?.cacheBustedArtworkURL {
            let key = "radio_remote_\(url.absoluteString)"
            if let cached = ImageCacheService.shared.cachedImage(key: key) {
                return cached
            }
            if let image = await ImageCacheService.shared.image(url: url, key: key) {
                return image
            }
        }
        if let coverArtId = station.coverArt {
            return await loadSongBackgroundImage(coverArtId: coverArtId)
        }
        return nil
    }

}

extension UIImage {
    func extractPlayerGradientPalette() -> (UIColor, UIColor?) {
        let totalBuckets = 14
        let side = 32
        let totalPixels = side * side
        let minimumTonalBrightnessDifference: CGFloat = 0.10
        let neutralFallback = UIColor(white: 0.28, alpha: 1)
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImage = small.cgImage else { return (neutralFallback, nil) }

        var pixels = [UInt8](repeating: 0, count: totalPixels * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (neutralFallback, nil) }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rSum = [CGFloat](repeating: 0, count: totalBuckets)
        var gSum = [CGFloat](repeating: 0, count: totalBuckets)
        var bSum = [CGFloat](repeating: 0, count: totalBuckets)
        var counts = [Int](repeating: 0, count: totalBuckets)
        var chromaticSamples = [[PlayerPalettePixelSample]](repeating: [], count: 12)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[index]) / 255
            let g = CGFloat(pixels[index + 1]) / 255
            let b = CGFloat(pixels[index + 2]) / 255

            var h: CGFloat = 0
            var s: CGFloat = 0
            var v: CGFloat = 0
            var a: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)

            let bucket: Int
            if v < 0.15 {
                bucket = 12
            } else if v > 0.85, s < 0.12 {
                bucket = 13
            } else if s >= 0.15 {
                bucket = min(Int(h * 12), 11)
            } else {
                continue
            }

            rSum[bucket] += r
            gSum[bucket] += g
            bSum[bucket] += b
            counts[bucket] += 1

            if bucket < 12 {
                chromaticSamples[bucket].append(PlayerPalettePixelSample(
                    red: r,
                    green: g,
                    blue: b,
                    brightness: v
                ))
            }
        }

        func bucketColor(at index: Int) -> UIColor {
            let count = CGFloat(counts[index])
            return UIColor(red: rSum[index] / count, green: gSum[index] / count, blue: bSum[index] / count, alpha: 1)
        }

        func averageColor(of samples: ArraySlice<PlayerPalettePixelSample>) -> UIColor {
            let count = CGFloat(samples.count)
            let red = samples.reduce(CGFloat.zero) { $0 + $1.red } / count
            let green = samples.reduce(CGFloat.zero) { $0 + $1.green } / count
            let blue = samples.reduce(CGFloat.zero) { $0 + $1.blue } / count
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        }

        func brightness(of color: UIColor) -> CGFloat {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return brightness
        }

        func tonalPalette(from index: Int, minimumCount: Int) -> (UIColor, UIColor)? {
            let samples = chromaticSamples[index].sorted { $0.brightness < $1.brightness }
            let midpoint = samples.count / 2
            guard midpoint >= minimumCount,
                  samples.count - midpoint >= minimumCount
            else { return nil }

            let darker = averageColor(of: samples[..<midpoint])
            let lighter = averageColor(of: samples[midpoint...])
            guard brightness(of: lighter) - brightness(of: darker) >= minimumTonalBrightnessDifference else {
                return nil
            }
            return (lighter, darker)
        }

        let chromaticSorted = (0..<12)
            .filter { counts[$0] > 0 }
            .sorted { counts[$0] > counts[$1] }

        guard let primaryIndex = chromaticSorted.first else {
            return (neutralFallback, nil)
        }

        let primary = bucketColor(at: primaryIndex)
        let primaryCount = counts[primaryIndex]
        let minSecondaryCount = max(3, primaryCount / 10)
        let secondaryIndex = chromaticSorted
            .dropFirst()
            .filter { counts[$0] >= minSecondaryCount }
            .max { lhs, rhs in
                let lhsDiff = abs(lhs - primaryIndex)
                let rhsDiff = abs(rhs - primaryIndex)
                let lhsDistance = min(lhsDiff, 12 - lhsDiff)
                let rhsDistance = min(rhsDiff, 12 - rhsDiff)

                if lhsDistance == rhsDistance {
                    return counts[lhs] < counts[rhs]
                }
                return lhsDistance < rhsDistance
            }

        if let secondaryIndex {
            return (primary, bucketColor(at: secondaryIndex))
        }
        if let tonalColors = tonalPalette(from: primaryIndex, minimumCount: minSecondaryCount) {
            return tonalColors
        }
        return (primary, nil)
    }
}
