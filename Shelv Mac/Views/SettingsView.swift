import SwiftUI

private enum SettingsTab: Hashable {
    case server
    case uiCustomizations
    case appearance
    case recap
    case playback
    case downloads
    case lyrics
    case cache
    case database
    case iCloud
    case info

    var icon: String {
        switch self {
        case .uiCustomizations: return "slider.horizontal.3"
        case .server: return "server.rack"
        case .appearance: return "paintpalette"
        case .recap: return "calendar.badge.clock"
        case .playback: return "play.circle"
        case .downloads: return "arrow.down.circle"
        case .lyrics: return "text.bubble"
        case .cache: return "internaldrive"
        case .database: return "cylinder"
        case .iCloud: return "icloud"
        case .info: return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .uiCustomizations: return String(localized: "ui_customizations")
        case .server: return String(localized: "server")
        case .appearance: return String(localized: "appearance")
        case .recap: return String(localized: "recap")
        case .playback: return String(localized: "playback")
        case .downloads: return String(localized: "downloads")
        case .lyrics: return String(localized: "lyrics")
        case .cache: return String(localized: "cache")
        case .database: return String(localized: "database")
        case .iCloud: return "iCloud"
        case .info: return String(localized: "info")
        }
    }
}

private let settingsTabs: [SettingsTab] = [
    .server,
    .uiCustomizations,
    .appearance,
    .recap,
    .playback,
    .downloads,
    .lyrics,
    .cache,
    .database,
    .iCloud,
    .info
]

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.themeColor) private var themeColor
    @AppStorage("appColorScheme") private var colorScheme: AppColorScheme = .system
    @State private var selectedTab: SettingsTab = .server

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(settingsTabs, id: \.self) { tab in
                    SettingsToolbarButton(tab: tab, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 820, height: 720)
        .environmentObject(appState)
        .environmentObject(serverStore)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .uiCustomizations:
            UICustomizationsTab()
        case .server:
            ServerTab()
        case .appearance:
            AppearanceTab(colorScheme: $colorScheme)
        case .recap:
            RecapTab()
        case .playback:
            PlaybackTab()
        case .downloads:
            StableDownloadsTabHost(appState: appState, serverStore: serverStore, themeColor: themeColor)
        case .lyrics:
            LyricsSettingsPanel()
        case .cache:
            CacheTab()
        case .database:
            DatabaseTab()
        case .iCloud:
            ICloudSyncTab()
        case .info:
            AboutTab()
        }
    }
}

private struct SettingsToolbarButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .regular))
                    .symbolVariant(isSelected ? .fill : .none)
                Text(tab.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 70, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

private struct StableDownloadsTabHost: NSViewRepresentable {
    let appState: AppState
    let serverStore: ServerStore
    let themeColor: Color

    func makeNSView(context: Context) -> NSHostingView<DownloadsTabRoot> {
        NSHostingView(rootView: rootView)
    }

    func updateNSView(_ nsView: NSHostingView<DownloadsTabRoot>, context: Context) {
        nsView.rootView = rootView
    }

    private var rootView: DownloadsTabRoot {
        DownloadsTabRoot(appState: appState, serverStore: serverStore, themeColor: themeColor)
    }
}

private struct DownloadsTabRoot: View {
    let appState: AppState
    let serverStore: ServerStore
    let themeColor: Color

    var body: some View {
        DownloadsTab()
            .environmentObject(appState)
            .environmentObject(serverStore)
            .environment(\.themeColor, themeColor)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
        .environmentObject(AppState.shared.serverStore)
        .environmentObject(LyricsStore.shared)
}
