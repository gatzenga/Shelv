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
            placeholder(icon: "pianokeys", text: String(localized: "instrumental"))
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
            placeholder(icon: "text.page.slash", text: String(localized: "no_lyrics_available"))
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
