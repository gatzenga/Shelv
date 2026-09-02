import SwiftUI

struct ScrobblePanel: View {
    @AppStorage(RemovedFeatureCleanup.playThresholdKey) private var playThreshold = 30
    @ObservedObject private var ckStatus = CloudKitSyncService.shared.status

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "count_from"), selection: $playThreshold) {
                    ForEach([10, 20, 30, 40, 50], id: \.self) { pct in
                        Text("\(pct)%").tag(pct)
                    }
                }
                LabeledContent(String(localized: "pending_scrobbles")) {
                    Text("\(ckStatus.pendingScrobbles)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        // Die Warteschlange leert sich ohne Zutun, sobald wieder gesendet werden
        // darf. Solange die Seite offen ist, wird der Stand deshalb nachgeführt.
        .task {
            while !Task.isCancelled {
                await CloudKitSyncService.shared.updatePendingCounts()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
