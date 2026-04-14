import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var player: AudioPlayerService
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var showAddServer = false
    @State private var editingServer: SubsonicServer?
    @State private var managingServer: SubsonicServer?
    @State private var showDeleteConfirm = false
    @State private var serverToDelete: SubsonicServer?
    @State private var showClearToast = false
    @State private var showClearCacheConfirm = false
    @State private var cacheSize = "—"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        ZStack {
        NavigationStack {
            List {
                Section(tr("Servers", "Server")) {
                    ForEach(serverStore.servers) { server in
                        serverRow(server)
                    }
                    Button {
                        showAddServer = true
                    } label: {
                        Label(tr("Add Server", "Server hinzufügen"), systemImage: "plus.circle")
                            .foregroundStyle(accentColor)
                    }
                }

                Section(tr("Appearance", "Erscheinungsbild")) {
                    Picker(tr("Appearance", "Erscheinungsbild"), selection: $appAppearance) {
                        Text(tr("System", "System")).tag("system")
                        Text(tr("Light", "Hell")).tag("light")
                        Text(tr("Dark", "Dunkel")).tag("dark")
                    }
                    .id(appAppearance + themeColorName)
                    Picker(tr("Accent Color", "Akzentfarbe"), selection: $themeColorName) {
                        ForEach(AppTheme.options, id: \.name) { option in
                            HStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 14, height: 14)
                                Text(appLang == "de" ? option.nameDE : option.nameEN)
                            }
                            .tag(option.name)
                        }
                    }
                    .id(themeColorName)
                }

                Section(tr("Cache", "Cache")) {
                    HStack {
                        Label(tr("Cache Size", "Cache-Größe"), systemImage: "internaldrive")
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Label(tr("Clear Cache", "Cache leeren"), systemImage: "trash")
                    }
                    .tint(.red)
                }

                Section(tr("Links & Contact", "Links & Kontakt")) {
                    SettingsLinkRow(icon: "chevron.left.forwardslash.chevron.right", label: "GitHub",
                                   urlString: "https://github.com/GatzeStreicheln/Shelv")
                    SettingsLinkRow(icon: "envelope", label: tr("Contact", "Kontakt"),
                                   urlString: "mailto:kontakt@vkugler.ch")
                }

                Section("Info") {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
                    Text("Shelv \(version) (\(build))")
                    Text(tr(
                        "Shelv is an unofficial Navidrome client and has no affiliation with Navidrome or its developers.",
                        "Shelv ist ein inoffizieller Navidrome-Client und steht in keiner Verbindung zu Navidrome oder dessen Entwicklern."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Color.clear
                    .frame(height: player.currentSong != nil ? 90 : 16)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollIndicators(.hidden)
            .navigationTitle(tr("Settings", "Einstellungen"))
            .task { await recalculateCacheSize() }
            .sheet(isPresented: $showAddServer) {
                AddServerView()
                    .environmentObject(serverStore)
                    .tint(accentColor)
            }
            .sheet(item: $editingServer) { server in
                AddServerView(editingServer: server)
                    .environmentObject(serverStore)
                    .tint(accentColor)
            }
            .sheet(item: $managingServer) { server in
                NavigationStack {
                    ServerDetailView(
                        server: server,
                        password: serverStore.password(for: server)
                    )
                    .environmentObject(libraryStore)
                    .tint(accentColor)
                }
            }
            .alert(
                tr("Delete Server?", "Server löschen?"),
                isPresented: $showDeleteConfirm,
                presenting: serverToDelete
            ) { server in
                Button(tr("Delete", "Löschen"), role: .destructive) {
                    serverStore.delete(server: server)
                }
                Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { server in
                Text("\"\(server.displayName)\"")
            }
            .alert(
                tr("Clear Cache?", "Cache leeren?"),
                isPresented: $showClearCacheConfirm
            ) {
                Button(tr("Clear", "Leeren"), role: .destructive) {
                    Task { await clearCache() }
                }
                Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
            } message: {
                Text(tr(
                    "This will remove all cached images and library data. The library will need to reload on next launch.",
                    "Alle gecachten Bilder und Bibliotheksdaten werden entfernt. Die Bibliothek wird beim nächsten Start neu geladen."
                ))
            }
        }
        .tint(accentColor)

        if showClearToast {
            cacheClearedToast
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .allowsHitTesting(false)
        }
        }
        .animation(.spring(duration: 0.35), value: showClearToast)
        .tint(accentColor)
    }

    private var cacheClearedToast: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text(tr("Cache cleared", "Cache geleert"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(28)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func recalculateCacheSize() async {
        let imgBytes = await ImageCacheService.shared.diskUsageBytes()
        let libBytes = LibraryStore.diskCacheSizeBytes()
        let total = imgBytes + libBytes
        cacheSize = total > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            : tr("Empty", "Leer")
    }

    private func clearCache() async {
        libraryStore.clearCache()
        await ImageCacheService.shared.clearAll()
        await recalculateCacheSize()
        withAnimation { showClearToast = true }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { showClearToast = false }
    }

    @ViewBuilder
    private func serverRow(_ server: SubsonicServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.displayName).font(.body)
                    if serverStore.activeServerID == server.id {
                        Text(tr("Active", "Aktiv"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.2))
                            .foregroundStyle(accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(server.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(server.username)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button(tr("Activate", "Aktivieren")) {
                    serverStore.activate(server: server)
                }
                Button(tr("Edit", "Bearbeiten")) {
                    editingServer = server
                }
                Divider()
                Button(tr("Manage Server", "Server verwalten")) {
                    managingServer = server
                }
                Divider()
                Button(tr("Delete", "Löschen"), role: .destructive) {
                    serverToDelete = server
                    showDeleteConfirm = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            serverStore.activate(server: server)
        }
    }
}

private struct SettingsLinkRow: View {
    let icon: String
    let label: String
    let urlString: String

    var body: some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(label)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
