import SwiftUI

/// Insights-Vollbild — Stub (Task 7 baut Top-Songs/Alben/Counts via play_log).
struct InsightsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 70)).foregroundStyle(.tint)
            Text(String(localized: "insights")).font(.largeTitle).bold()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
