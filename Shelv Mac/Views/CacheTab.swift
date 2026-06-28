import SwiftUI

struct CacheTab: View {
    @AppStorage("streamPreCacheEnabled") private var streamPreCacheEnabled = false
    @AppStorage("streamPreCacheAheadCount") private var streamPreCacheAheadCount = 1
    @Environment(\.themeColor) private var themeColor
    @State private var cacheSize = "–"
    @State private var showClearConfirm = false
    @State private var showInfo = false
    @State private var showCacheLog = false
    private let preCacheAheadOptions = Array(1...5)

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "precache_original_file"), isOn: $streamPreCacheEnabled)
                    .onChange(of: streamPreCacheEnabled) { _, _ in
                        AudioPlayerService.shared.refreshStreamPreCacheWindow()
                    }
                if streamPreCacheEnabled {
                    Picker(String(localized: "precache_ahead_count"), selection: $streamPreCacheAheadCount) {
                        ForEach(preCacheAheadOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .onChange(of: streamPreCacheAheadCount) { _, _ in
                        AudioPlayerService.shared.refreshStreamPreCacheWindow()
                    }
                }
                Button {
                    showInfo = true
                } label: {
                    Label(String(localized: "about_precache"), systemImage: "info.circle")
                }
            }

            Section {
                LabeledContent(String(localized: "cache_size")) {
                    Text(cacheSize).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label(String(localized: "clear_cache"), systemImage: "trash")
                }
                .confirmationDialog(String(localized: "clear_cache_2"), isPresented: $showClearConfirm) {
                    Button(String(localized: "clear"), role: .destructive) {
                        Task {
                            await ImageCacheService.shared.clearAll()
                            await recalculateCacheSize()
                        }
                    }
                    Button(String(localized: "cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "all_cached_cover_images_will_be_deleted_and_reload"))
                }
            }

            Section {
                Button {
                    showCacheLog = true
                } label: {
                    Label(String(localized: "logs"), systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await recalculateCacheSize() }
        .sheet(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "precache"))
                    .font(.headline)
                ScrollView {
                    Text(String(localized: "stable_networkindependent_playback_with_seamless_g"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button(String(localized: "done")) { showInfo = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 420, height: 340)
        }
        .sheet(isPresented: $showCacheLog) {
            CacheLogView()
                .frame(width: 600, height: 440)
        }
    }

    private func recalculateCacheSize() async {
        let bytes = await ImageCacheService.shared.diskUsageBytes()
        cacheSize = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : "0 KB"
    }
}
