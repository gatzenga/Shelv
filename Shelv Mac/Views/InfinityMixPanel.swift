import SwiftUI

struct InfinityMixPanel: View {
    @AppStorage("infinityMixAheadCount") private var infinityMixAheadCount = 1
    @Environment(\.themeColor) private var themeColor
    private let infinityMixAheadOptions = Array(1...10)

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "infinity_mix_ahead_count"), selection: $infinityMixAheadCount) {
                    ForEach(infinityMixAheadOptions, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .tint(themeColor)
                .onChange(of: infinityMixAheadCount) { _, _ in
                    AudioPlayerService.shared.refreshInfinityMixWindow()
                }
            }
        }
        .formStyle(.grouped)
    }
}
