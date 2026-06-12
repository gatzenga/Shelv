import SwiftUI
import UIKit

/// Einzeiliger Text, der bei Überlänge horizontal durchläuft (Marquee) statt mit „…"
/// abzuschneiden. Passt der Text in die verfügbare Breite, wird er statisch (per
/// `alignment`) angezeigt — kein unnötiges Scrollen.
///
/// Messung über `UIFont` (zuverlässiger als GeometryReader-Textmessung); zwei gegen-
/// phasige Kopien erzeugen einen nahtlosen Loop. Pattern nach joekndy/MarqueeText (MIT).
struct MarqueeText: View {
    let text: String
    /// Font für Anzeige UND Breitenmessung — beide aus derselben Quelle, kein Drift.
    var uiFont: UIFont
    var color: Color = .primary
    /// Ausrichtung, wenn der Text passt (nicht scrollt).
    var alignment: Alignment = .center
    /// Pause am Schleifenanfang, bevor es losläuft.
    var startDelay: Double = 1.4
    /// Scroll-Geschwindigkeit in Punkten pro Sekunde.
    var velocity: Double = 30

    @State private var animate = false

    private var stringWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: uiFont]).width
    }
    private var stringHeight: CGFloat {
        (text as NSString).size(withAttributes: [.font: uiFont]).height
    }

    var body: some View {
        // Lücke zwischen den zwei Lauf-Kopien.
        let gap = stringHeight * 2

        GeometryReader { geo in
            let needsScroll = stringWidth > geo.size.width

            Group {
                if needsScroll {
                    let anim = Animation
                        .linear(duration: Double(stringWidth + gap) / velocity)
                        .delay(startDelay)
                        .repeatForever(autoreverses: false)

                    ZStack(alignment: .leading) {
                        label.offset(x: animate ? -stringWidth - gap : 0)
                        label.offset(x: animate ? 0 : stringWidth + gap)
                    }
                    .animation(animate ? anim : .none, value: animate)
                    .onAppear {
                        // einen Tick warten, damit der Layout-Pass durch ist
                        DispatchQueue.main.async { animate = true }
                    }
                } else {
                    label.frame(width: geo.size.width, alignment: alignment)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            .onChange(of: text) { _, _ in
                animate = false
                DispatchQueue.main.async {
                    if stringWidth > geo.size.width { animate = true }
                }
            }
        }
        .frame(height: stringHeight)
    }

    private var label: some View {
        Text(text)
            .font(Font(uiFont as CTFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
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
