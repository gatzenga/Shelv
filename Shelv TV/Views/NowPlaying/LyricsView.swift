import SwiftUI

/// Lyrics-Vollbild — Stub (Task 11 baut die echte Lyrics-Anzeige via LyricsService).
struct LyricsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text(String(localized: "lyrics"))
                .font(.largeTitle).bold()
            Text("…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
