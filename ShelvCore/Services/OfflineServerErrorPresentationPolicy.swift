import Foundation

struct OfflineServerErrorPresentationPolicy {
    private var bannerCooldownUntil: Date?
    private var initialServerErrorPending = false
    private var userInitiatedServerErrorAllowedUntil: Date?
    private var userInitiatedServerErrorPresented = false

    var hasPresentationState: Bool {
        bannerCooldownUntil != nil
            || initialServerErrorPending
            || userInitiatedServerErrorAllowedUntil != nil
            || userInitiatedServerErrorPresented
    }

    mutating func shouldPresentServerError(
        now: Date = Date(),
        isBannerVisible: Bool,
        bypassCooldown: Bool
    ) -> Bool {
        if isBannerVisible {
            return true
        }
        if !bypassCooldown, let until = bannerCooldownUntil, now < until {
            return false
        }
        bannerCooldownUntil = now.addingTimeInterval(10)
        return true
    }

    mutating func prepareInitialServerErrorPresentation() {
        initialServerErrorPending = true
    }

    mutating func allowUserInitiatedServerErrorPresentation(
        now: Date = Date(),
        duration: TimeInterval = 20
    ) {
        userInitiatedServerErrorAllowedUntil = now.addingTimeInterval(duration)
        userInitiatedServerErrorPresented = false
    }

    mutating func markUserInitiatedOfflinePresentation() {
        userInitiatedServerErrorAllowedUntil = nil
        userInitiatedServerErrorPresented = true
    }

    mutating func clearUserInitiatedServerErrorPresentation() {
        userInitiatedServerErrorAllowedUntil = nil
        userInitiatedServerErrorPresented = false
    }

    mutating func consumeServerErrorPresentationAllowance(now: Date = Date()) -> Bool {
        if initialServerErrorPending {
            initialServerErrorPending = false
            return true
        }
        if let until = userInitiatedServerErrorAllowedUntil,
           now < until,
           !userInitiatedServerErrorPresented {
            userInitiatedServerErrorPresented = true
            return true
        }
        if let until = userInitiatedServerErrorAllowedUntil, now >= until {
            userInitiatedServerErrorAllowedUntil = nil
            userInitiatedServerErrorPresented = false
        }
        return false
    }

    mutating func clearAfterSuccessfulResponse() {
        bannerCooldownUntil = nil
        initialServerErrorPending = false
        userInitiatedServerErrorAllowedUntil = nil
        userInitiatedServerErrorPresented = false
    }

    mutating func dismissBanner() {
        bannerCooldownUntil = nil
    }

    mutating func resetForOfflineMode() {
        clearAfterSuccessfulResponse()
    }

    mutating func resetCooldown() {
        bannerCooldownUntil = nil
    }
}
