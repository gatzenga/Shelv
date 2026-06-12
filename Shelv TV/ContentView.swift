import SwiftUI

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore

    var body: some View {
        if serverStore.activeServer != nil {
            MainTabView()
        } else {
            // Platzhalter bis zum echten Login-Flow (Task 4).
            VStack(spacing: 20) {
                Image(systemName: "music.note")
                    .font(.system(size: 80))
                    .foregroundStyle(.tint)
                Text("Shelv TV")
                    .font(.largeTitle).bold()
                Text(String(localized: "no_server_yet"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
