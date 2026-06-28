import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("appColorScheme") private var colorScheme: AppColorScheme = .system

    var body: some View {
        TabView {
            ServerTab()
                .tabItem {
                    Image(systemName: "server.rack")
                    Text(String(localized: "server"))
                }
            AppearanceTab(colorScheme: $colorScheme)
                .tabItem {
                    Image(systemName: "paintpalette")
                    Text(String(localized: "appearance"))
                }
            RecapTab()
                .tabItem {
                    Image(systemName: "calendar.badge.clock")
                    Text(String(localized: "recap"))
                }
            PlaybackTab()
                .tabItem {
                    Image(systemName: "play.circle")
                    Text(String(localized: "playback"))
                }
            DownloadsTab()
                .tabItem {
                    Image(systemName: "arrow.down.circle")
                    Text(String(localized: "downloads"))
                }
            LyricsSettingsPanel()
                .tabItem {
                    Image(systemName: "text.bubble")
                    Text(String(localized: "lyrics"))
                }
            CacheTab()
                .tabItem {
                    Image(systemName: "internaldrive")
                    Text(String(localized: "cache"))
                }
            DatabaseTab()
                .tabItem {
                    Image(systemName: "cylinder")
                    Text(String(localized: "database"))
                }
            ICloudSyncTab()
                .tabItem {
                    Image(systemName: "icloud")
                    Text("iCloud")
                }
            AboutTab()
                .tabItem {
                    Image(systemName: "info.circle")
                    Text(String(localized: "info"))
                }
        }
        .frame(width: 820, height: 660)
        .environmentObject(appState)
        .transaction { $0.animation = nil }
    }
}

struct ServerTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddServer = false
    @State private var serverToEdit: SubsonicServer?
    @State private var serverToDelete: SubsonicServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(appState.serverStore.servers) { server in
                    ServerRow(
                        server: server,
                        isActive: appState.serverStore.activeServerID == server.id,
                        onActivate: { appState.switchServer(server) },
                        onEdit: { serverToEdit = server },
                        onDelete: { serverToDelete = server }
                    )
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 140)

            Divider()

            HStack {
                Button {
                    showAddServer = true
                } label: {
                    Label(String(localized: "add_server"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Spacer()
            }
        }
        .sheet(isPresented: $showAddServer) {
            AddServerSheet()
                .environmentObject(appState)
        }
        .sheet(item: $serverToEdit) { server in
            EditServerSheet(server: server)
                .environmentObject(appState)
        }
        .confirmationDialog(
            String(localized: "remove_server"),
            isPresented: Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } }),
            presenting: serverToDelete
        ) { server in
            Button(String(localized: "remove"), role: .destructive) {
                appState.deleteServer(server)
                serverToDelete = nil
            }
            Button(String(localized: "cancel"), role: .cancel) { serverToDelete = nil }
        } message: { server in
            Text(String(format: String(localized: "server_will_be_removed_format"), server.displayName))
        }
    }
}

struct ServerRow: View {
    let server: SubsonicServer
    let isActive: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(themeColor) : AnyShapeStyle(.tertiary))
                .font(.body)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(server.username + " · " + server.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let uid = server.remoteUserId {
                    Text("ID: \(uid)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !isActive {
                Button(String(localized: "connect")) { onActivate() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Button { onEdit() } label: {
                Image(systemName: "pencil").font(.caption)
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

struct AddServerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text(String(localized: "add_server_2"))
                .font(.title2.bold())

            serverForm

            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button(String(localized: "cancel")) { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button {
                    Task { await connect() }
                } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Text(String(localized: "connect")) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || url.isEmpty || username.isEmpty || password.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            formFieldLabel(String(localized: "server_name"))
            TextField(String(localized: "my_navidrome"), text: $name)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()

            formFieldLabel("URL")
            TextField("https://music.example.com", text: $url)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()

            formFieldLabel(String(localized: "username"))
            TextField(String(localized: "username"), text: $username)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()

            formFieldLabel(String(localized: "password"))
            SecureField(String(localized: "password"), text: $password)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func connect() async {
        isLoading = true
        errorMessage = nil
        let success = await appState.addServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            serverURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username,
            password: password
        )
        if success { dismiss() }
        else { errorMessage = appState.errorMessage ?? String(localized: "connection_failed") }
        isLoading = false
    }
}

struct EditServerSheet: View {
    let server: SubsonicServer
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var username: String
    @State private var password: String = ""

    init(server: SubsonicServer) {
        self.server = server
        _name = State(initialValue: server.name)
        _url = State(initialValue: server.baseURL)
        _username = State(initialValue: server.username)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(String(localized: "edit_server"))
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                formFieldLabel(String(localized: "server_name"))
                TextField(String(localized: "my_navidrome"), text: $name)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()

                formFieldLabel("URL")
                TextField("https://music.example.com", text: $url)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()

                formFieldLabel(String(localized: "username"))
                TextField(String(localized: "username"), text: $username)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()

                formFieldLabel(String(localized: "password"))
                SecureField(String(localized: "leave_blank_to_keep_current"), text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(String(localized: "cancel")) { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button(String(localized: "save")) {
                    var updated = server
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.baseURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.serverStore.update(
                        server: updated,
                        password: password.isEmpty ? nil : password
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty || username.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

}

enum AppColorScheme: String, CaseIterable {
    case system = "System"
    case light = "Hell"
    case dark = "Dunkel"

    var displayName: String {
        switch self {
        case .system: return String(localized: "system")
        case .light:  return String(localized: "light")
        case .dark:   return String(localized: "dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

struct AppearanceTab: View {
    @Binding var colorScheme: AppColorScheme

    var body: some View {
        Form {
            Section(String(localized: "appearance")) {
                Picker(String(localized: "mode"), selection: $colorScheme) {
                    ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct CacheTab: View {
    @AppStorage("streamPreCacheEnabled") private var streamPreCacheEnabled = false
    @AppStorage("streamPreCacheAheadCount") private var streamPreCacheAheadCount = 1
    @Environment(\.themeColor) private var themeColor
    @State private var cacheSize = "–"
    @State private var showClearConfirm = false
    @State private var showInfo = false
    @State private var showCacheLog = false
    private let preCacheAheadOptions = Array(1...5)

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "precache_original_file"), isOn: $streamPreCacheEnabled)
                    .onChange(of: streamPreCacheEnabled) { _, _ in
                        AudioPlayerService.shared.refreshStreamPreCacheWindow()
                    }
                if streamPreCacheEnabled {
                    Picker(String(localized: "precache_ahead_count"), selection: $streamPreCacheAheadCount) {
                        ForEach(preCacheAheadOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .onChange(of: streamPreCacheAheadCount) { _, _ in
                        AudioPlayerService.shared.refreshStreamPreCacheWindow()
                    }
                }
                Button {
                    showInfo = true
                } label: {
                    Label(String(localized: "about_precache"), systemImage: "info.circle")
                }
            }

            Section {
                LabeledContent(String(localized: "cache_size")) {
                    Text(cacheSize).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label(String(localized: "clear_cache"), systemImage: "trash")
                }
                .confirmationDialog(String(localized: "clear_cache_2"), isPresented: $showClearConfirm) {
                    Button(String(localized: "clear"), role: .destructive) {
                        Task {
                            await ImageCacheService.shared.clearAll()
                            await recalculateCacheSize()
                        }
                    }
                    Button(String(localized: "cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "all_cached_cover_images_will_be_deleted_and_reload"))
                }
            }

            Section {
                Button {
                    showCacheLog = true
                } label: {
                    Label(String(localized: "logs"), systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await recalculateCacheSize() }
        .sheet(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "precache"))
                    .font(.headline)
                ScrollView {
                    Text(String(localized: "stable_networkindependent_playback_with_seamless_g"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button(String(localized: "done")) { showInfo = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420, height: 340)
        }
        .sheet(isPresented: $showCacheLog) {
            CacheLogView()
                .frame(width: 600, height: 440)
        }
    }

    private func recalculateCacheSize() async {
        let bytes = await ImageCacheService.shared.diskUsageBytes()
        cacheSize = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : "0 KB"
    }
}

struct RecapTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var recapStore = RecapStore.shared
    @Environment(\.themeColor) private var themeColor

    @AppStorage("recapEnabled")          private var recapEnabled          = false
    @AppStorage("recapWeeklyEnabled")    private var recapWeeklyEnabled    = true
    @AppStorage("recapMonthlyEnabled")   private var recapMonthlyEnabled   = true
    @AppStorage("recapYearlyEnabled")    private var recapYearlyEnabled    = true
    @AppStorage("recapWeeklyRetention")  private var recapWeeklyRetention  = 1
    @AppStorage("recapMonthlyRetention") private var recapMonthlyRetention = 12
    @AppStorage("recapYearlyRetention")  private var recapYearlyRetention  = 3

    @State private var showRegistry = false
    @State private var showRecapLog = false
    @State private var showMarkersLog = false
    @State private var showAdvanced = false
    @State private var showVerify = false

    @State private var weekRetentionDraft: Int = 1
    @State private var monthRetentionDraft: Int = 12
    @State private var yearRetentionDraft: Int = 3
    @State private var pendingRetention: PendingRetentionChange?

    private struct PendingRetentionChange: Identifiable {
        let id = UUID()
        let type: RecapPeriod.PeriodType
        let newValue: Int
        let excess: Int
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "enable_recap"), isOn: $recapEnabled)
            } footer: {
                if !recapEnabled {
                    Text(String(localized: "track_your_listening_history_and_generate_automati"))
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            if recapEnabled {
                Section(String(localized: "periods")) {
                    periodRow(title: String(localized: "weekly"),
                              enabled: $recapWeeklyEnabled,
                              retention: $weekRetentionDraft, range: 1...52,
                              type: .week)
                    periodRow(title: String(localized: "monthly"),
                              enabled: $recapMonthlyEnabled,
                              retention: $monthRetentionDraft, range: 1...24,
                              type: .month)
                    periodRow(title: String(localized: "yearly"),
                              enabled: $recapYearlyEnabled,
                              retention: $yearRetentionDraft, range: 1...10,
                              type: .year)
                }

                Section(String(localized: "logs")) {
                    Button {
                        showRegistry = true
                    } label: {
                        Label(String(localized: "registry"), systemImage: "square.stack.3d.up")
                    }
                    Button {
                        showRecapLog = true
                    } label: {
                        Label(String(localized: "recap_log"), systemImage: "sparkles.rectangle.stack")
                    }
                    Button {
                        showMarkersLog = true
                    } label: {
                        Label(String(localized: "autogen_markers"), systemImage: "checkmark.circle.badge.questionmark")
                    }
                }

                Section(String(localized: "actions")) {
                    Button {
                        showVerify = true
                    } label: {
                        Label(String(localized: "sync_with_navidrome"),
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        showAdvanced = true
                    } label: {
                        Label(String(localized: "advanced"), systemImage: "slider.horizontal.2.square")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            weekRetentionDraft  = recapWeeklyRetention
            monthRetentionDraft = recapMonthlyRetention
            yearRetentionDraft  = recapYearlyRetention
        }
        .alert(
            pendingRetention.map {
                String(format: String(localized: "delete_count_period_format"), $0.excess, periodTypeName($0.type))
            } ?? "",
            isPresented: Binding(
                get: { pendingRetention != nil },
                set: { if !$0 { pendingRetention = nil } }
            ),
            presenting: pendingRetention
        ) { pending in
            Button(String(localized: "delete"), role: .destructive) {
                guard let sid = appState.serverStore.activeServer?.stableId else { return }
                let type = pending.type
                let newValue = pending.newValue
                Task {
                    await recapStore.applyRetention(
                        periodType: type, limit: newValue, serverId: sid
                    )
                    setStoredRetention(type, newValue)
                }
                pendingRetention = nil
            }
            Button(String(localized: "cancel"), role: .cancel) {
                setDraft(pending.type, storedRetention(for: pending.type))
                pendingRetention = nil
            }
        } message: { _ in
            Text(String(localized: "these_playlists_will_be_permanently_deleted_from_n"))
        }
        .sheet(isPresented: $showRegistry) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapRegistryView(serverId: sid)
            }
        }
        .sheet(isPresented: $showRecapLog) {
            RecapCreationLogView()
        }
        .sheet(isPresented: $showMarkersLog) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapMarkersLogView(serverId: sid)
            }
        }
        .sheet(isPresented: $showAdvanced) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapAdvancedView(serverId: sid)
            }
        }
        .sheet(isPresented: $showVerify) {
            if let sid = appState.serverStore.activeServer?.stableId {
                RecapVerifyView(serverId: sid)
            }
        }
    }

    @ViewBuilder
    private func periodRow(title: String, enabled: Binding<Bool>,
                           retention: Binding<Int>, range: ClosedRange<Int>,
                           type: RecapPeriod.PeriodType) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(title, isOn: enabled)
            if enabled.wrappedValue {
                Stepper(value: retention, in: range) {
                    HStack {
                        Text(String(localized: "keep")).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(retention.wrappedValue)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .onChange(of: retention.wrappedValue) { _, newValue in
                    handleRetentionChange(type: type, newValue: newValue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func storedRetention(for type: RecapPeriod.PeriodType) -> Int {
        switch type {
        case .week:  return recapWeeklyRetention
        case .month: return recapMonthlyRetention
        case .year:  return recapYearlyRetention
        }
    }

    private func setStoredRetention(_ type: RecapPeriod.PeriodType, _ value: Int) {
        switch type {
        case .week:  recapWeeklyRetention = value
        case .month: recapMonthlyRetention = value
        case .year:  recapYearlyRetention = value
        }
        // Geteilte Wahrheit: Änderung in iCloud spiegeln (siehe iOS-Pendant).
        Task { await CloudKitSyncService.shared.recordRetentionChange() }
    }

    private func setDraft(_ type: RecapPeriod.PeriodType, _ value: Int) {
        switch type {
        case .week:  weekRetentionDraft = value
        case .month: monthRetentionDraft = value
        case .year:  yearRetentionDraft = value
        }
    }

    private func handleRetentionChange(type: RecapPeriod.PeriodType, newValue: Int) {
        let current = storedRetention(for: type)
        guard newValue != current else { return }
        guard newValue < current else {
            setStoredRetention(type, newValue)
            return
        }
        guard let sid = appState.serverStore.activeServer?.stableId else {
            setDraft(type, current)
            return
        }
        Task {
            let excess = await recapStore.excessRetentionCount(
                periodType: type, limit: newValue, serverId: sid
            )
            if excess > 0 {
                pendingRetention = PendingRetentionChange(type: type, newValue: newValue, excess: excess)
            } else {
                setStoredRetention(type, newValue)
            }
        }
    }

    private func periodTypeName(_ type: RecapPeriod.PeriodType) -> String {
        switch type {
        case .week:  return String(localized: "weekly_recaps")
        case .month: return String(localized: "monthly_recaps")
        case .year:  return String(localized: "yearly_recaps")
        }
    }
}

struct AboutTab: View {
    @Environment(\.themeColor) private var themeColor

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text("Shelv Desktop")
                .font(.title2.bold())
            Text(appVersion)
                .foregroundStyle(.secondary)
            Text(String(localized: "navidrome_subsonic_client_for_macos"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 16) {
                Link(String(localized: "developer_website"), destination: URL(string: "https://vkugler.app")!)
                Text("·").foregroundStyle(.secondary)
                Link("GitHub", destination: URL(string: "https://github.com/gatzenga/Shelv-Desktop")!)
                Text("·").foregroundStyle(.secondary)
                Link(String(localized: "privacy_policy"), destination: URL(string: "https://vkugler.app/shelv_privacy.html")!)
                Text("·").foregroundStyle(.secondary)
                Link(String(localized: "contact"), destination: URL(string: "mailto:contact@vkugler.app")!)
                Text("·").foregroundStyle(.secondary)
                Link("Discord", destination: URL(string: "https://discord.gg/UdJK5mpmZu")!)
            }
            .font(.callout)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
        .environmentObject(LyricsStore.shared)
}
