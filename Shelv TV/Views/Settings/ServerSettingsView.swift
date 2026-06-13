import SwiftUI

/// Server-Verwaltung in den Settings: aktiven Server wechseln, neue hinzufügen,
/// einzelne entfernen. Nutzt dieselben ShelvCore-Primitiven wie die LoginView.
struct ServerSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore

    var body: some View {
        List {
            Section(String(localized: "servers")) {
                ForEach(serverStore.servers) { server in
                    NavigationLink {
                        ServerDetailView(server: server)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.displayName).font(.headline)
                                Text(server.baseURL).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.id == serverStore.activeServerID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    AddServerView()
                } label: {
                    Label(String(localized: "add_server"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(String(localized: "servers"))
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Detail eines Servers: aktivieren (falls nicht aktiv) oder entfernen.
struct ServerDetailView: View {
    let server: SubsonicServer
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "username"), value: server.username)
                LabeledContent(String(localized: "server_url"), value: server.baseURL)
            }

            Section {
                if server.id != serverStore.activeServerID {
                    Button {
                        serverStore.activate(server: server)
                        dismiss()
                    } label: {
                        Label(String(localized: "activate"), systemImage: "checkmark.circle")
                    }
                }
                Button(role: .destructive) {
                    serverStore.delete(server: server)
                    dismiss()
                } label: {
                    Label(String(localized: "remove_server"), systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .navigationTitle(server.displayName)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Server-Anmeldeformular — wiederverwendbar fürs initiale Login und „Server hinzufügen".
struct AddServerView: View {
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                TextField(String(localized: "server_url"), text: $serverURL)
                    .textContentType(.URL)
                TextField(String(localized: "username"), text: $username)
                    .textContentType(.username)
                SecureField(String(localized: "password"), text: $password)
                    .textContentType(.password)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text(String(localized: "connect"))
                    }
                }
                .disabled(isConnecting || serverURL.isEmpty || username.isEmpty)
            }
        }
        .navigationTitle(String(localized: "add_server"))
        .toolbar(.hidden, for: .tabBar)
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let normalized = serverURL.hasPrefix("http://") || serverURL.hasPrefix("https://")
            ? serverURL : "https://" + serverURL
        var server = SubsonicServer(name: "", baseURL: normalized, username: username)
        do {
            try await SubsonicAPIService.shared.ping(server: server, password: password)
            server.remoteUserId = try await SubsonicAPIService.shared.authLogin(server: server, password: password)
            serverStore.add(server: server, password: password)
            serverStore.activate(server: server)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
