import XCTest

final class TranscodingProfileDecisionTests: XCTestCase {
    private func profile(
        isEnabled: Bool = true,
        dataSaver: Bool = false,
        isOnWifi: Bool = true,
        serverHasSecondaryURL: Bool = true,
        isOnPrimaryServerURL: Bool = true,
        exemptsPrimaryServerURL: Bool = false
    ) -> TranscodingProfile {
        TranscodingProfileDecision.profile(
            isEnabled: isEnabled,
            dataSaver: dataSaver,
            isOnWifi: isOnWifi,
            serverHasSecondaryURL: serverHasSecondaryURL,
            isOnPrimaryServerURL: isOnPrimaryServerURL,
            exemptsPrimaryServerURL: exemptsPrimaryServerURL
        )
    }

    func testTranscodingOffAlwaysAsksForTheOriginal() {
        XCTAssertEqual(profile(isEnabled: false), .original)
        XCTAssertEqual(profile(isEnabled: false, isOnWifi: false), .original)
    }

    func testWithoutTheExemptionEveryWifiUsesTheWifiProfile() {
        XCTAssertEqual(profile(isOnPrimaryServerURL: true), .wifi)
        XCTAssertEqual(profile(isOnPrimaryServerURL: false), .wifi)
    }

    func testTheExemptionOnlyAppliesOnThePrimaryURL() {
        XCTAssertEqual(
            profile(isOnPrimaryServerURL: true, exemptsPrimaryServerURL: true),
            .original
        )
        // Another Wi-Fi, reached through the secondary URL: transcode as before.
        XCTAssertEqual(
            profile(isOnPrimaryServerURL: false, exemptsPrimaryServerURL: true),
            .wifi
        )
    }

    func testTheExemptionNeverAppliesOffWifi() {
        // Reaching the primary URL over cellular, for instance through a VPN,
        // is not being at home.
        XCTAssertEqual(
            profile(isOnWifi: false, isOnPrimaryServerURL: true, exemptsPrimaryServerURL: true),
            .cellular
        )
    }

    func testAServerWithOneURLIgnoresAStaleExemption() {
        // The toggle is not shown for such a server, so a flag left on by
        // another one must not change how this one streams.
        XCTAssertEqual(
            profile(serverHasSecondaryURL: false, exemptsPrimaryServerURL: true),
            .wifi
        )
    }

    func testDataSaverOutranksTheExemption() {
        XCTAssertEqual(
            profile(dataSaver: true, isOnPrimaryServerURL: true, exemptsPrimaryServerURL: true),
            .cellular
        )
    }
}
