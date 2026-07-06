import XCTest

final class OfflineServerErrorPresentationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPassiveServerErrorsAreThrottled() {
        var policy = OfflineServerErrorPresentationPolicy()

        XCTAssertTrue(policy.shouldPresentServerError(
            now: now,
            isBannerVisible: false,
            bypassCooldown: false
        ))
        XCTAssertFalse(policy.shouldPresentServerError(
            now: now.addingTimeInterval(5),
            isBannerVisible: false,
            bypassCooldown: false
        ))
        XCTAssertTrue(policy.shouldPresentServerError(
            now: now.addingTimeInterval(10),
            isBannerVisible: false,
            bypassCooldown: false
        ))
    }

    func testBypassAllowsExplicitServerErrorDuringCooldown() {
        var policy = OfflineServerErrorPresentationPolicy()

        XCTAssertTrue(policy.shouldPresentServerError(
            now: now,
            isBannerVisible: false,
            bypassCooldown: false
        ))
        XCTAssertTrue(policy.shouldPresentServerError(
            now: now.addingTimeInterval(1),
            isBannerVisible: false,
            bypassCooldown: true
        ))
    }

    func testVisibleBannerAllowsMessageUpdatesDuringCooldown() {
        var policy = OfflineServerErrorPresentationPolicy()

        XCTAssertTrue(policy.shouldPresentServerError(
            now: now,
            isBannerVisible: false,
            bypassCooldown: false
        ))
        XCTAssertTrue(policy.shouldPresentServerError(
            now: now.addingTimeInterval(1),
            isBannerVisible: true,
            bypassCooldown: false
        ))
    }

    func testInitialServerErrorPresentationIsConsumedOnce() {
        var policy = OfflineServerErrorPresentationPolicy()

        policy.prepareInitialServerErrorPresentation()

        XCTAssertTrue(policy.consumeServerErrorPresentationAllowance(now: now))
        XCTAssertFalse(policy.consumeServerErrorPresentationAllowance(now: now))
    }

    func testUserInitiatedServerErrorPresentationIsConsumedOnce() {
        var policy = OfflineServerErrorPresentationPolicy()

        policy.allowUserInitiatedServerErrorPresentation(now: now, duration: 20)

        XCTAssertTrue(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(5)))
        XCTAssertFalse(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(6)))
    }

    func testUserInitiatedServerErrorPresentationExpires() {
        var policy = OfflineServerErrorPresentationPolicy()

        policy.allowUserInitiatedServerErrorPresentation(now: now, duration: 20)

        XCTAssertFalse(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(21)))
        XCTAssertFalse(policy.hasPresentationState)
    }

    func testDismissClearsPassiveCooldown() {
        var policy = OfflineServerErrorPresentationPolicy()

        XCTAssertTrue(policy.shouldPresentServerError(
            now: now,
            isBannerVisible: false,
            bypassCooldown: false
        ))

        policy.dismissBanner()

        XCTAssertTrue(policy.shouldPresentServerError(
            now: now.addingTimeInterval(1),
            isBannerVisible: false,
            bypassCooldown: false
        ))
    }

    func testSuccessfulResponseClearsAllPresentationState() {
        var policy = OfflineServerErrorPresentationPolicy()

        policy.prepareInitialServerErrorPresentation()
        policy.allowUserInitiatedServerErrorPresentation(now: now, duration: 20)
        _ = policy.shouldPresentServerError(
            now: now,
            isBannerVisible: false,
            bypassCooldown: false
        )

        policy.clearAfterSuccessfulResponse()

        XCTAssertFalse(policy.hasPresentationState)
        XCTAssertFalse(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(1)))
        XCTAssertTrue(policy.shouldPresentServerError(
            now: now.addingTimeInterval(1),
            isBannerVisible: false,
            bypassCooldown: false
        ))
    }

    func testOfflinePresentationConsumesUserInitiatedAttempt() {
        var policy = OfflineServerErrorPresentationPolicy()

        policy.allowUserInitiatedServerErrorPresentation(now: now, duration: 20)
        policy.markUserInitiatedOfflinePresentation()

        XCTAssertFalse(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(1)))
    }

    func testClearingUserInitiatedPresentationPreventsLaterPassiveConsumption() {
        var policy = OfflineServerErrorPresentationPolicy()

        policy.allowUserInitiatedServerErrorPresentation(now: now, duration: 20)
        policy.clearUserInitiatedServerErrorPresentation()

        XCTAssertFalse(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(1)))
        XCTAssertFalse(policy.hasPresentationState)
    }

    func testClearingUserInitiatedPresentationKeepsInitialPresentation() {
        var policy = OfflineServerErrorPresentationPolicy()

        policy.prepareInitialServerErrorPresentation()
        policy.allowUserInitiatedServerErrorPresentation(now: now, duration: 20)
        policy.clearUserInitiatedServerErrorPresentation()

        XCTAssertTrue(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(1)))
        XCTAssertFalse(policy.consumeServerErrorPresentationAllowance(now: now.addingTimeInterval(2)))
    }
}
