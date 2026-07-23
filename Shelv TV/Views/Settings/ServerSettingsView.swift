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
    @State private var originalPassword: String?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: String?
    @State private var testSuccess = false

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
                TextField(
                    "",
                    text: $name,
                    prompt: Text(String(localized: "name_optional"))
                )
                .accessibilityLabel(String(localized: "name_optional"))
                .tvServerInputField()
                TextField(
                    "",
                    text: $serverURL,
                    prompt: Text(String(localized: "server_url"))
                )
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel(String(localized: "server_url"))
                    .tvServerInputField()
            }

            Section(String(localized: "account")) {
                TextField(
                    "",
                    text: $username,
                    prompt: Text(String(localized: "username"))
                )
                    .textContentType(.username)
                    .accessibilityLabel(String(localized: "username"))
                    .tvServerInputField()
                SecureField(
                    "",
                    text: $password,
                    prompt: Text(String(localized: "password"))
                )
                    .textContentType(.password)
                    .accessibilityLabel(String(localized: "password"))
                    .tvServerInputField()
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
                        guard let server = editingServer else { return }
                        Task {
                            await serverStore.activate(server: server)
                            dismiss()
                        }
                    } label: {
                        Label(String(localized: "activate"), systemImage: "checkmark.circle")
                    }
                }
            }

            if isEditing {
                Section {
                    DestructiveButton(title: String(localized: "remove_server"), systemImage: "trash") {
                        guard let server = editingServer else { return }
                        Task {
                            guard await serverStore.delete(server: server) else {
                                testSuccess = false
                                testResult = String(localized: "credential_storage_failed")
                                return
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            guard let server = editingServer else { return }
            name = server.name
            serverURL = server.baseURL
            username = server.username
            let cachedPassword = serverStore.password(for: server)
            password = cachedPassword ?? ""
            originalPassword = cachedPassword
        }
        .task(id: editingServer?.id) {
            guard password.isEmpty,
                  let server = editingServer else { return }
            let serverID = server.id
                guard let storedPassword = await serverStore.loadPassword(for: server),
                  !Task.isCancelled,
                  editingServer?.id == serverID,
                      password.isEmpty else { return }
                password = storedPassword
                originalPassword = storedPassword
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
            updated.sanitizeURLSlots()
            let authenticationConfigurationChanged =
                updated.baseURL != existing.baseURL
                || updated.secondaryBaseURL != existing.secondaryBaseURL
                || updated.username != existing.username
            let passwordChanged = originalPassword.map { $0 != password }
                ?? !password.isEmpty
            if authenticationConfigurationChanged || passwordChanged {
                do {
                    updated.remoteUserId = try await SubsonicAPIService.shared.validatedStableId(
                        server: updated,
                        password: password
                    )
                } catch {
                    testSuccess = false
                    testResult = error.localizedDescription
                    return
                }
            }
            guard await serverStore.update(
                server: updated,
                password: passwordChanged ? password : nil,
                authenticationIdentityVerified: authenticationConfigurationChanged
            ) else {
                testSuccess = false
                testResult = String(localized: "credential_storage_failed")
                return
            }
            dismiss()
        } else {
            var server = SubsonicServer(name: trimmedName, baseURL: normalized, username: username)
            do {
                server.remoteUserId = try await SubsonicAPIService.shared.validatedStableId(
                    server: server,
                    password: password
                )
                guard await serverStore.add(server: server, password: password) else {
                    testSuccess = false
                    testResult = String(localized: "credential_storage_failed")
                    return
                }
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
