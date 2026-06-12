import SwiftUI

struct InsightsView: View {
    private let api = SubsonicAPIService.shared
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 40)]

    @State private var topAlbums: [Album] = []
    @State private var totalPlays = 0
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 6) {
                    Text("\(totalPlays)")
                        .font(.system(size: 90, weight: .bold))
                        .foregroundStyle(.tint)
                    Text(String(localized: "total_plays"))
                        .font(.title3).foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)

                if !topAlbums.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(String(localized: "most_played"))
                            .font(.title2).bold()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: columns, spacing: 40) {
                            ForEach(topAlbums) { AlbumCard(album: $0) }
                        }
                    }
                }
            }
            .padding(50)
        }
        .navigationTitle(String(localized: "insights"))
        .task { await load() }
    }

    private func load() async {
        topAlbums = (try? await api.getAlbumList(type: "frequent", size: 24)) ?? []
        if let sid = api.activeServer?.stableId, !sid.isEmpty {
            totalPlays = await PlayLogService.shared.logCount(serverId: sid)
        }
        isLoading = false
    }
}
