import SwiftUI

struct AddServerView: View {
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) var dismiss
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private let serverURLPlaceholder = "https://music.example.com"

    var editingServer: SubsonicServer? = nil
    var requiresServer = false

    @State private var name = ""
    @State private var baseURL = ""
    @State private var useSecondaryURL = false
    @State private var secondaryBaseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var originalPassword: String?
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, secondaryURL, username, password }

    private var isEditing: Bool { editingServer != nil }
    private var confirmationTitle: String {
        requiresServer && !isEditing ? String(localized: "connect") : String(localized: "save")
    }
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
                if !requiresServer {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "cancel")) { dismiss() }
                            .disabled(isSaving)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(confirmationTitle) { Task { await save() } }
                            .disabled(!canSave || isSaving)
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
                    let cachedPassword = serverStore.password(for: server)
                    password = cachedPassword ?? ""
                    originalPassword = cachedPassword
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = isEditing ? .name : .url
                }
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
            .interactiveDismissDisabled(isSaving)
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
                    testResult = error.localizedDescription
                    testSuccess = false
                    return
                }
            }
            guard await serverStore.update(
                server: updated,
                password: passwordChanged ? password : nil,
                authenticationIdentityVerified: authenticationConfigurationChanged
            ) else {
                testResult = String(localized: "credential_storage_failed")
                testSuccess = false
                return
            }
            dismiss()
        } else {
            let tempServer = SubsonicServer(
                name: name,
                baseURL: baseURL,
                username: username,
                secondaryBaseURL: useSecondaryURL ? trimmedSecondaryBaseURL : nil
            )
            do {
                let uid = try await SubsonicAPIService.shared.validatedStableId(
                    server: tempServer,
                    password: password
                )
                var server = tempServer
                server.remoteUserId = uid
                guard await serverStore.add(server: server, password: password) else {
                    testResult = String(localized: "credential_storage_failed")
                    testSuccess = false
                    return
                }
                if !requiresServer {
                    dismiss()
                }
            } catch {
                testResult = error.localizedDescription
                testSuccess = false
            }
        }
    }
}
