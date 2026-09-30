import AuthenticationServices
import SwiftUI

struct ExternalServicesSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(LastFMCredentialStore.enabledKey) private var lastFMEnabled = false
    @AppStorage(LastFMCredentialStore.topSongsEnabledKey) private var topSongsEnabled = true
    @AppStorage(LastFMCredentialStore.mixesEnabledKey) private var mixesEnabled = true
    @ObservedObject private var status = LastFMService.shared.status
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL

    @State private var apiKey = ""
    @State private var sharedSecret = ""
    @State private var savedAPIKey = ""
    @State private var savedSharedSecret = ""
    @State private var hasSession = false
    @State private var isAuthorizing = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var credentialsEdited: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines) != savedAPIKey
            || sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines) != savedSharedSecret
    }

    private var canConnect: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isAuthorizing
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { lastFMEnabled },
                    set: { enabled in Task { await LastFMService.shared.setEnabled(enabled) } }
                )) {
                    Label { Text("Last.fm") } icon: {
                        Image(systemName: "music.note.list").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
            } footer: {
                Text(String(localized: "lastfm_footer"))
            }

            if lastFMEnabled {
                Section {
                    Toggle(isOn: $topSongsEnabled) {
                        Label { Text(String(localized: "lastfm_top_songs")) } icon: {
                            Image(systemName: "music.mic").foregroundStyle(accentColor)
                        }
                    }
                    Toggle(isOn: $mixesEnabled) {
                        Label { Text(String(localized: "lastfm_mixes")) } icon: {
                            Image(systemName: "shuffle").foregroundStyle(accentColor)
                        }
                    }
                } header: {
                    Text(String(localized: "lastfm_use_for"))
                } footer: {
                    Text(String(localized: "lastfm_use_for_footer"))
                }
                .tint(accentColor)

                Section {
                    TextField(String(localized: "lastfm_api_key"), text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    SecureField(String(localized: "lastfm_shared_secret"), text: $sharedSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text(String(localized: "lastfm_api_account"))
                } footer: {
                    Button(String(localized: "lastfm_create_api_account")) {
                        openURL(LastFMService.createAPIAccountURL)
                    }
                    .font(.footnote)
                }

                Section {
                    HStack {
                        Label {
                            Text(status.state.displayText)
                        } icon: {
                            Image(systemName: status.state.symbolName)
                                .foregroundStyle(statusColor)
                        }
                        Spacer()
                        if status.state == .checking || isAuthorizing {
                            ProgressView()
                        }
                    }

                    if hasSession && !credentialsEdited {
                        Button {
                            Task { await LastFMService.shared.verifyConnection() }
                        } label: {
                            Label { Text(String(localized: "lastfm_check_connection")) } icon: {
                                Image(systemName: "arrow.clockwise").foregroundStyle(accentColor)
                            }
                        }
                        .disabled(status.state == .checking)

                        Button(role: .destructive) {
                            Task { await LastFMService.shared.disconnect() }
                        } label: {
                            Label(String(localized: "lastfm_disconnect"), systemImage: "link.badge.minus")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            Task { await connect() }
                        } label: {
                            Label { Text(String(localized: "lastfm_connect")) } icon: {
                                Image(systemName: "link.badge.plus").foregroundStyle(accentColor)
                            }
                        }
                        .disabled(!canConnect)
                    }
                } header: {
                    Text(String(localized: "connection"))
                }

                Section {
                    NavigationLink(destination: ExternalServicesLogView()) {
                        Label { Text(String(localized: "logs")) } icon: {
                            Image(systemName: "doc.text").foregroundStyle(accentColor)
                        }
                    }
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(String(localized: "external_services"))
        .navigationBarTitleDisplayMode(.inline)
        .task { loadCredentials() }
        .onChange(of: status.state) { _, _ in loadCredentials(keepEdits: true) }
    }

    private var statusColor: Color {
        switch status.state {
        case .connected: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private func loadCredentials(keepEdits: Bool = false) {
        let snapshot = LastFMCredentialStore.snapshot()
        if !keepEdits || !credentialsEdited {
            apiKey = snapshot.apiKey
            sharedSecret = snapshot.sharedSecret
        }
        savedAPIKey = snapshot.apiKey
        savedSharedSecret = snapshot.sharedSecret
        hasSession = !snapshot.sessionKey.isEmpty
    }

    /// Saves the entered credentials, lets the listener approve Shelv on
    /// last.fm and then exchanges the approval for a session.
    @MainActor
    private func connect() async {
        isAuthorizing = true
        defer { isAuthorizing = false }
        await LastFMService.shared.saveCredentials(apiKey: apiKey, sharedSecret: sharedSecret)
        loadCredentials()
        guard let request = try? await LastFMService.shared.beginAuthorization(
            callback: LastFMService.callbackURL
        ) else { return }
        // Closing the sheet early is fine: an approved token still works,
        // an unapproved one fails and the status says so.
        _ = try? await webAuthenticationSession.authenticate(
            using: request.url,
            callbackURLScheme: LastFMService.callbackScheme
        )
        await LastFMService.shared.completeAuthorization(token: request.token)
        loadCredentials()
    }
}

/// Live log of connection checks and mix requests.
private struct ExternalServicesLogView: View {
    @ObservedObject private var log = ExternalServicesLog.shared

    var body: some View {
        Group {
            if log.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "no_log_entries_yet"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(log.entries.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle(String(localized: "external_services_log"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !log.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "clear")) { log.clear() }
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
