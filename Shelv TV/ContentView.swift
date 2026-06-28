import SwiftUI

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore
    @State private var showInstantMixUnavailable = false

    var body: some View {
        if serverStore.activeServer != nil {
            MainTabView()
                .onReceive(NotificationCenter.default.publisher(for: .instantMixUnavailable)) { _ in
                    showInstantMixUnavailable = true
                }
                .alert(String(localized: "instant_mix"), isPresented: $showInstantMixUnavailable) {
                    Button(String(localized: "ok"), role: .cancel) {}
                } message: {
                    Text(String(localized: "no_instant_mix_available"))
                }
        } else {
            LoginView()
        }
    }
}
