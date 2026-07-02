import SwiftUI
import UIKit

struct RadioStationsView: View {
    @ObservedObject private var store = RadioStationStore.shared
    @ObservedObject private var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("radioSortDirection") private var sortDirectionRaw = SortDirection.ascending.rawValue

    @State private var showAddStation = false
    @State private var editingItem: RadioStationDisplayItem?
    @State private var deleteItem: RadioStationDisplayItem?
    @State private var toast: ShelveToast?

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var sortDirection: SortDirection { SortDirection(rawValue: sortDirectionRaw) ?? .ascending }
    private var displayItems: [RadioStationDisplayItem] {
        sortDirection == .descending ? Array(store.items.reversed()) : store.items
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayItems.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "no_radio_stations"), systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(String(localized: "add_a_radio_station_to_get_started"))
                    } actions: {
                        Button {
                            showAddStation = true
                        } label: {
                            Label(String(localized: "new_radio_station"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    listBody
                }
            }
            .navigationTitle(String(localized: "radio_stations"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker(selection: $sortDirectionRaw) {
                            ForEach(SortDirection.allCases, id: \.rawValue) { direction in
                                Text(direction.label).tag(direction.rawValue)
                            }
                        } label: {
                            Label(String(localized: "direction"), systemImage: "arrow.up.and.down")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    Button {
                        showAddStation = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await store.refresh() }
            .refreshable {
                async let reload: Void = store.refresh()
                async let sync: Void = CloudKitSyncService.shared.syncNow()
                _ = await (reload, sync)
            }
            .onChange(of: store.errorMessage) { _, message in
                guard let message else { return }
                toast = ShelveToast(message: message, isError: true)
            }
            .sheet(isPresented: $showAddStation) {
                RadioStationEditorView(item: nil)
                    .presentationSizing(.page)
                    .presentationCornerRadius(24)
                    .presentationDragIndicator(.visible)
                    .tint(accentColor)
            }
            .sheet(item: $editingItem) { item in
                RadioStationEditorView(item: item)
                    .presentationSizing(.page)
                    .presentationCornerRadius(24)
                    .presentationDragIndicator(.visible)
                    .tint(accentColor)
            }
            .alert(
                String(localized: "delete_radio_station"),
                isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }),
                presenting: deleteItem
            ) { item in
                Button(String(localized: "delete"), role: .destructive) {
                    Task {
                        if await store.deleteStation(item) {
                            toast = ShelveToast(message: String(localized: "radio_station_deleted"))
                        }
                    }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { item in
                Text("\"\(item.name)\"")
            }
            .shelveToast($toast)
        }
    }

    private var listBody: some View {
        List {
            ForEach(displayItems) { item in
                radioRow(item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        play(item)
                    }
                .contextMenu { contextMenu(for: item) }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        deleteItem = item
                    } label: {
                        Label(String(localized: "delete"), systemImage: "trash")
                    }
                    .tint(.red)

                    Button {
                        editingItem = item
                    } label: {
                        Label(String(localized: "edit"), systemImage: "pencil")
                    }
                    .tint(accentColor)
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .animation(.snappy, value: displayItems.map(\.id))
    }

    private func radioRow(_ item: RadioStationDisplayItem) -> some View {
        HStack(spacing: 12) {
            radioArtwork(item, size: 56)
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
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
    }

    private func radioArtwork(_ item: RadioStationDisplayItem, size: CGFloat) -> some View {
        let cornerRadius: CGFloat = size > 80 ? 10 : 7
        return RadioStationArtworkView(item: item, size: size, metadata: nil)
            .overlay {
                RadioNowPlayingOverlay(stationId: item.id, size: size, cornerRadius: cornerRadius)
            }
    }

    @ViewBuilder
    private func contextMenu(for item: RadioStationDisplayItem) -> some View {
        Button {
            play(item)
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

    private func play(_ item: RadioStationDisplayItem) {
        guard URL(string: item.streamURL) != nil else {
            toast = ShelveToast(message: String(localized: "invalid_stream_url"), isError: true)
            return
        }
        player.playRadioStation(item)
    }
}

struct RadioStationArtworkView: View {
    let item: RadioStationDisplayItem
    let size: CGFloat
    var metadata: RadioNowPlayingMetadata?

    var body: some View {
        let cornerRadius: CGFloat = size > 80 ? 10 : 7
        ZStack {
            if let remoteArtworkURL {
                RemoteRadioArtworkView(url: remoteArtworkURL, size: size, cornerRadius: cornerRadius) {
                    fallbackArtwork(cornerRadius: cornerRadius)
                }
            } else {
                fallbackArtwork(cornerRadius: cornerRadius)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var remoteArtworkURL: URL? {
        guard item.usesDynamicSongCover,
              let url = metadata?.cacheBustedArtworkURL
        else { return nil }
        return url
    }

    @ViewBuilder
    private func fallbackArtwork(cornerRadius: CGFloat) -> some View {
        if let coverArt = item.coverArt {
            AlbumArtView(coverArtId: coverArt, size: Int(size * 3), cornerRadius: cornerRadius)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.secondary.opacity(0.14))
                .overlay {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct RemoteRadioArtworkView<Fallback: View>: View {
    let url: URL
    let size: CGFloat
    let cornerRadius: CGFloat
    @ViewBuilder var fallback: () -> Fallback

    @State private var image: UIImage?
    @State private var loadedURLString: String?
    @State private var activeLoadURLString: String?

    init(url: URL, size: CGFloat, cornerRadius: CGFloat, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.url = url
        self.size = size
        self.cornerRadius = cornerRadius
        self.fallback = fallback
        let cachedImage = ImageCacheService.shared.cachedImage(key: Self.cacheKey(for: url))
        self._image = State(initialValue: cachedImage)
        self._loadedURLString = State(initialValue: cachedImage == nil ? nil : url.absoluteString)
    }

    var body: some View {
        let urlString = url.absoluteString
        ZStack {
            if let image, loadedURLString == urlString {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            let key = Self.cacheKey(for: url)
            activeLoadURLString = urlString
            if let cached = ImageCacheService.shared.cachedImage(key: key) {
                image = cached
                loadedURLString = urlString
                return
            }
            image = nil
            loadedURLString = nil
            let loaded = await ImageCacheService.shared.image(url: url, key: key)
            guard !Task.isCancelled, activeLoadURLString == urlString else { return }
            image = loaded
            loadedURLString = loaded == nil ? nil : urlString
        }
    }

    private static func cacheKey(for url: URL) -> String {
        "radio_remote_\(url.absoluteString)"
    }
}

private struct RadioStationEditorView: View {
    let item: RadioStationDisplayItem?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RadioStationStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var name = ""
    @State private var streamURL = ""
    @State private var useAzuraCastAPI = false
    @State private var azuraCastAPIURL = ""
    @State private var showSongCover = true
    @State private var isSaving = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var isEditing: Bool { item != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !streamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "name"), text: $name)
                        .autocorrectionDisabled()
                    TextField(String(localized: "streaming_link"), text: $streamURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text(String(localized: "stream_data"))
                }

                Section {
                    Toggle(String(localized: "use_azuracast_api"), isOn: $useAzuraCastAPI)
                        .tint(accentColor)
                    if useAzuraCastAPI {
                        TextField(String(localized: "api_url"), text: $azuraCastAPIURL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            if let derived = RadioStationMetadata.derivedAzuraCastAPIURL(from: streamURL) {
                                azuraCastAPIURL = derived
                            }
                        } label: {
                            Label(String(localized: "fill_api_url_from_stream_url"), systemImage: "wand.and.stars")
                        }
                        Toggle(String(localized: "show_song_cover"), isOn: $showSongCover)
                            .tint(accentColor)
                    }
                } header: {
                    Text(String(localized: "azuracast"))
                }

                Section {
                    AzuraCastInfoBox()
                }
            }
            .navigationTitle(isEditing ? String(localized: "edit_radio_station") : String(localized: "new_radio_station"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save")) { save() }
                        .disabled(!canSave)
                }
            }
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

private struct RadioNowPlayingOverlay: View {
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

private struct AzuraCastInfoBox: View {
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
