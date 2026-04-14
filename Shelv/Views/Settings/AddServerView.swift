import SwiftUI

struct AddServerView: View {
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var editingServer: SubsonicServer? = nil

    @State private var name = ""
    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false

    private var isEditing: Bool { editingServer != nil }
    private var canSave: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Server", "Server")) {
                    TextField(tr("Name (optional)", "Name (optional)"), text: $name)
                        .autocorrectionDisabled()

                    TextField(tr("URL (e.g. https://music.example.com)", "URL (z.B. https://musik.example.com)"), text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section(tr("Account", "Konto")) {
                    TextField(tr("Username", "Benutzername"), text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField(tr("Password", "Passwort"), text: $password)
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 10) {
                            if isTesting {
                                ProgressView().tint(accentColor)
                            } else {
                                Image(systemName: testSuccess ? "checkmark.circle.fill" : "network")
                                    .foregroundStyle(testSuccess ? .green : accentColor)
                            }
                            Text(tr("Test Connection", "Verbindung testen"))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .disabled(isTesting || !canSave)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(testSuccess ? .green : .red)
                    }
                }
            }
            .navigationTitle(isEditing
                ? tr("Edit Server", "Server bearbeiten")
                : tr("Add Server", "Server hinzufügen")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel", "Abbrechen")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Save", "Speichern")) { save() }
                        .disabled(!canSave)
                        .bold()
                }
            }
            .onAppear {
                if let server = editingServer {
                    name = server.name
                    baseURL = server.baseURL
                    username = server.username
                    password = serverStore.password(for: server) ?? ""
                }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        testSuccess = false

        let originalServer = SubsonicAPIService.shared.activeServer
        let originalPassword = SubsonicAPIService.shared.activePassword

        let tempServer = SubsonicServer(name: name, baseURL: baseURL, username: username)
        SubsonicAPIService.shared.activeServer = tempServer
        SubsonicAPIService.shared.activePassword = password

        do {
            try await SubsonicAPIService.shared.ping()
            testSuccess = true
            testResult = tr("Connection successful!", "Verbindung erfolgreich!")
        } catch {
            testResult = error.localizedDescription
        }

        SubsonicAPIService.shared.activeServer = originalServer
        SubsonicAPIService.shared.activePassword = originalPassword

        isTesting = false
    }

    private func save() {
        if let existing = editingServer {
            var updated = existing
            updated.name = name
            updated.baseURL = baseURL
            updated.username = username
            serverStore.update(server: updated, password: password.isEmpty ? nil : password)
        } else {
            let server = SubsonicServer(name: name, baseURL: baseURL, username: username)
            serverStore.add(server: server, password: password)
        }
        dismiss()
    }
}
