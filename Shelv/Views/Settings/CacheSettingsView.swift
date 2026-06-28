import SwiftUI

struct CacheSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("streamPreCacheEnabled") private var streamPreCacheEnabled = false
    @AppStorage("streamPreCacheAheadCount") private var streamPreCacheAheadCount = 1

    @State private var showClearCacheConfirm = false
    @State private var showClearToast = false
    @State private var cacheSize = "—"
    @State private var showPreCacheInfo = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private let preCacheAheadOptions = Array(1...5)

    var body: some View {
        ZStack {
            List {
                Section(String(localized: "precache")) {
                    Toggle(isOn: $streamPreCacheEnabled) {
                        Label { Text(String(localized: "precache_original_file")) } icon: {
                            Image(systemName: "arrow.down.to.line").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: streamPreCacheEnabled) { _, _ in
                        AudioPlayerService.shared.refreshStreamPreCacheWindow()
                    }
                    if streamPreCacheEnabled {
                        Picker(selection: $streamPreCacheAheadCount) {
                            ForEach(preCacheAheadOptions, id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        } label: {
                            Label { Text(String(localized: "precache_ahead_count")) } icon: {
                                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .onChange(of: streamPreCacheAheadCount) { _, _ in
                            AudioPlayerService.shared.refreshStreamPreCacheWindow()
                        }
                    }
                    Button {
                        showPreCacheInfo = true
                    } label: {
                        Label {
                            Text(String(localized: "about_precache"))
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(accentColor)
                        }
                    }
                    .sheet(isPresented: $showPreCacheInfo) {
                        NavigationStack {
                            ScrollView {
                                Text(String(localized: "stable_networkindependent_playback_with_seamless_g"))
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .navigationTitle(String(localized: "precache"))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(String(localized: "done")) { showPreCacheInfo = false }
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }
                }

                Section {
                    HStack {
                        Label { Text(String(localized: "cache_size")) } icon: {
                            Image(systemName: "internaldrive").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink(destination: CacheLogView()) {
                        Label { Text(String(localized: "logs")) } icon: {
                            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(accentColor)
                        }
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Label { Text(String(localized: "clear_cache")) } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                    .tint(.red)
                }

                PlayerBottomSpacer()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .tint(accentColor)
            .listStyle(.insetGrouped)
            .scrollIndicators(.hidden)
            .navigationTitle(String(localized: "cache"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await recalculateCacheSize()
            }
            .alert(
                String(localized: "clear_cache_2"),
                isPresented: $showClearCacheConfirm
            ) {
                Button(String(localized: "clear"), role: .destructive) {
                    Task { await clearCache() }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "this_will_remove_all_cached_images_and_library_dat"))
            }

            if showClearToast {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)
                    Text(String(localized: "cache_cleared"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(28)
                .background(Color.black.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .allowsHitTesting(false)
            }
        }
        .tint(accentColor)
    }

    private func recalculateCacheSize() async {
        let imgBytes = await ImageCacheService.shared.diskUsageBytes()
        let libBytes = LibraryStore.diskCacheSizeBytes()
        let total = imgBytes + libBytes
        cacheSize = total > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            : String(localized: "empty")
    }

    private func clearCache() async {
        LibraryStore.shared.clearCache()
        await ImageCacheService.shared.clearAll()
        await recalculateCacheSize()
        withAnimation { showClearToast = true }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { showClearToast = false }
    }
}
