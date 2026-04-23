import Foundation
import SwiftUI
import Combine

@MainActor
final class OfflineModeService: ObservableObject {
    static let shared = OfflineModeService()

    @AppStorage("offlineModeEnabled") private var storedOffline: Bool = false
    @AppStorage("enableDownloads") private var storedDownloadsEnabled: Bool = false

    @Published var isOffline: Bool = UserDefaults.standard.bool(forKey: "offlineModeEnabled")
    @Published var downloadsFeatureEnabled: Bool = UserDefaults.standard.bool(forKey: "enableDownloads")
    @Published var serverErrorBannerVisible: Bool = false
    @Published var lastServerErrorMessage: String?

    private var bannerCooldownUntil: Date?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // AppStorage-Werte spiegeln
        $isOffline
            .dropFirst()
            .sink { [weak self] new in
                guard let self else { return }
                self.storedOffline = new
                if new { self.serverErrorBannerVisible = false }
            }
            .store(in: &cancellables)
        $downloadsFeatureEnabled
            .dropFirst()
            .sink { [weak self] new in
                self?.storedDownloadsEnabled = new
                if !new {
                    self?.isOffline = false
                }
            }
            .store(in: &cancellables)
    }

    func notifyServerError(_ message: String? = nil) {
        guard !isOffline else { return }
        guard downloadsFeatureEnabled else { return }
        if let until = bannerCooldownUntil, Date() < until { return }
        bannerCooldownUntil = Date().addingTimeInterval(60)
        lastServerErrorMessage = message
        serverErrorBannerVisible = true
    }

    func dismissBanner() {
        serverErrorBannerVisible = false
    }

    func enterOfflineMode() {
        isOffline = true
        serverErrorBannerVisible = false
    }

    func exitOfflineMode() {
        isOffline = false
        bannerCooldownUntil = nil
    }
}
