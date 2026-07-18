import Foundation
import SwiftUI
import Combine

@MainActor
final class OfflineModeService: ObservableObject {
    static let shared = OfflineModeService()

    enum VisibleServerReachabilityResult {
        case reachable
        case unreachable
        case cancelled
    }

    @AppStorage("offlineModeEnabled") private var storedOffline: Bool = false
    @AppStorage("enableDownloads") private var storedDownloadsEnabled: Bool = true

    @Published var isOffline: Bool = UserDefaults.standard.bool(forKey: "offlineModeEnabled")
    @Published var downloadsFeatureEnabled: Bool = OfflineModeService.downloadsEnabledDefaultingToTrue()
    @Published var serverErrorBannerVisible: Bool = false
    @Published var lastServerErrorMessage: String?
    @Published var lastServerErrorWasDeviceOffline: Bool = false

    private var presentationPolicy = OfflineServerErrorPresentationPolicy()
    private var serverErrorPublicationGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    private struct ServerErrorPublicationState: Sendable {
        var isVisible: Bool
        var message: String?
        var wasDeviceOffline: Bool
    }

    private enum ServerErrorMutation: Sendable {
        case notify(message: String?, bypassCooldown: Bool)
        case publish(ServerErrorPublicationState)
        case clear
        case dismiss
        case enterOffline
        case exitOffline
    }

    private var activeServerDebugLabel: String {
        guard let server = SubsonicAPIService.shared.activeServer else { return "none" }
        let slot = server.isUsingSecondaryURL ? "secondary" : "primary"
        let url = URL(string: server.activeBaseURL).map(ConnectivityDebugLog.redacted) ?? server.activeBaseURL
        return "\(server.displayName) [\(slot)] \(url)"
    }

    private var activeServerRequestSignature: String? {
        guard let server = SubsonicAPIService.shared.activeServer else { return nil }
        return "\(server.id.uuidString)|\(server.activeBaseURL)"
    }

    private static func downloadsEnabledDefaultingToTrue() -> Bool {
        if UserDefaults.standard.object(forKey: "enableDownloads") == nil {
            #if os(tvOS)
            return false
            #else
            return true
            #endif
        }
        return UserDefaults.standard.bool(forKey: "enableDownloads")
    }

    private init() {
        // AppStorage-Werte spiegeln
        $isOffline
            .dropFirst()
            .sink { [weak self] new in
                guard let self else { return }
                self.storedOffline = new
                QueueSyncService.shared.handleOfflineModeChange()
                if new {
                    self.publishServerErrorState(.init(isVisible: false, message: nil, wasDeviceOffline: false))
                }
            }
            .store(in: &cancellables)
        $downloadsFeatureEnabled
            .dropFirst()
            .sink { [weak self] new in
                self?.storedDownloadsEnabled = new
                if !new {
                    self?.exitOfflineMode()
                }
            }
            .store(in: &cancellables)
    }

    private func notifyServerError(_ message: String? = nil, bypassCooldown: Bool = false) {
        guard !isOffline else { return }
        guard SubsonicAPIService.shared.activeServer != nil else { return }
        scheduleServerErrorMutation(.notify(message: message, bypassCooldown: bypassCooldown))
    }

    /// Connection failures have one app-wide presentation: the server banner.
    /// Returning `nil` from `inlineErrorMessage` prevents a second local error view.
    @discardableResult
    func presentConnectivityErrorIfNeeded(
        _ error: Error,
        userInitiated: Bool = false
    ) -> Bool {
        guard ServerConnectivityErrorClassifier.isConnectivityFailure(error) else { return false }
        if userInitiated {
            notifyUserInitiatedServerError(error.localizedDescription)
        } else {
            // Connectivity failures can originate from passive work such as lyrics fetching,
            // queue sync or prefetching. Suppress those globally unless the initial launch or
            // an explicit user action opened a presentation allowance.
            notifyServerErrorIfPresentationAllowed(error.localizedDescription)
        }
        return true
    }

    func inlineErrorMessage(for error: Error, userInitiated: Bool = false) -> String? {
        guard !presentConnectivityErrorIfNeeded(error, userInitiated: userInitiated) else { return nil }
        return error.localizedDescription
    }

    private func notifyServerErrorNow(_ message: String? = nil, bypassCooldown: Bool = false) {
        guard !isOffline else { return }
        // Kein Banner, wenn kein Server konfiguriert ist (z.B. beim allerersten App-Start
        // vor dem Onboarding) — ohne Server gibt es nichts zu kontaktieren.
        guard SubsonicAPIService.shared.activeServer != nil else { return }
        guard presentationPolicy.shouldPresentServerError(
            isBannerVisible: serverErrorBannerVisible,
            bypassCooldown: bypassCooldown
        ) else { return }
        applyServerErrorState(.init(
            isVisible: true,
            message: message,
            wasDeviceOffline: !NetworkStatus.shared.hasNetwork
        ))
    }

    func prepareInitialServerErrorPresentation() {
        guard !isOffline else { return }
        guard SubsonicAPIService.shared.activeServer != nil else { return }
        presentationPolicy.prepareInitialServerErrorPresentation()
    }

    func allowUserInitiatedServerErrorPresentation(duration: TimeInterval = 20) {
        guard !isOffline else { return }
        guard SubsonicAPIService.shared.activeServer != nil else { return }
        presentationPolicy.allowUserInitiatedServerErrorPresentation(duration: duration)
    }

    /// Presents a known user-initiated failure immediately through the same global path.
    /// Callers must already have established that the failing operation came from user input.
    func notifyUserInitiatedServerError(_ message: String? = nil) {
        allowUserInitiatedServerErrorPresentation()
        notifyServerErrorIfPresentationAllowed(message)
    }

    func notifyServerErrorIfPresentationAllowed(_ message: String? = nil) {
        guard consumeServerErrorPresentationAllowance() else { return }
        notifyServerError(message, bypassCooldown: true)
    }

    /// User hat aktiv einen serverseitigen Refresh ausgelöst. Der kurze Ping bindet
    /// "Server unreachable" an genau diese Aktion, statt die Meldung beim nächsten
    /// passiven Tab-Request nachzuholen.
    @discardableResult
    func beginUserInitiatedServerRefresh(presentsServerError: Bool = true) async -> Bool {
        let result = await beginServerReachabilityCheck(
            label: "refresh",
            markOfflinePresentation: true,
            presentsServerError: presentsServerError
        )
        return result != .reachable
    }

    /// Sichtbare Leerseiten dürfen vor dem teuren Content-Load kurz pingen, damit
    /// "Server unreachable" nicht erst nach mehreren parallelen Discover-Requests erscheint.
    @discardableResult
    func beginVisibleServerReachabilityCheck() async -> VisibleServerReachabilityResult {
        await beginServerReachabilityCheck(
            label: "load",
            markOfflinePresentation: false,
            presentsServerError: true
        )
    }

    @discardableResult
    private func beginServerReachabilityCheck(
        label: String,
        markOfflinePresentation: Bool,
        presentsServerError: Bool
    ) async -> VisibleServerReachabilityResult {
        guard !isOffline else { return .reachable }
        guard let requestSignature = activeServerRequestSignature else { return .reachable }
        await NetworkStatus.shared.waitUntilReady()
        ConnectivityDebugLog.log("\(label) check started: server=\(activeServerDebugLabel), network=\(NetworkStatus.shared.isOnWifi ? "wifi" : "cellular/other")")
        guard NetworkStatus.shared.hasNetwork else {
            guard requestSignature == activeServerRequestSignature else {
                ConnectivityDebugLog.log("\(label) ignored: active server changed")
                return .cancelled
            }
            let message = SubsonicAPIError.networkError(URLError(.notConnectedToInternet)).localizedDescription
            ConnectivityDebugLog.log("\(label) failed: no network")
            if markOfflinePresentation, presentsServerError {
                presentationPolicy.markUserInitiatedOfflinePresentation()
            }
            if presentsServerError {
                notifyServerError(message, bypassCooldown: true)
            }
            return .unreachable
        }

        if presentsServerError {
            allowUserInitiatedServerErrorPresentation()
        }
        do {
            try await SubsonicAPIService.shared.ping()
            guard requestSignature == activeServerRequestSignature else {
                ConnectivityDebugLog.log("\(label) ignored: active server changed")
                return .cancelled
            }
            ConnectivityDebugLog.log("\(label) ok: ping")
            if presentsServerError {
                allowUserInitiatedServerErrorPresentation()
            }
            return .reachable
        } catch {
            if isCancellation(error) {
                ConnectivityDebugLog.log("\(label) cancelled")
                return .cancelled
            }
            if shouldLogRefreshFailure(error) {
                ConnectivityDebugLog.log("\(label) failed: \(describeServerError(error))")
            }
            guard requestSignature == activeServerRequestSignature else {
                ConnectivityDebugLog.log("\(label) ignored: active server changed")
                return .cancelled
            }
            if presentsServerError {
                notifyServerError(error.localizedDescription, bypassCooldown: true)
                presentationPolicy.clearUserInitiatedServerErrorPresentation()
            }
            return .unreachable
        }
    }

    func finishUserInitiatedServerRefresh() {
        presentationPolicy.clearUserInitiatedServerErrorPresentation()
    }

    @discardableResult
    func notifyUserInitiatedServerRefreshIfOffline() async -> Bool {
        await beginUserInitiatedServerRefresh()
    }

    /// Wird bei JEDEM erfolgreichen API-Response aufgerufen — blendet den Banner automatisch aus,
    /// sobald der Server wieder antwortet, ohne dass der User manuell eingreifen muss.
    func clearServerError() {
        guard serverErrorBannerVisible || lastServerErrorMessage != nil || presentationPolicy.hasPresentationState else { return }
        scheduleServerErrorMutation(.clear)
    }

    private func clearServerErrorNow() {
        guard serverErrorBannerVisible || lastServerErrorMessage != nil || presentationPolicy.hasPresentationState else { return }
        presentationPolicy.clearAfterSuccessfulResponse()
        applyServerErrorState(.init(isVisible: false, message: nil, wasDeviceOffline: false))
    }

    func dismissBanner() {
        cancelPendingServerErrorPublication()
        scheduleServerErrorMutation(.dismiss)
    }

    private func dismissBannerNow() {
        serverErrorBannerVisible = false
        presentationPolicy.dismissBanner()
    }

    func enterOfflineMode() {
        cancelPendingServerErrorPublication()
        scheduleServerErrorMutation(.enterOffline)
    }

    private func enterOfflineModeNow() {
        isOffline = true
        serverErrorBannerVisible = false
        lastServerErrorWasDeviceOffline = false
        presentationPolicy.resetForOfflineMode()
    }

    func exitOfflineMode() {
        cancelPendingServerErrorPublication()
        scheduleServerErrorMutation(.exitOffline)
    }

    private func exitOfflineModeNow() {
        isOffline = false
        presentationPolicy.resetCooldown()
        allowUserInitiatedServerErrorPresentation()
    }

    private func publishServerErrorState(_ state: ServerErrorPublicationState) {
        scheduleServerErrorMutation(.publish(state))
    }

    private func scheduleServerErrorMutation(_ mutation: ServerErrorMutation) {
        switch mutation {
        case .dismiss, .enterOffline, .exitOffline:
            Task { @MainActor [weak self, mutation] in
                try? await Task.sleep(nanoseconds: 1_000_000)
                self?.applyServerErrorMutation(mutation)
            }
            return
        case .notify, .publish, .clear:
            break
        }

        serverErrorPublicationGeneration += 1
        let generation = serverErrorPublicationGeneration
        Task { @MainActor [weak self, mutation] in
            try? await Task.sleep(nanoseconds: 1_000_000)
            guard let self, generation == self.serverErrorPublicationGeneration else { return }
            self.applyServerErrorMutation(mutation)
        }
    }

    private func cancelPendingServerErrorPublication() {
        serverErrorPublicationGeneration += 1
    }

    private func applyServerErrorMutation(_ mutation: ServerErrorMutation) {
        switch mutation {
        case .notify(let message, let bypassCooldown):
            notifyServerErrorNow(message, bypassCooldown: bypassCooldown)
        case .publish(let state):
            applyServerErrorState(state)
        case .clear:
            clearServerErrorNow()
        case .dismiss:
            dismissBannerNow()
        case .enterOffline:
            enterOfflineModeNow()
        case .exitOffline:
            exitOfflineModeNow()
        }
    }

    private func applyServerErrorState(_ state: ServerErrorPublicationState) {
        if state.isVisible {
            guard !isOffline, SubsonicAPIService.shared.activeServer != nil else { return }
        }
        lastServerErrorMessage = state.message
        lastServerErrorWasDeviceOffline = state.wasDeviceOffline
        serverErrorBannerVisible = state.isVisible
    }

    private func consumeServerErrorPresentationAllowance() -> Bool {
        guard !isOffline else { return false }
        guard SubsonicAPIService.shared.activeServer != nil else { return false }
        return presentationPolicy.consumeServerErrorPresentationAllowance()
    }

    private func describeServerError(_ error: Error) -> String {
        guard let apiError = error as? SubsonicAPIError else {
            return "\(ConnectivityDebugLog.short(error)): \(error.localizedDescription)"
        }
        switch apiError {
        case .httpError(let statusCode):
            return "HTTP \(statusCode)"
        case .networkError(let rootError):
            return "\(ConnectivityDebugLog.short(rootError)): \(rootError.localizedDescription)"
        case .apiError(let code, let message):
            return "API \(code): \(message ?? apiError.localizedDescription)"
        case .decodingError(let rootError):
            return "\(ConnectivityDebugLog.short(rootError)): \(apiError.localizedDescription)"
        default:
            return apiError.localizedDescription
        }
    }

    private func shouldLogRefreshFailure(_ error: Error) -> Bool {
        guard let apiError = error as? SubsonicAPIError else { return true }
        switch apiError {
        case .httpError, .networkError:
            return false
        default:
            return true
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if let apiError = error as? SubsonicAPIError,
           case .networkError(let rootError) = apiError {
            return isCancellation(rootError)
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
