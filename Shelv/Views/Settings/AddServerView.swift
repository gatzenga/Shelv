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
    @State private var isSaving = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, username, password }

    private var isEditing: Bool { editingServer != nil }
    private var canSave: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("settings.add.server.server")) {
                    TextField(tr("settings.add.server.name_optional"), text: $name)
                        .focused($focusedField, equals: .name)
                        .autocorrectionDisabled()

                    TextField(tr("settings.add.server.url_e_g_https_music_example"), text: $baseURL)
                        .focused($focusedField, equals: .url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section(tr("settings.add.server.account")) {
                    TextField(tr("settings.add.server.username"), text: $username)
                        .focused($focusedField, equals: .username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField(tr("settings.add.server.password"), text: $password)
                        .focused($focusedField, equals: .password)
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
                            Text(tr("settings.add.server.test_connection"))
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
                ? tr("settings.add.server.edit_server")
                : tr("settings.add.server.add_server")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("downloads.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(tr("playlists.playlist.detail.save")) { Task { await save() } }
                            .disabled(!canSave)
                            .bold()
                    }
                }
            }
            .onAppear {
                if let server = editingServer {
                    name = server.name
                    baseURL = server.baseURL
                    username = server.username
                    password = serverStore.password(for: server) ?? ""
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = isEditing ? .name : .url
                }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        testSuccess = false

        let tempServer = SubsonicServer(name: name, baseURL: baseURL, username: username)
        do {
            _ = try await SubsonicAPIService.shared.ping(server: tempServer, password: password)
            testSuccess = true
            testResult = tr("settings.add.server.connection_successful")
        } catch {
            testResult = error.localizedDescription
        }

        isTesting = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if let existing = editingServer {
            var updated = existing
            updated.name = name
            updated.baseURL = baseURL
            updated.username = username
            serverStore.update(server: updated, password: password.isEmpty ? nil : password)
            dismiss()
        } else {
            let tempServer = SubsonicServer(name: name, baseURL: baseURL, username: username)
            do {
                let uid = try await SubsonicAPIService.shared.authLogin(server: tempServer, password: password)
                var server = tempServer
                server.remoteUserId = uid
                serverStore.add(server: server, password: password)
                dismiss()
            } catch {
                testResult = error.localizedDescription
                testSuccess = false
            }
        }
    }
}
