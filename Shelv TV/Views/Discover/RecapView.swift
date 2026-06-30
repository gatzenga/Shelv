import SwiftUI

/// Recap-Playlists, geöffnet über Discover wenn `recapEnabled` aktiv ist.
/// Segmentiert nach Weekly/Monthly/Yearly (wie der Library-Picker),
/// innerhalb der Periode neueste zuerst.
struct RecapView: View {
    @ObservedObject var library = LibraryStore.shared
    @ObservedObject var recap = RecapStore.shared

    @State private var segment = 0   // 0 = Weekly, 1 = Monthly, 2 = Yearly
    private let periodTypes = ["week", "month", "year"]

    /// Periode (Typ + Zeitraum) zum Registry-Eintrag einer Recap-Playlist — liefert
    /// Periodentitel + Playcount-Zeitfenster, exakt wie iOS.
    private func period(for playlist: Playlist) -> RecapPeriod? {
        guard let e = recap.entries.first(where: { $0.playlistId == playlist.id }),
              let type = RecapPeriod.PeriodType(rawValue: e.periodType) else { return nil }
        return RecapPeriod(type: type,
                           start: Date(timeIntervalSince1970: e.periodStart),
                           end: Date(timeIntervalSince1970: e.periodEnd))
    }

    /// Recap-Playlists der gewählten Periode, nach Periodenstart absteigend.
    private var recapPlaylists: [Playlist] {
        let type = periodTypes[segment]
        let entries = recap.entries.filter { $0.periodType == type }
        let order = Dictionary(entries.map { ($0.playlistId, $0.periodStart) }) { a, _ in a }
        return library.playlists
            .filter { order[$0.id] != nil }
            .sorted { (order[$0.id] ?? 0) > (order[$1.id] ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                Text(String(localized: "weekly")).tag(0)
                Text(String(localized: "monthly")).tag(1)
                Text(String(localized: "yearly")).tag(2)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 700)
            .padding(.top, 40)
            .padding(.bottom, 24)
            // Eigene Fokus-Sektion: Runter landet immer im Inhalt darunter, Hoch immer
            // zurück auf die Periodenleiste — auch wenn horizontal nichts direkt darüber/
            // darunter sitzt (sonst springt der Fokus an der Periodenleiste vorbei).
            .focusSection()

            ScrollView {
                if recapPlaylists.isEmpty {
                    ContentUnavailableView(
                        String(localized: "no_recaps_yet"),
                        systemImage: "sparkles.rectangle.stack"
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                        ForEach(recapPlaylists) { PlaylistCard(playlist: $0, recapPeriod: period(for: $0)) }
                    }
                    .padding(.horizontal, 50)
                    .padding(.top, 30)
                    .padding(.bottom, 50)
                    // Eigene Fokus-Sektion: Runter-Navigation vom Segment-Picker landet
                    // zuverlässig auf der (ggf. einzelnen, links sitzenden) Playlist.
                    .focusSection()
                }
            }
        }
        .navigationTitle("")
        .task(id: library.reloadID) { await library.loadPlaylists() }
    }
}
