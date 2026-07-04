import SwiftUI

struct AddServerView: View {
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private let serverURLPlaceholder = "https://music.example.com"

    var editingServer: SubsonicServer? = nil

    @State private var name = ""
    @State private var baseURL = ""
    @State private var useSecondaryURL = false
    @State private var secondaryBaseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, secondaryURL, username, password }

    private var isEditing: Bool { editingServer != nil }
    private var trimmedSecondaryBaseURL: String {
        secondaryBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        && !username.isEmpty
        && !password.isEmpty
        && (!useSecondaryURL || !trimmedSecondaryBaseURL.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "server")) {
                    TextField(String(localized: "name_optional"), text: $name)
                        .focused($focusedField, equals: .name)
                        .autocorrectionDisabled()

                    TextField(
                        String(localized: "url_eg_httpsmusicexamplecom"),
                        text: $baseURL,
                        prompt: Text(serverURLPlaceholder).foregroundStyle(.secondary)
                    )
                        .focused($focusedField, equals: .url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Toggle(String(localized: "use_secondary_url"), isOn: $useSecondaryURL)
                        .tint(accentColor)

                    if useSecondaryURL {
                        TextField(
                            String(localized: "secondary_url"),
                            text: $secondaryBaseURL,
                            prompt: Text(serverURLPlaceholder).foregroundStyle(.secondary)
                        )
                            .focused($focusedField, equals: .secondaryURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                }

                Section(String(localized: "account")) {
                    TextField(String(localized: "username"), text: $username)
                        .focused($focusedField, equals: .username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if isEditing {
                        SecureField(String(localized: "password"), text: $password)
                            .focused($focusedField, equals: .password)
                    } else {
                        HStack {
                            if showPassword {
                                TextField(String(localized: "password"), text: $password)
                                    .focused($focusedField, equals: .password)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            } else {
                                SecureField(String(localized: "password"), text: $password)
                                    .focused($focusedField, equals: .password)
                            }
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
                            Text(String(localized: "test_connection"))
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
                ? String(localized: "edit_server")
                : String(localized: "add_server")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "save")) { Task { await save() } }
                            .disabled(!canSave)
                            .bold()
                    }
                }
            }
            .onAppear {
                if let server = editingServer {
                    name = server.name
                    baseURL = server.baseURL
                    useSecondaryURL = server.hasSecondaryURL
                    secondaryBaseURL = server.secondaryURL ?? ""
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
            testResult = String(localized: "connection_successful")
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
            updated.secondaryBaseURL = useSecondaryURL ? trimmedSecondaryBaseURL : nil
            if !useSecondaryURL {
                updated.activeURLSlot = .primary
            }
            updated.username = username
            serverStore.update(server: updated, password: password.isEmpty ? nil : password)
            dismiss()
        } else {
            let tempServer = SubsonicServer(
                name: name,
                baseURL: baseURL,
                username: username,
                secondaryBaseURL: useSecondaryURL ? trimmedSecondaryBaseURL : nil
            )
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
