import SwiftUI

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.themeColor) private var themeColor

    @State private var serverName: String = ""
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // Logo
                VStack(spacing: 10) {
                    if let nsImage = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .frame(width: 80, height: 80)
                    }
                    Text("Shelv")
                        .font(.system(size: 28, weight: .bold))
                    Text(String(localized: "navidrome_desktop_client"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Form
                VStack(alignment: .leading, spacing: 10) {
                    formFieldLabel(String(localized: "server_name"))
                    TextField(String(localized: "my_navidrome"), text: $serverName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    formFieldLabel(String(localized: "server_url"))
                    TextField("https://music.example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    formFieldLabel(String(localized: "username"))
                    TextField(String(localized: "username"), text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    formFieldLabel(String(localized: "password"))
                    SecureField(String(localized: "password"), text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: 340)

                if let err = errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }

                Button {
                    Task { await connect() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(String(localized: "connect"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: 340)
                .disabled(isLoading || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                .keyboardShortcut(.return)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 440)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func connect() async {
        isLoading = true
        errorMessage = nil
        let success = await appState.addServer(
            name: serverName.trimmingCharacters(in: .whitespacesAndNewlines),
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username,
            password: password
        )
        if !success {
            errorMessage = appState.errorMessage ?? String(localized: "connection_failed")
        }
        isLoading = false
    }
}

#Preview {
    LoginView()
        .environmentObject(AppState.shared)
        .frame(width: 700, height: 580)
}
