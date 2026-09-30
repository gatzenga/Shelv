import AuthenticationServices
import SwiftUI

struct ExternalServicesTab: View {
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
    @State private var showLog = false

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
        Form {
            Section {
                Toggle("Last.fm", isOn: Binding(
                    get: { lastFMEnabled },
                    set: { enabled in Task { await LastFMService.shared.setEnabled(enabled) } }
                ))
            } footer: {
                Text(String(localized: "lastfm_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if lastFMEnabled {
                Section {
                    Toggle(String(localized: "lastfm_top_songs"), isOn: Binding(
                        get: { topSongsEnabled },
                        set: { enabled in Task { await LastFMService.shared.setTopSongsEnabled(enabled) } }
                    ))
                    Toggle(String(localized: "lastfm_mixes"), isOn: Binding(
                        get: { mixesEnabled },
                        set: { enabled in Task { await LastFMService.shared.setMixesEnabled(enabled) } }
                    ))
                } header: {
                    Text(String(localized: "lastfm_use_for"))
                } footer: {
                    Text(String(localized: "lastfm_use_for_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "lastfm_api_account")) {
                    TextField(String(localized: "lastfm_api_key"), text: $apiKey)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    SecureField(String(localized: "lastfm_shared_secret"), text: $sharedSecret)
                        .font(.body.monospaced())
                    Button(String(localized: "lastfm_create_api_account")) {
                        openURL(LastFMService.createAPIAccountURL)
                    }
                    .buttonStyle(.link)
                }

                Section(String(localized: "connection")) {
                    LabeledContent {
                        if status.state == .checking || isAuthorizing {
                            ProgressView().controlSize(.small)
                        }
                    } label: {
                        Label {
                            Text(status.state.displayText)
                        } icon: {
                            Image(systemName: status.state.symbolName)
                                .foregroundStyle(statusColor)
                        }
                    }

                    if hasSession && !credentialsEdited {
                        HStack {
                            Button(String(localized: "lastfm_check_connection")) {
                                Task { await LastFMService.shared.verifyConnection() }
                            }
                            .disabled(status.state == .checking)
                            Spacer()
                            Button(String(localized: "lastfm_disconnect"), role: .destructive) {
                                Task { await LastFMService.shared.disconnect() }
                            }
                        }
                    } else {
                        Button(String(localized: "lastfm_connect")) {
                            Task { await connect() }
                        }
                        .disabled(!canConnect)
                    }
                }

                Section {
                    Button { showLog = true } label: {
                        Label(String(localized: "logs"), systemImage: "doc.text")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showLog) {
            ExternalServicesLogView()
        }
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
        // Closing the window early is fine: an approved token still works,
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if log.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(String(localized: "no_log_entries_yet"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(log.entries.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle(String(localized: "external_services_log"))
            .toolbar {
                ToolbarItem(placement: .destructiveAction) {
                    Button(String(localized: "clear")) { log.clear() }
                        .disabled(log.entries.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
        .frame(width: 640, height: 520)
    }
}
