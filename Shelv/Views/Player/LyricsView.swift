import SwiftUI

struct LyricsView: View {
    let record: LyricsRecord?
    let isLoading: Bool

    var body: some View {
        ZStack {
            if isLoading || record == nil {
                ProgressView()
            } else if let r = record {
                content(for: r)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for record: LyricsRecord) -> some View {
        if record.isInstrumental {
            placeholder(icon: "pianokeys", text: tr("Instrumental", "Instrumental"))
        } else if let text = record.plainText, !text.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(.callout)
                    .lineSpacing(6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
        } else {
            placeholder(icon: "text.page.slash", text: tr("No lyrics available", "Keine Lyrics verfügbar"))
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}
