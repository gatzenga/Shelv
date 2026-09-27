import CoreImage.CIFilterBuiltins
import SwiftUI

struct ExternalServicesSettingsView: View {
    @AppStorage(LastFMCredentialStore.enabledKey) private var lastFMEnabled = false
    @ObservedObject private var status = LastFMService.shared.status

    @State private var apiKey = ""
    @State private var sharedSecret = ""
    @State private var hasSession = false
    @State private var pendingAuthorization: LastFMAuthorizationRequest?
    @State private var isPreparingAuthorization = false

    private var canConnect: Bool {
        !apiKey.isEmpty && !sharedSecret.isEmpty && !isPreparingAuthorization
    }

    var body: some View {
        Form {
            Text(String(localized: "external_services"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section {
                Toggle("Last.fm", isOn: Binding(
                    get: { lastFMEnabled },
                    set: { enabled in Task { await LastFMService.shared.setEnabled(enabled) } }
                ))
                NavigationLink(String(localized: "about")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 30) {
                            Text(String(localized: "external_services_about_1"))
                            Text(String(localized: "external_services_about_2"))
                            Text(String(localized: "external_services_about_3"))
                        }
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(60)
                        .focusable()
                    }
                    .navigationTitle(String(localized: "external_services"))
                    .toolbar(.hidden, for: .tabBar)
                }
                NavigationLink(String(localized: "logs")) {
                    ExternalServicesLogView()
                }
            } footer: {
                Text(String(localized: "lastfm_footer"))
            }

            if lastFMEnabled {
                // Read only: typing keys with the remote is impractical, they
                // arrive through iCloud from another device instead.
                Section {
                    LabeledContent(
                        String(localized: "lastfm_api_key"),
                        value: apiKey.isEmpty ? "–" : apiKey
                    )
                    LabeledContent(
                        String(localized: "lastfm_shared_secret"),
                        value: sharedSecret.isEmpty ? "–" : String(repeating: "•", count: min(sharedSecret.count, 32))
                    )
                } header: {
                    Text(String(localized: "lastfm_api_account"))
                } footer: {
                    Text(String(localized: "lastfm_tv_icloud_hint"))
                }

                Section(String(localized: "connection")) {
                    LabeledContent {
                        if status.state == .checking || isPreparingAuthorization {
                            ProgressView()
                        }
                    } label: {
                        Label(status.state.displayText, systemImage: status.state.symbolName)
                    }
                    .focusable()

                    if hasSession {
                        Button(String(localized: "lastfm_check_connection")) {
                            Task { await LastFMService.shared.verifyConnection() }
                        }
                        .disabled(status.state == .checking)
                        Button(String(localized: "lastfm_disconnect"), role: .destructive) {
                            Task { await LastFMService.shared.disconnect() }
                        }
                    } else {
                        Button(String(localized: "lastfm_connect")) {
                            Task { await prepareAuthorization() }
                        }
                        .disabled(!canConnect)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task { loadCredentials() }
        .onChange(of: status.state) { _, _ in loadCredentials() }
        .fullScreenCover(item: Binding(
            get: { pendingAuthorization.map(IdentifiedAuthorization.init) },
            set: { if $0 == nil { pendingAuthorization = nil } }
        )) { item in
            LastFMAuthorizationView(url: item.request.url) {
                let token = item.request.token
                pendingAuthorization = nil
                Task {
                    await LastFMService.shared.completeAuthorization(token: token)
                    loadCredentials()
                }
            } onCancel: {
                pendingAuthorization = nil
            }
        }
    }

    private func loadCredentials() {
        let snapshot = LastFMCredentialStore.snapshot()
        apiKey = snapshot.apiKey
        sharedSecret = snapshot.sharedSecret
        hasSession = !snapshot.sessionKey.isEmpty
    }

    @MainActor
    private func prepareAuthorization() async {
        isPreparingAuthorization = true
        defer { isPreparingAuthorization = false }
        // No callback: the approval happens on another device's browser.
        pendingAuthorization = try? await LastFMService.shared.beginAuthorization(callback: nil)
    }
}

/// Live log of connection checks and mix requests.
private struct ExternalServicesLogView: View {
    @ObservedObject private var log = ExternalServicesLog.shared

    var body: some View {
        LogListView(title: String(localized: "external_services_log"), entries: log.entries)
    }
}

private struct IdentifiedAuthorization: Identifiable {
    let request: LastFMAuthorizationRequest
    var id: String { request.token }
}

/// Shows the approval page as a QR code, because Apple TV has no browser.
private struct LastFMAuthorizationView: View {
    let url: URL
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            Text(String(localized: "lastfm_tv_scan_title"))
                .font(.title2).bold()
            if let image = Self.qrCode(for: url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 420, height: 420)
                    .padding(24)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
            }
            Text(String(localized: "lastfm_tv_scan_message"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            HStack(spacing: 40) {
                Button(String(localized: "cancel"), role: .cancel, action: onCancel)
                Button(String(localized: "done"), action: onDone)
            }
        }
        .padding(80)
    }

    private static func qrCode(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
