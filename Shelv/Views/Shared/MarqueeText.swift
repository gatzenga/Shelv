import SwiftUI
import UIKit

/// Einzeiliger Text, der bei Überlänge horizontal durchläuft (Marquee) statt mit „…"
/// abzuschneiden. Passt der Text in die verfügbare Breite, wird er statisch (per
/// `alignment`) angezeigt — kein unnötiges Scrollen.
///
/// Zwei identische Textkopien bilden ein durchgehendes Band. Nach einem vollständigen
/// Durchlauf liegt die zweite Kopie exakt an der Startposition der ersten; der
/// anschließende, animationsfreie Reset ist dadurch unsichtbar. Der Zyklus gehört zu
/// einer SwiftUI-Task und wird bei Text-, Layout- oder Identitätswechsel abgebrochen.
struct MarqueeText: View {
    let text: String
    /// Font für Anzeige UND Breitenmessung — beide aus derselben Quelle, kein Drift.
    var uiFont: UIFont
    var color: Color = .primary
    /// Ausrichtung, wenn der Text passt (nicht scrollt).
    var alignment: Alignment = .center
    /// Pause an der Startposition vor jedem Durchlauf.
    var startDelay: Double = 1.4
    /// Scroll-Geschwindigkeit in Punkten pro Sekunde.
    var velocity: Double = 30
    /// Optionaler fachlicher Reset, etwa die Song-ID bei gleichlautenden Titeln.
    var resetID: AnyHashable?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        text: String,
        uiFont: UIFont,
        color: Color = .primary,
        alignment: Alignment = .center,
        startDelay: Double = 1.4,
        velocity: Double = 30,
        resetID: AnyHashable? = nil
    ) {
        self.text = text
        self.uiFont = uiFont
        self.color = color
        self.alignment = alignment
        self.startDelay = startDelay
        self.velocity = velocity
        self.resetID = resetID
    }

    private var stringWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: uiFont]).width)
    }

    private var stringHeight: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: uiFont]).height)
    }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width)
            let needsScroll = availableWidth > 0 && stringWidth > availableWidth + 0.5

            Group {
                if needsScroll && !reduceMotion {
                    let gap = min(stringHeight * 2, availableWidth * 0.25)
                    let identity = MarqueeCycleIdentity(
                        text: text,
                        resetID: resetID,
                        availableWidth: availableWidth,
                        fontName: uiFont.fontName,
                        fontSize: uiFont.pointSize,
                        startDelay: startDelay,
                        velocity: velocity
                    )

                    ScrollingMarqueeTrack(
                        text: text,
                        uiFont: uiFont,
                        color: color,
                        textWidth: stringWidth,
                        gap: gap,
                        startDelay: startDelay,
                        velocity: velocity
                    )
                    // Eine neue Identität setzt den Offset vor dem ersten sichtbaren Frame
                    // zurück. So kann die Animationsphase des alten Songs nie weiterleben.
                    .id(identity)
                } else {
                    staticLabel(scaleToFit: needsScroll)
                }
            }
            .frame(width: availableWidth, height: stringHeight, alignment: .leading)
            .clipped()
        }
        .frame(height: stringHeight)
    }

    private func staticLabel(scaleToFit: Bool) -> some View {
        Text(text)
            .font(Font(uiFont as CTFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .allowsTightening(scaleToFit)
            .minimumScaleFactor(scaleToFit ? 0.7 : 1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct MarqueeCycleIdentity: Hashable {
    let text: String
    let resetID: AnyHashable?
    let availableWidth: CGFloat
    let fontName: String
    let fontSize: CGFloat
    let startDelay: Double
    let velocity: Double
}

private struct ScrollingMarqueeTrack: View {
    let text: String
    let uiFont: UIFont
    let color: Color
    let textWidth: CGFloat
    let gap: CGFloat
    let startDelay: Double
    let velocity: Double

    @State private var offset: CGFloat = 0

    private var scrollDistance: CGFloat { textWidth + gap }
    private var scrollDuration: Double {
        Double(scrollDistance) / max(velocity, 1)
    }

    var body: some View {
        HStack(spacing: gap) {
            label
            label.accessibilityHidden(true)
        }
        .fixedSize(horizontal: true, vertical: true)
        .offset(x: offset)
        .task {
            await runAnimationCycle()
        }
    }

    private var label: some View {
        Text(text)
            .font(Font(uiFont as CTFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .frame(width: textWidth, alignment: .leading)
    }

    @MainActor
    private func runAnimationCycle() async {
        resetOffset()

        while !Task.isCancelled {
            guard await wait(for: max(0, startDelay)) else { return }

            withAnimation(.linear(duration: scrollDuration)) {
                offset = -scrollDistance
            }

            guard await wait(for: scrollDuration) else { return }
            resetOffset()
        }
    }

    @MainActor
    private func wait(for seconds: Double) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(for: .seconds(seconds))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    @MainActor
    private func resetOffset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
        }
    }
}

extension UIFont {
    /// Dynamic-Type-fähige UIFont aus einem TextStyle, optional fett.
    static func preferred(_ style: UIFont.TextStyle, bold: Bool = false) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        guard bold, let d = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
        return UIFont(descriptor: d, size: 0)
    }
}
