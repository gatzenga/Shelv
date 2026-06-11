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
        // Kein Banner, wenn kein Server konfiguriert ist (z.B. beim allerersten App-Start
        // vor dem Onboarding) — ohne Server gibt es nichts zu kontaktieren.
        guard SubsonicAPIService.shared.hasConfig else { return }
        if let until = bannerCooldownUntil, Date() < until { return }
        bannerCooldownUntil = Date().addingTimeInterval(60)
        lastServerErrorMessage = message
        serverErrorBannerVisible = true
    }

    /// Wird bei JEDEM erfolgreichen API-Response aufgerufen — blendet den Banner automatisch aus,
    /// sobald der Server wieder antwortet, ohne dass der User manuell eingreifen muss.
    func clearServerError() {
        guard serverErrorBannerVisible || lastServerErrorMessage != nil || bannerCooldownUntil != nil else { return }
        serverErrorBannerVisible = false
        lastServerErrorMessage = nil
        bannerCooldownUntil = nil
    }

    func dismissBanner() {
        serverErrorBannerVisible = false
        bannerCooldownUntil = nil
    }

    func enterOfflineMode() {
        isOffline = true
        serverErrorBannerVisible = false
        bannerCooldownUntil = nil
    }

    func exitOfflineMode() {
        isOffline = false
        bannerCooldownUntil = nil
    }
}
