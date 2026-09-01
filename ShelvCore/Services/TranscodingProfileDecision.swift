import Foundation

/// Which transcoding profile a stream should use.
nonisolated enum TranscodingProfile: Equatable, Sendable {
    /// Ask the server for the original file.
    case original
    /// The Wi-Fi profile from Settings.
    case wifi
    /// The cellular profile from Settings.
    case cellular
}

/// Picking the profile, separated from reading `UserDefaults` so it can be tested.
///
/// A listener on a slow uplink wants the original at home and a transcode
/// everywhere else, but the Wi-Fi profile applies to every Wi-Fi alike (#7).
/// Rather than read the SSID, which costs a location permission on iOS, this
/// uses something the app already knows: a server can hold a primary and a
/// secondary URL, and the active slot is the listener saying where they are.
nonisolated enum TranscodingProfileDecision {
    static func profile(
        isEnabled: Bool,
        dataSaver: Bool,
        isOnWifi: Bool,
        serverHasSecondaryURL: Bool,
        isOnPrimaryServerURL: Bool,
        exemptsPrimaryServerURL: Bool
    ) -> TranscodingProfile {
        guard isEnabled else { return .original }

        // Data Saver (the macOS menu item) forces the cellular profile onto
        // Wi-Fi, and outranks the home exemption: it is an explicit request.
        if dataSaver { return .cellular }

        guard isOnWifi else { return .cellular }

        // Only on Wi-Fi. Reaching the primary URL over cellular is not home.
        //
        // Both slots have to be filled for the exemption to mean anything. On a
        // server with one URL it would read as "never transcode on Wi-Fi", and
        // the toggle that sets it is not even shown there: a flag left on by
        // another server must not quietly change how this one streams.
        if exemptsPrimaryServerURL, serverHasSecondaryURL, isOnPrimaryServerURL {
            return .original
        }

        return .wifi
    }
}
