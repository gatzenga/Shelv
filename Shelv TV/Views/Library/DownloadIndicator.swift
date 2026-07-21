import SwiftUI

/// Subtiler Listenstatus für lokal vorgepufferte Songs auf tvOS.
struct DownloadAvailabilityIcon: View {
    @AppStorage("themeColor") private var themeColorName = "violet"

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.caption)
            .foregroundStyle(AppTheme.color(for: themeColorName))
            .frame(width: 14, height: 14)
    }
}
