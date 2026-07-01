import SwiftUI

struct RadioView: View {
    @ObservedObject private var store = RadioStationStore.shared
    @ObservedObject private var player = AudioPlayerService.shared
    @AppStorage("radioSortDirectionTV") private var dirRaw = "ascending"
    @AppStorage("radioViewIsGridTV") private var isGrid = true

    @State private var showCreate = false
    @State private var editingItem: RadioStationDisplayItem?
    @State private var deleteItem: RadioStationDisplayItem?

    private var dir: SortDirection { SortDirection(rawValue: dirRaw) ?? .ascending }
    private var displayItems: [RadioStationDisplayItem] {
        dir == .descending ? Array(store.items.reversed()) : store.items
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Button {
                    dirRaw = dir == .ascending ? "descending" : "ascending"
                } label: {
                    Image(systemName: dir.icon)
                }
                Button {
                    isGrid.toggle()
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                }
                Spacer()
                Button {
                    showCreate = true
                } label: {
                    Label(String(localized: "new_radio_station"), systemImage: "plus")
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 50)
            .padding(.top, 40)
            .padding(.bottom, 16)
            .focusSection()

            Group {
                if displayItems.isEmpty && store.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayItems.isEmpty, let message = store.errorMessage {
                    ContentUnavailableView(
                        String(localized: "error"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayItems.isEmpty {
                    ContentUnavailableView(String(localized: "no_radio_stations"), systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isGrid {
                    gridBody
                } else {
                    listBody
                }
            }
            .focusSection()
        }
        .task { await store.refresh() }
        .sheet(isPresented: $showCreate) {
            TVRadioStationEditSheet(item: nil)
        }
        .sheet(item: $editingItem) { item in
            TVRadioStationEditSheet(item: item)
        }
        .confirmationDialog(String(localized: "delete_radio_station"), isPresented: Binding(
            get: { deleteItem != nil },
            set: { if !$0 { deleteItem = nil } }
        ), titleVisibility: .visible) {
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

    private var gridBody: some View {
        ScrollView {
            LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                ForEach(displayItems) { item in
                    TVRadioStationCard(
                        item: item,
                        isPlaying: player.currentRadioStation?.id == item.id && player.isPlaying,
                        play: { player.playRadioStation(item) },
                        edit: { editingItem = item },
                        delete: { deleteItem = item }
                    )
                }
            }
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 50)
        }
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(displayItems) { item in
                    TVRadioStationListRow(
                        item: item,
                        isCurrent: player.currentRadioStation?.id == item.id,
                        isPlaying: player.isPlaying,
                        play: { player.playRadioStation(item) }
                    ) {
                        contextMenu(for: item)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
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
        Divider()
        Button(role: .destructive) {
            deleteItem = item
        } label: {
            Label(String(localized: "delete"), systemImage: "trash")
        }
    }
}

private struct TVRadioStationListRow<ContextMenuContent: View>: View {
    let item: RadioStationDisplayItem
    let isCurrent: Bool
    let isPlaying: Bool
    let play: () -> Void
    @ViewBuilder let contextMenu: () -> ContextMenuContent
    @AppStorage("themeColor") private var themeColor = "violet"

    var body: some View {
        HStack(spacing: 20) {
            TVRadioStationArtworkView(item: item, size: 80, metadata: nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1)
                Text(URL(string: item.streamURL)?.host ?? item.streamURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.body)
                    .foregroundStyle(AppTheme.color(for: themeColor))
                    .symbolEffect(.variableColor.iterative.reversing, isActive: isPlaying)
            }
        }
        .rowButton(action: play)
        .contextMenu { contextMenu() }
    }
}

private struct TVRadioStationCard: View {
    let item: RadioStationDisplayItem
    let isPlaying: Bool
    let play: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(action: play) {
                TVRadioStationArtworkView(item: item, size: 240, metadata: nil)
                    .overlay {
                        if isPlaying {
                            TVRadioNowPlayingOverlay(size: 240, cornerRadius: 8)
                        }
                    }
            }
            .buttonStyle(.card)
            .contextMenu {
                Button(String(localized: "edit"), action: edit)
                Divider()
                Button(String(localized: "delete"), role: .destructive, action: delete)
            }

            Text(item.name)
                .lineLimit(1)
                .font(.callout)
            Text(URL(string: item.streamURL)?.host ?? item.streamURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 240)
    }
}

private struct TVRadioNowPlayingOverlay: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.42))

            Image(systemName: "waveform")
                .font(.system(size: size * 0.28, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                .scaleEffect(isAnimating ? 1.08 : 0.94)
                .opacity(isAnimating ? 1.0 : 0.72)
                .animation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true), value: isAnimating)
                .onAppear { isAnimating = true }
                .onDisappear { isAnimating = false }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct TVRadioStationArtworkView: View {
    let item: RadioStationDisplayItem
    let size: CGFloat
    var metadata: RadioNowPlayingMetadata?

    var body: some View {
        if let remoteArtworkURL {
            CoverArtView(url: remoteArtworkURL, size: size, cornerRadius: 8)
        } else if let coverArt = item.coverArt,
           let url = SubsonicAPIService.shared.coverArtURL(for: coverArt, size: Int(size * 2)) {
            CoverArtView(url: url, size: size, cornerRadius: 8)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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

private struct TVRadioStationEditSheet: View {
    let item: RadioStationDisplayItem?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RadioStationStore.shared

    @State private var name: String = ""
    @State private var streamURL: String = ""
    @State private var useAzuraCastAPI = false
    @State private var azuraCastAPIURL = ""
    @State private var showSongCover = true
    @State private var isSaving = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedStreamURL: String { streamURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 30) {
                TextField(String(localized: "name"), text: $name)
                TextField(String(localized: "streaming_link"), text: $streamURL)
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
                HStack(spacing: 30) {
                    Button(String(localized: "cancel"), role: .cancel) { dismiss() }
                    Button(String(localized: "done")) { save() }
                        .disabled(trimmedName.isEmpty || trimmedStreamURL.isEmpty || isSaving)
                }
                Spacer()
            }
            .padding(80)
            .onAppear(perform: prefill)
        }
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
