import SwiftUI

struct ServerTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @State private var showAddServer = false
    @State private var serverToEdit: SubsonicServer?
    @State private var serverToDelete: SubsonicServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(serverStore.servers) { server in
                    ServerRow(
                        server: server,
                        isActive: serverStore.activeServerID == server.id,
                        onActivate: { appState.switchServer(server) },
                        onToggleURLSlot: { Task { await switchServerURLSlot(from: server) } },
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
                .environmentObject(serverStore)
        }
        .sheet(item: $serverToEdit) { server in
            EditServerSheet(server: serverStore.servers.first(where: { $0.id == server.id }) ?? server)
                .environmentObject(appState)
                .environmentObject(serverStore)
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

    @MainActor
    private func switchServerURLSlot(from server: SubsonicServer) async {
        serverStore.toggleURLSlot(for: server)
        guard serverStore.activeServerID == server.id else { return }

        LibraryViewModel.shared.reset()
        RadioStationStore.shared.resetInMemory()

        if await OfflineModeService.shared.beginUserInitiatedServerRefresh() { return }
        defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }

        await LibraryViewModel.shared.loadAlbums()
        await LibraryViewModel.shared.loadArtists()
        await LibraryViewModel.shared.loadPlaylists(force: true)
        await RadioStationStore.shared.refresh()
    }
}

private struct ServerRow: View {
    let server: SubsonicServer
    let isActive: Bool
    let onActivate: () -> Void
    let onToggleURLSlot: () -> Void
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
                Text(server.username + " · " + server.activeBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if server.hasSecondaryURL {
                    Text(server.isUsingSecondaryURL ? String(localized: "secondary_url") : String(localized: "primary_url"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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

            if server.hasSecondaryURL {
                Button { onToggleURLSlot() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(server.isUsingSecondaryURL ? AnyShapeStyle(themeColor) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help(server.isUsingSecondaryURL ? String(localized: "use_primary_url") : String(localized: "use_secondary_url"))
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

private struct AddServerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor
    private let serverURLPlaceholder = "https://music.example.com"
    @State private var name = ""
    @State private var url = ""
    @State private var useSecondaryURL = false
    @State private var secondaryURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var trimmedSecondaryURL: String {
        secondaryURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        !url.isEmpty && !username.isEmpty && !password.isEmpty && (!useSecondaryURL || !trimmedSecondaryURL.isEmpty)
    }

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
                .disabled(isLoading || !canConnect)
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
            TextField("URL", text: $url, prompt: Text(serverURLPlaceholder).foregroundStyle(.secondary))
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()

            Toggle(String(localized: "use_secondary_url"), isOn: $useSecondaryURL)

            if useSecondaryURL {
                formFieldLabel(String(localized: "secondary_url"))
                TextField(String(localized: "secondary_url"), text: $secondaryURL, prompt: Text(serverURLPlaceholder).foregroundStyle(.secondary))
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }

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
            password: password,
            secondaryServerURL: useSecondaryURL ? trimmedSecondaryURL : nil
        )
        if success { dismiss() }
        else { errorMessage = appState.errorMessage ?? String(localized: "connection_failed") }
        isLoading = false
    }
}

private struct EditServerSheet: View {
    let server: SubsonicServer
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss
    private let serverURLPlaceholder = "https://music.example.com"
    @State private var name: String
    @State private var url: String
    @State private var useSecondaryURL: Bool
    @State private var secondaryURL: String
    @State private var username: String
    @State private var password: String = ""

    private var trimmedSecondaryURL: String {
        secondaryURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !url.isEmpty && !username.isEmpty && (!useSecondaryURL || !trimmedSecondaryURL.isEmpty)
    }

    init(server: SubsonicServer) {
        self.server = server
        _name = State(initialValue: server.name)
        _url = State(initialValue: server.baseURL)
        _useSecondaryURL = State(initialValue: server.hasSecondaryURL)
        _secondaryURL = State(initialValue: server.secondaryURL ?? "")
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
                TextField("URL", text: $url, prompt: Text(serverURLPlaceholder).foregroundStyle(.secondary))
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()

                Toggle(String(localized: "use_secondary_url"), isOn: $useSecondaryURL)

                if useSecondaryURL {
                    formFieldLabel(String(localized: "secondary_url"))
                    TextField(String(localized: "secondary_url"), text: $secondaryURL, prompt: Text(serverURLPlaceholder).foregroundStyle(.secondary))
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }

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
                    updated.secondaryBaseURL = useSecondaryURL ? trimmedSecondaryURL : nil
                    if !useSecondaryURL {
                        updated.activeURLSlot = .primary
                    }
                    updated.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    serverStore.update(
                        server: updated,
                        password: password.isEmpty ? nil : password
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
