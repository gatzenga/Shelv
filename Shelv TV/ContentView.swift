import SwiftUI

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore

    var body: some View {
        if serverStore.activeServer != nil {
            MainTabView()
        } else {
            LoginView()
        }
    }
}
