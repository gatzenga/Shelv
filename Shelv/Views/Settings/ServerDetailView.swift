import SwiftUI

struct ServerDetailView: View {
    let server: SubsonicServer
    let password: String?

    @ObservedObject var libraryStore = LibraryStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var isScanning = false
    @State private var scanDone = false
    @State private var serverInfo: ServerInfo? = nil
    @State private var errorMessage: String? = nil

    private var lastSyncKey: String { "shelv_lastSync_\(server.id)" }
    private var songCountKey: String { "shelv_songCount_\(server.id)" }
    private var albumCountKey: String { "shelv_albumCount_\(server.id)" }
    private var artistCountKey: String { "shelv_artistCount_\(server.id)" }

    private var lastSync: Date? {
        let t = UserDefaults.standard.double(forKey: lastSyncKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    private var storedSongCount: Int { UserDefaults.standard.integer(forKey: songCountKey) }
    private var storedAlbumCount: Int { UserDefaults.standard.integer(forKey: albumCountKey) }
    private var storedArtistCount: Int { UserDefaults.standard.integer(forKey: artistCountKey) }

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private let api = SubsonicAPIService.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "full_scan"))
                                .font(.headline)
                            if let lastSync {
                                Text(
                                    String(localized: "last_sync_2")
                                    + lastSync.formatted(date: .abbreviated, time: .shortened)
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                Text(String(localized: "never_synced"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if isScanning {
                            ProgressView()
                        } else if scanDone {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title2)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    if isScanning {
                        Text(String(localized: "scanning_library"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await runFullScan() }
                    } label: {
                        Text(String(localized: "start_full_scan"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .disabled(isScanning || password == nil)
                }
                .padding(.vertical, 4)
                .animation(.easeInOut, value: scanDone)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section(String(localized: "library")) {
                infoRow(
                    icon: "square.stack",
                    label: String(localized: "albums"),
                    value: storedAlbumCount > 0 ? "\(storedAlbumCount)" : (libraryStore.albums.isEmpty ? "—" : "\(libraryStore.albums.count)")
                )
                infoRow(
                    icon: "music.mic",
                    label: String(localized: "artists"),
                    value: storedArtistCount > 0 ? "\(storedArtistCount)" : (libraryStore.artists.isEmpty ? "—" : "\(libraryStore.artists.count)")
                )
                infoRow(
                    icon: "music.note",
                    label: String(localized: "tracks"),
                    value: storedSongCount > 0 ? "\(storedSongCount)" : "—"
                )
            }

            Section(String(localized: "server")) {
                infoRow(
                    icon: "cpu",
                    label: "Navidrome",
                    value: serverInfo?.serverVersion ?? "—"
                )
                infoRow(
                    icon: "antenna.radiowaves.left.and.right",
                    label: String(localized: "api_version"),
                    value: serverInfo?.apiVersion ?? "—"
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadServerInfo()
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func loadServerInfo() async {
        guard let password else { return }
        async let infoTask   = api.ping(server: server, password: password)
        async let statusTask = api.getScanStatus(server: server, password: password)
        serverInfo = try? await infoTask
        if let status = try? await statusTask, status.count > 0 {
            UserDefaults.standard.set(status.count, forKey: songCountKey)
        }
    }

    private func runFullScan() async {
        guard let password else { return }
        isScanning = true
        scanDone = false
        errorMessage = nil
        do {
            try await api.startScan(server: server, password: password)
            var attempts = 0
            let maxAttempts = 60
            while attempts < maxAttempts {
                let status = try await api.getScanStatus(server: server, password: password)
                if !status.scanning {
                    if status.count > 0 {
                        UserDefaults.standard.set(status.count, forKey: songCountKey)
                    }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncKey)
                    break
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                attempts += 1
            }
            if attempts >= maxAttempts {
                throw SubsonicAPIError.apiError(0, String(localized: "scan_timed_out_after_2_minutes"))
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await libraryStore.loadAlbums() }
                group.addTask { await libraryStore.loadArtists() }
                group.addTask { await libraryStore.loadDiscover() }
            }
            isScanning = false
            scanDone = true
        } catch {
            isScanning = false
            errorMessage = error.localizedDescription
        }
    }
}
