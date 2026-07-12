import SwiftUI
import UIKit

private final class TVPlayerPaletteResult: NSObject {
    let primary: UIColor
    let secondary: UIColor?

    init(_ primary: UIColor, _ secondary: UIColor?) {
        self.primary = primary
        self.secondary = secondary
    }
}

struct TVPlayerGradientBackground: View {
    enum Style {
        case standard
        case idle
    }

    let style: Style

    @ObservedObject private var player = AudioPlayerService.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var rawPrimary: UIColor?
    @State private var rawSecondary: UIColor?
    @State private var primaryColor = Color.black
    @State private var secondaryColor = Color.black
    @State private var activeIdentifier: String?

    private static let paletteCache: NSCache<NSString, TVPlayerPaletteResult> = {
        let cache = NSCache<NSString, TVPlayerPaletteResult>()
        cache.countLimit = 200
        return cache
    }()

    init(style: Style = .standard) {
        self.style = style
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
        .overlay {
            if style == .idle {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
            }
        }
        .task(id: backgroundLoadIdentifier) {
            await updateBackground()
        }
        .onChange(of: colorScheme) { _, _ in
            guard let rawPrimary else { return }
            primaryColor = adaptedColor(rawPrimary, asSecondary: false)
            secondaryColor = adaptedColor(rawSecondary ?? rawPrimary, asSecondary: true)
        }
    }

    private var backgroundIdentifier: String {
        if player.isRadioPlayback {
            guard let station = player.currentRadioStation else { return "radio-none" }
            if station.usesDynamicSongCover,
               let metadata = player.currentRadioMetadata,
               metadata.cacheBustedArtworkURL != nil {
                return "radio-art-\(metadata.artworkRevisionToken)"
            }
            if let coverArt = station.coverArt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !coverArt.isEmpty {
                return "radio-cover-\(coverArt)"
            }
            return "radio-station-\(station.id)"
        }
        return player.currentSong?.coverArt ?? "song-none"
    }

    private var backgroundLoadIdentifier: String {
        guard player.isRadioPlayback else { return backgroundIdentifier }
        return "\(backgroundIdentifier)|\(player.artworkReloadToken.uuidString)"
    }

    private func updateBackground() async {
        let identifier = backgroundIdentifier
        guard identifier != "song-none", identifier != "radio-none" else {
            activeIdentifier = nil
            rawPrimary = nil
            rawSecondary = nil
            withAnimation(.easeInOut(duration: 0.5)) {
                primaryColor = .black
                secondaryColor = .black
            }
            return
        }

        activeIdentifier = identifier

        if let hit = Self.paletteCache.object(forKey: identifier as NSString) {
            rawPrimary = hit.primary
            rawSecondary = hit.secondary
            withAnimation(.easeInOut(duration: 0.6)) {
                primaryColor = adaptedColor(hit.primary, asSecondary: false)
                secondaryColor = adaptedColor(hit.secondary ?? hit.primary, asSecondary: true)
            }
            return
        }

        let image = await loadBackgroundImage()
        guard !Task.isCancelled, activeIdentifier == identifier else { return }
        guard let image else {
            rawPrimary = nil
            rawSecondary = nil
            withAnimation(.easeInOut(duration: 0.5)) {
                primaryColor = .black
                secondaryColor = .black
            }
            return
        }

        let (primary, secondary) = image.extractTVPlayerPalette()
        guard !Task.isCancelled, activeIdentifier == identifier else { return }

        Self.paletteCache.setObject(TVPlayerPaletteResult(primary, secondary), forKey: identifier as NSString)
        rawPrimary = primary
        rawSecondary = secondary
        withAnimation(.easeInOut(duration: 0.6)) {
            primaryColor = adaptedColor(primary, asSecondary: false)
            secondaryColor = adaptedColor(secondary ?? primary, asSecondary: true)
        }
    }

    private func loadBackgroundImage() async -> UIImage? {
        if player.isRadioPlayback {
            return await loadRadioBackgroundImage()
        }
        guard let url = player.currentSong?.coverURL(900) else { return nil }
        return await loadImage(url: url, preferredSize: 900)
    }

    private func loadRadioBackgroundImage() async -> UIImage? {
        guard let station = player.currentRadioStation else { return nil }
        if station.usesDynamicSongCover,
           let url = player.currentRadioMetadata?.cacheBustedArtworkURL {
            return await loadImage(url: url, preferredSize: 900)
        }
        guard let coverArt = station.coverArt,
              let url = SubsonicAPIService.shared.coverArtURL(for: coverArt, size: 900)
        else { return nil }
        return await loadImage(url: url, preferredSize: 900)
    }

    private func loadImage(url: URL, preferredSize: Int) async -> UIImage? {
        let fallbackSizes = ImageCacheService.coverFallbackSizes(preferred: preferredSize)
        if let cached = ImageCacheService.shared.cachedImage(url: url, fallbackSizes: fallbackSizes) {
            return cached.image
        }
        if let disk = await ImageCacheService.shared.diskOnlyImageResult(url: url, fallbackSizes: fallbackSizes) {
            return disk.image
        }
        return await ImageCacheService.shared.image(url: url)
    }

    private func adaptedColor(_ uiColor: UIColor, asSecondary: Bool) -> Color {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var v: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let factor: CGFloat = asSecondary ? 0.88 : 1.0
        if colorScheme == .dark {
            return Color(UIColor(
                hue: h,
                saturation: min(s * 1.2 * factor, 0.90),
                brightness: min(max(v, 0.35) * 0.82, 0.72),
                alpha: 1
            ))
        } else {
            return Color(UIColor(
                hue: h,
                saturation: min(s * 0.82 * factor, 0.78),
                brightness: min(v * 0.45 + 0.58, 0.96),
                alpha: 1
            ))
        }
    }
}

private extension UIImage {
    func extractTVPlayerPalette() -> (UIColor, UIColor?) {
        let totalBuckets = 14
        let side = 32
        let totalPixels = side * side
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImage = small.cgImage else { return (.systemGray, nil) }

        var pixels = [UInt8](repeating: 0, count: totalPixels * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (.systemGray, nil) }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rSum = [CGFloat](repeating: 0, count: totalBuckets)
        var gSum = [CGFloat](repeating: 0, count: totalBuckets)
        var bSum = [CGFloat](repeating: 0, count: totalBuckets)
        var counts = [Int](repeating: 0, count: totalBuckets)

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
            if v < 0.20 {
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
        }

        func bucketColor(at index: Int) -> UIColor {
            let count = CGFloat(counts[index])
            return UIColor(red: rSum[index] / count, green: gSum[index] / count, blue: bSum[index] / count, alpha: 1)
        }

        let chromaticSorted = (0..<12)
            .filter { counts[$0] > 0 }
            .sorted { counts[$0] > counts[$1] }

        var primary: UIColor
        var secondary: UIColor?

        if let primaryIndex = chromaticSorted.first {
            let chromaticColor = bucketColor(at: primaryIndex)
            let chromaticCount = counts[primaryIndex]
            let minSecondaryCount = max(3, chromaticCount / 10)

            for candidateIndex in chromaticSorted.dropFirst() {
                let diff = abs(candidateIndex - primaryIndex)
                if min(diff, 12 - diff) >= 2, counts[candidateIndex] >= minSecondaryCount {
                    secondary = bucketColor(at: candidateIndex)
                    break
                }
            }

            if secondary != nil {
                primary = chromaticColor
            } else {
                let darkCount = counts[12]
                let lightCount = counts[13]
                let neutralIndex = darkCount >= lightCount ? 12 : 13
                let neutralCount = max(darkCount, lightCount)
                if neutralCount > 0 {
                    if neutralCount > chromaticCount {
                        primary = bucketColor(at: neutralIndex)
                        secondary = chromaticColor
                    } else {
                        primary = chromaticColor
                        secondary = bucketColor(at: neutralIndex)
                    }
                } else {
                    primary = chromaticColor
                }
            }
        } else {
            let darkCount = counts[12]
            let lightCount = counts[13]
            if darkCount >= lightCount {
                primary = darkCount > 0 ? bucketColor(at: 12) : .systemGray
                secondary = lightCount > 0 ? bucketColor(at: 13) : nil
            } else {
                primary = bucketColor(at: 13)
                secondary = darkCount > 0 ? bucketColor(at: 12) : nil
            }
        }

        if secondary == nil {
            var h: CGFloat = 0
            var s: CGFloat = 0
            var v: CGFloat = 0
            var a: CGFloat = 0
            primary.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            secondary = UIColor(
                hue: h,
                saturation: min(s * 0.8, 1.0),
                brightness: max(v * 0.45, 0.10),
                alpha: 1
            )
        }

        return (primary, secondary)
    }
}
