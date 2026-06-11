import SwiftUI

struct ScrobblePanel: View {
    @AppStorage("recapThreshold") private var recapThreshold = 30

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "count_from"), selection: $recapThreshold) {
                    ForEach([10, 20, 30, 40, 50], id: \.self) { pct in
                        Text("\(pct)%").tag(pct)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
