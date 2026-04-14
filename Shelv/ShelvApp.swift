import SwiftUI

let appLang: String = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"

func tr(_ en: String, _ de: String, _ lang: String = appLang) -> String {
    lang == "de" ? de : en
}

@main
struct ShelvApp: App {
    @StateObject private var serverStore = ServerStore()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("appAppearance") private var appAppearance = "system"

    private var preferredScheme: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverStore)
                .environmentObject(libraryStore)
                .environmentObject(player)
                .tint(AppTheme.color(for: themeColorName))
                .preferredColorScheme(preferredScheme)
        }
    }
}
