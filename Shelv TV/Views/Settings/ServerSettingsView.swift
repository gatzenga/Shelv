import SwiftUI

/// Server-Verwaltung in den Settings: aktiven Server wechseln, neue hinzufügen,
/// einzelne bearbeiten/entfernen. Nutzt dieselben ShelvCore-Primitiven wie die LoginView.
struct ServerSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore

    var body: some View {
        List {
            Text(String(localized: "servers"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)
            Section(String(localized: "servers")) {
                ForEach(serverStore.servers) { server in
                    NavigationLink {
                        ServerFormView(editingServer: server)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.displayName)
                                Text(server.baseURL)
                                    .foregroundStyle(.secondary)
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
                    ServerFormView()
                } label: {
                    Label(String(localized: "add_server"), systemImage: "plus")
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Server-Formular — fürs Hinzufügen und Bearbeiten, strukturiert wie iOS/macOS:
/// Abschnitt „Server" (Name + URL), „Account" (Username + Passwort), Test Connection.
/// Im Bearbeiten-Modus zusätzlich Aktivieren + Entfernen (kein Kontextmenü auf tvOS).
struct ServerFormView: View {
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeColor") private var themeColor = "violet"

    var editingServer: SubsonicServer? = nil

    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var showServerURLEditor = false
    @State private var draftServerURL = ""

    private var accent: Color { AppTheme.color(for: themeColor) }
    private var isEditing: Bool { editingServer != nil }
    private var isActive: Bool { editingServer?.id == serverStore.activeServerID }
    private var canSave: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty
    }

    var body: some View {
        List {
            Text(isEditing ? String(localized: "edit_server") : String(localized: "add_server"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "server")) {
                TextField(String(localized: "name_optional"), text: $name)
                Button {
                    draftServerURL = serverURL
                    showServerURLEditor = true
                } label: {
                    HStack {
                        Text(String(localized: "server_url"))
                        Spacer()
                        Text(serverURL.isEmpty ? String(localized: "server_url") : serverURL)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section(String(localized: "account")) {
                TextField(String(localized: "username"), text: $username)
                    .textContentType(.username)
                SecureField(String(localized: "password"), text: $password)
                    .textContentType(.password)
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack(spacing: 10) {
                        if isTesting {
                            ProgressView().tint(accent)
                        } else {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "network")
                                .foregroundStyle(testSuccess ? .green : accent)
                        }
                        Text(String(localized: "test_connection"))
                    }
                }
                .disabled(isTesting || !canSave)

                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testSuccess ? .green : .red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(String(localized: "save"))
                    }
                }
                .disabled(!canSave || isSaving)

                if isEditing && !isActive {
                    Button {
                        if let s = editingServer { serverStore.activate(server: s); dismiss() }
                    } label: {
                        Label(String(localized: "activate"), systemImage: "checkmark.circle")
                    }
                }
            }

            if isEditing {
                Section {
                    DestructiveButton(title: String(localized: "remove_server"), systemImage: "trash") {
                        if let s = editingServer { serverStore.delete(server: s); dismiss() }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .alert(String(localized: "server_url"), isPresented: $showServerURLEditor) {
            TextField(String(localized: "server_url"), text: $draftServerURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "done")) {
                serverURL = draftServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .onAppear {
            guard let server = editingServer else { return }
            name = server.name
            serverURL = server.baseURL
            username = server.username
            password = serverStore.password(for: server) ?? ""
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        testSuccess = false
        defer { isTesting = false }

        let normalized = normalizedURL()
        let temp = SubsonicServer(name: name, baseURL: normalized, username: username)
        do {
            try await SubsonicAPIService.shared.ping(server: temp, password: password)
            testSuccess = true
            testResult = String(localized: "connection_successful")
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let normalized = normalizedURL()

        if let existing = editingServer {
            var updated = existing
            updated.name = trimmedName
            updated.baseURL = normalized
            updated.username = username
            serverStore.update(server: updated, password: password.isEmpty ? nil : password)
            dismiss()
        } else {
            var server = SubsonicServer(name: trimmedName, baseURL: normalized, username: username)
            do {
                server.remoteUserId = try await SubsonicAPIService.shared.authLogin(server: server, password: password)
                serverStore.add(server: server, password: password)
                dismiss()
            } catch {
                testSuccess = false
                testResult = error.localizedDescription
            }
        }
    }

    private func normalizedURL() -> String {
        serverURL.hasPrefix("http://") || serverURL.hasPrefix("https://") ? serverURL : "https://" + serverURL
    }
}
