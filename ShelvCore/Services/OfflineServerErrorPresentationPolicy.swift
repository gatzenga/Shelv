import Foundation

nonisolated protocol ServerConnectivityErrorProviding: Error {
    var underlyingConnectivityError: Error? { get }
}

nonisolated enum ServerConnectivityErrorClassifier {
    static func isConnectivityFailure(_ error: Error) -> Bool {
        if let wrappedError = error as? ServerConnectivityErrorProviding {
            guard let rootError = wrappedError.underlyingConnectivityError else { return false }
            return isConnectivityFailure(rootError)
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code != NSURLErrorCancelled
    }
}

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

struct UserInitiatedPlaybackErrorPresentationPolicy {
    private var generation: Int?
    private var expiresAt: Date?

    mutating func configure(
        generation: Int,
        userInitiated: Bool,
        now: Date = Date(),
        duration: TimeInterval = 20
    ) {
        guard userInitiated else {
            self.generation = nil
            expiresAt = nil
            return
        }
        self.generation = generation
        expiresAt = now.addingTimeInterval(duration)
    }

    mutating func consume(generation: Int, now: Date = Date()) -> Bool {
        guard self.generation == generation else { return false }
        guard let expiresAt, now < expiresAt else {
            self.generation = nil
            self.expiresAt = nil
            return false
        }
        self.generation = nil
        self.expiresAt = nil
        return true
    }
}
