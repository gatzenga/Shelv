import SwiftUI

struct AboutTab: View {
    @Environment(\.themeColor) private var themeColor

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text("Shelv Desktop")
                .font(.title2.bold())
            Text(appVersion)
                .foregroundStyle(.secondary)
            Text(String(localized: "navidrome_subsonic_client_for_macos"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 16) {
                Link(String(localized: "developer_website"), destination: URL(string: "https://vkugler.app")!)
                Text("·").foregroundStyle(.secondary)
                Link("GitHub", destination: URL(string: "https://github.com/gatzenga/Shelv-Desktop")!)
                Text("·").foregroundStyle(.secondary)
                Link(String(localized: "privacy_policy"), destination: URL(string: "https://vkugler.app/shelv_privacy.html")!)
                Text("·").foregroundStyle(.secondary)
                Link(String(localized: "contact"), destination: URL(string: "mailto:contact@vkugler.app")!)
                Text("·").foregroundStyle(.secondary)
                Link("Discord", destination: URL(string: "https://discord.gg/UdJK5mpmZu")!)
            }
            .font(.callout)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
