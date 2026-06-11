import SwiftUI

struct ServerManagementView: View {
    @EnvironmentObject var appState: AppState

    @State private var serverInfo: ServerInfo?
    @State private var scanStatus: ScanStatus?
    @State private var albumCount: Int?
    @State private var artistCount: Int?
    @State private var isLoadingInfo = true
    @State private var isScanning = false
    @State private var scanDone = false
    @State private var lastSyncDate: Date? = {
        let ts = UserDefaults.standard.double(forKey: "shelv_lastSync")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }()
    @State private var errorMessage: String?

    var body: some View {
        Form {
            // MARK: Server Info
            Section(String(localized: "connected_server")) {
                LabeledContent("URL") {
                    Text(appState.serverDisplayName)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent(String(localized: "user")) {
                    Text(appState.username)
                        .foregroundStyle(.secondary)
                }
                if isLoadingInfo {
                    LabeledContent(String(localized: "version")) {
                        ProgressView().controlSize(.small)
                    }
                } else if let info = serverInfo {
                    if let sv = info.serverVersion {
                        LabeledContent(String(localized: "version")) {
                            Text(sv + (info.serverType.map { " (\($0))" } ?? ""))
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("API") {
                        Text(info.apiVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Bibliothek
            Section(String(localized: "library")) {
                if isLoadingInfo {
                    LabeledContent(String(localized: "albums"))   { ProgressView().controlSize(.small) }
                    LabeledContent(String(localized: "artists")) { ProgressView().controlSize(.small) }
                    LabeledContent(String(localized: "tracks"))   { ProgressView().controlSize(.small) }
                } else {
                    if let c = albumCount {
                        LabeledContent(String(localized: "albums"))   { Text(String(c)).foregroundStyle(.secondary) }
                    }
                    if let c = artistCount {
                        LabeledContent(String(localized: "artists")) { Text(String(c)).foregroundStyle(.secondary) }
                    }
                    if let c = scanStatus?.count, c > 0 {
                        LabeledContent(String(localized: "tracks"))   { Text(String(c)).foregroundStyle(.secondary) }
                    }
                }
            }

            // MARK: Synchronisation
            Section(String(localized: "synchronisation")) {
                LabeledContent(String(localized: "last_sync")) {
                    if let date = lastSyncDate {
                        Text(date, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "never"))
                            .foregroundStyle(.secondary)
                    }
                }

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "scanning_library"))
                            .foregroundStyle(.secondary)
                    }
                } else if scanDone {
                    Label(String(localized: "sync_complete"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button {
                    Task { await runFullSync() }
                } label: {
                    Label(String(localized: "full_sync"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isScanning || !appState.isLoggedIn)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 640)
        .padding(.vertical, 8)
        .task { await loadInfo() }
    }

    // MARK: - Load

    private func loadInfo() async {
        isLoadingInfo = true
        let api = SubsonicAPIService.shared

        async let infoTask   = api.getServerInfo()
        async let statusTask = api.getScanStatus()
        async let artistTask = api.getAllArtists()
        async let albumTask  = loadAlbumCount(api: api)

        serverInfo  = try? await infoTask
        scanStatus  = try? await statusTask
        artistCount = try? await artistTask.count
        albumCount  = await albumTask

        isLoadingInfo = false
    }

    /// Paginiert durch getAlbumList und gibt die Gesamtanzahl zurück.
    private func loadAlbumCount(api: SubsonicAPIService) async -> Int {
        var total = 0
        var offset = 0
        let pageSize = 500
        while true {
            guard let page = try? await api.getAlbumList(
                type: .alphabeticalByName, size: pageSize, offset: offset
            ) else { break }
            total += page.count
            if page.count < pageSize { break }
            offset += pageSize
        }
        return total
    }

    // MARK: - Full Sync

    private func runFullSync() async {
        isScanning = true
        scanDone = false
        errorMessage = nil

        do {
            var status = try await SubsonicAPIService.shared.startScan()
            while status.scanning {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                status = try await SubsonicAPIService.shared.getScanStatus()
            }
            scanStatus = status
            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "shelv_lastSync")
            scanDone = true
            // Counts nach Sync aktualisieren
            await loadInfo()
        } catch {
            errorMessage = error.localizedDescription
        }

        isScanning = false
    }
}

#Preview {
    ServerManagementView()
        .environmentObject(AppState.shared)
}
