import SwiftUI

struct RadioView: View {
    @ObservedObject private var store = RadioStationStore.shared
    @ObservedObject private var player = AudioPlayerService.shared
    @Environment(\.themeColor) private var themeColor
    @AppStorage("radioViewIsGridMac") private var isGrid = false
    @AppStorage("radioSortDirectionMac") private var directionRaw = SortDirection.ascending.rawValue

    @State private var showAdd = false
    @State private var editingItem: RadioStationDisplayItem?
    @State private var deleteItem: RadioStationDisplayItem?
    @State private var isEditingStations = false

    private var direction: SortDirection { SortDirection(rawValue: directionRaw) ?? .ascending }
    private var displayItems: [RadioStationDisplayItem] {
        direction == .descending ? Array(store.items.reversed()) : store.items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Group {
                if store.isLoading && store.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayItems.isEmpty {
                    ContentUnavailableView(
                        String(localized: "no_radio_stations"),
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text(String(localized: "add_a_radio_station_to_get_started"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isGrid && !isEditingStations {
                    gridBody
                } else {
                    listBody
                }
            }
        }
        .navigationTitle(String(localized: "radio"))
        .task { await store.refresh() }
        .onChange(of: store.errorMessage) { _, message in
            guard let message else { return }
            NotificationCenter.default.post(name: .showToast, object: message)
        }
        .sheet(isPresented: $showAdd) {
            MacRadioStationEditorView(item: nil)
                .environment(\.themeColor, themeColor)
        }
        .sheet(item: $editingItem) { item in
            MacRadioStationEditorView(item: item)
                .environment(\.themeColor, themeColor)
        }
        .confirmationDialog(
            String(localized: "delete_radio_station"),
            isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                if let deleteItem {
                    Task { _ = await store.deleteStation(deleteItem) }
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(deleteItem?.name ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.items.count) \(String(localized: "stations"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.snappy) {
                    if isEditingStations {
                        isEditingStations = false
                    } else {
                        isGrid = false
                        isEditingStations = true
                    }
                }
            } label: {
                Image(systemName: isEditingStations ? "checkmark" : "pencil")
                    .font(.title3)
            }
            .help(isEditingStations ? String(localized: "done") : String(localized: "edit"))

            if !isEditingStations {
                Button {
                    directionRaw = direction == .ascending ? SortDirection.descending.rawValue : SortDirection.ascending.rawValue
                } label: {
                    Image(systemName: direction == .ascending ? "arrow.up" : "arrow.down")
                        .font(.title3)
                }
                .help(direction == .ascending ? String(localized: "ascending") : String(localized: "descending"))

                Button {
                    isGrid.toggle()
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                        .font(.title3)
                }
                .help(isGrid ? String(localized: "list") : String(localized: "grid"))

                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                }
                .help(String(localized: "new_radio_station"))
            }
        }
        .buttonStyle(.borderless)
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayItems) { item in
                    MacRadioStationRow(
                        item: item,
                        isActive: player.currentRadioStation?.id == item.id,
                        isEditing: isEditingStations,
                        delete: { deleteItem = item }
                    ) {
                        player.playRadioStation(item)
                    }
                    .contextMenu { contextMenu(for: item) }

                    if item.id != displayItems.last?.id {
                        Divider()
                            .padding(.leading, 84)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .animation(.snappy, value: displayItems.map(\.id))
    }

    private var gridBody: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 22)], alignment: .leading, spacing: 26) {
                ForEach(displayItems) { item in
                    Button {
                        player.playRadioStation(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            MacRadioStationArtworkView(
                                item: item,
                                size: 150,
                                metadata: nil
                            )
                                .overlay {
                                    MacRadioNowPlayingOverlay(stationId: item.id, size: 150, cornerRadius: 10)
                                }
                            Text(item.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                                .frame(width: 150, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: RadioStationDisplayItem) -> some View {
        Button {
            player.playRadioStation(item)
        } label: {
            Label(String(localized: "play"), systemImage: "play.fill")
        }
        Button {
            editingItem = item
        } label: {
            Label(String(localized: "edit"), systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleteItem = item
        } label: {
            Label(String(localized: "delete"), systemImage: "trash")
        }
    }
}

private struct MacRadioStationRow: View {
    let item: RadioStationDisplayItem
    let isActive: Bool
    let isEditing: Bool
    let delete: () -> Void
    let play: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            MacRadioStationArtworkView(item: item, size: 52, metadata: nil)
                .overlay {
                    MacRadioNowPlayingOverlay(stationId: item.id, size: 52, cornerRadius: 7)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(URL(string: item.streamURL)?.host ?? item.streamURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isEditing {
                Button(action: delete) {
                    Image(systemName: "trash.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color(NSColor.windowBackgroundColor)
            if isHovered {
                Color.primary.opacity(0.05)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !isEditing else { return }
            play()
        }
    }
}

private struct MacRadioNowPlayingOverlay: View {
    let stationId: String
    let size: CGFloat
    let cornerRadius: CGFloat

    @ObservedObject private var player = AudioPlayerService.shared

    private var isActive: Bool { player.currentRadioStation?.id == stationId }

    var body: some View {
        if isActive {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: size, height: size)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: player.isPlaying)
            }
        }
    }
}

struct MacRadioStationArtworkView: View {
    let item: RadioStationDisplayItem
    let size: CGFloat
    var metadata: RadioNowPlayingMetadata?
    var reloadToken: UUID? = nil

    var body: some View {
        if let remoteArtworkURL {
            CoverArtView(
                url: remoteArtworkURL,
                size: size,
                cornerRadius: size > 80 ? 10 : 7,
                reloadToken: reloadToken
            )
        } else if let coverArt = item.coverArt,
           let url = SubsonicAPIService.shared.coverArtURL(id: coverArt, size: Int(size * 3)) {
            CoverArtView(
                url: url,
                size: size,
                cornerRadius: size > 80 ? 10 : 7,
                reloadToken: reloadToken
            )
        } else {
            RoundedRectangle(cornerRadius: size > 80 ? 10 : 7, style: .continuous)
                .fill(.secondary.opacity(0.14))
                .overlay {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
        }
    }

    private var remoteArtworkURL: URL? {
        guard item.usesDynamicSongCover,
              let url = metadata?.cacheBustedArtworkURL
        else { return nil }
        return url
    }
}

private struct MacRadioStationEditorView: View {
    let item: RadioStationDisplayItem?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor
    @ObservedObject private var store = RadioStationStore.shared

    @State private var name = ""
    @State private var streamURL = ""
    @State private var useAzuraCastAPI = false
    @State private var azuraCastAPIURL = ""
    @State private var showSongCover = true
    @State private var isSaving = false

    private var isEditing: Bool { item != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !streamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? String(localized: "edit_radio_station") : String(localized: "new_radio_station"))
                    .font(.title2.bold())
                Spacer()
            }
            .padding(20)

            Form {
                Section {
                    TextField(String(localized: "name"), text: $name)
                    TextField(String(localized: "streaming_link"), text: $streamURL)
                } header: {
                    Text(String(localized: "stream_data"))
                }

                Section {
                    Toggle(String(localized: "use_azuracast_api"), isOn: $useAzuraCastAPI)
                    if useAzuraCastAPI {
                        TextField(String(localized: "api_url"), text: $azuraCastAPIURL)
                        Button {
                            if let derived = RadioStationMetadata.derivedAzuraCastAPIURL(from: streamURL) {
                                azuraCastAPIURL = derived
                            }
                        } label: {
                            Label(String(localized: "fill_api_url_from_stream_url"), systemImage: "wand.and.stars")
                        }
                        Toggle(String(localized: "show_song_cover"), isOn: $showSongCover)
                    }
                } header: {
                    Text(String(localized: "azuracast"))
                }

                Section {
                    MacAzuraCastInfoBox()
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(String(localized: "cancel")) { dismiss() }
                Button(String(localized: "save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 520, height: useAzuraCastAPI ? 610 : 480)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard let item else { return }
        name = item.name
        streamURL = item.streamURL
        useAzuraCastAPI = item.metadata.useAzuraCastAPI
        azuraCastAPIURL = item.metadata.azuraCastAPIURL
        showSongCover = item.metadata.showSongCover
    }

    private func save() {
        isSaving = true
        Task {
            let ok: Bool
            if let item {
                ok = await store.updateStation(
                    item,
                    name: name,
                    streamURL: streamURL,
                    useAzuraCastAPI: useAzuraCastAPI,
                    azuraCastAPIURL: azuraCastAPIURL,
                    showSongCover: showSongCover
                )
            } else {
                ok = await store.createStation(
                    name: name,
                    streamURL: streamURL,
                    useAzuraCastAPI: useAzuraCastAPI,
                    azuraCastAPIURL: azuraCastAPIURL,
                    showSongCover: showSongCover
                )
            }
            isSaving = false
            if ok { dismiss() }
        }
    }
}

private struct MacAzuraCastInfoBox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "azuracast_api_format"))
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Text(verbatim: "https://your-domain.com/api/nowplaying/station_shortcode")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "supported_formats"))
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Text(verbatim: "HLS, MP3, AAC")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
