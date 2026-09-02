import SwiftUI

struct ScrobblePanel: View {
    @AppStorage("playThreshold") private var playThreshold = 30

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "count_from"), selection: $playThreshold) {
                    ForEach([10, 20, 30, 40, 50], id: \.self) { pct in
                        Text("\(pct)%").tag(pct)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
