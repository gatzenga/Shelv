import SwiftUI

/// Server-Anmeldung auf tvOS. Textfelder nutzen die native „Tippen-vom-iPhone"-Funktion.
/// Verbindungstest + Anlegen über die ShelvCore-Primitiven (wie iOS).
struct LoginView: View {
    @EnvironmentObject var serverStore: ServerStore

    @State private var name = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 70))
                    .foregroundStyle(.tint)
                Text("Shelv").font(.largeTitle).bold()
            }

            VStack(spacing: 16) {
                TextField(String(localized: "name_optional"), text: $name)
                    .lineLimit(1)
                TextField(String(localized: "server_url"), text: $serverURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1)
                TextField(String(localized: "username"), text: $username)
                    .textContentType(.username)
                    .lineLimit(1)
                SecureField(String(localized: "password"), text: $password)
                    .textContentType(.password)
                    .lineLimit(1)
            }
            .frame(width: 700)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button {
                Task { await connect() }
            } label: {
                if isConnecting {
                    ProgressView()
                } else {
                    Text(String(localized: "connect")).frame(maxWidth: 400)
                }
            }
            .disabled(isConnecting || serverURL.isEmpty || username.isEmpty)

            #if DEBUG
            Button(String(localized: "try_demo")) {
                Task {
                    await serverStore.activate(server: DemoContent.server)
                    AudioPlayerService.shared.loadDemoStandby()   // fester Player-Standby wie iOS/Mac
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            #endif
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        let normalized = serverURL.hasPrefix("http://") || serverURL.hasPrefix("https://")
            ? serverURL : "https://" + serverURL
        var server = SubsonicServer(name: name.trimmingCharacters(in: .whitespaces), baseURL: normalized, username: username)
        do {
            server.remoteUserId = try await SubsonicAPIService.shared.validatedStableId(
                server: server,
                password: password
            )
            guard await serverStore.add(server: server, password: password) else {
                errorMessage = String(localized: "credential_storage_failed")
                return
            }
            await serverStore.activate(server: server)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
