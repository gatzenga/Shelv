import XCTest

final class ShortcutPlaybackErrorTests: XCTestCase {
    private struct ClassifiedRemoteError: ShortcutRemoteErrorClassifying {
        let shortcutPlaybackError: ShortcutPlaybackError
    }

    func testMapsTransportFailuresToNetworkError() {
        XCTAssertEqual(
            ShortcutPlaybackError.remoteFailure(URLError(.notConnectedToInternet)),
            .noNetwork
        )
    }

    func testMapsMissingRemoteItemWithoutCallingItOffline() {
        XCTAssertEqual(
            ShortcutPlaybackError.remoteFailure(
                ClassifiedRemoteError(shortcutPlaybackError: .notFound)
            ),
            .notFound
        )
    }

    func testMapsCredentialAndCancellationFailures() {
        XCTAssertEqual(
            ShortcutPlaybackError.remoteFailure(
                ClassifiedRemoteError(shortcutPlaybackError: .playbackFailed)
            ),
            .playbackFailed
        )
        XCTAssertEqual(
            ShortcutPlaybackError.remoteFailure(CancellationError()),
            .cancelled
        )
        XCTAssertEqual(
            ShortcutPlaybackError.remoteFailure(URLError(.cancelled)),
            .cancelled
        )
    }

    func testPlaybackCommandsExposeStableDiagnosticActions() {
        let reference = ShortcutPlayableReference(
            serverConfigID: "server",
            kind: .artist,
            contentID: "artist"
        )

        XCTAssertEqual(
            ShortcutPlaybackCommand.playable(reference, order: .inOrder).diagnosticAction,
            "playable.play"
        )
        XCTAssertEqual(
            ShortcutPlaybackCommand.playable(reference, order: .shuffled).diagnosticAction,
            "playable.shuffle"
        )
        XCTAssertEqual(
            ShortcutPlaybackCommand.instantMix(reference).diagnosticAction,
            "instantMix"
        )
        XCTAssertEqual(
            ShortcutPlaybackCommand.instantMix(reference).diagnosticReference,
            reference
        )
    }

    func testInstantMixFailureHasDedicatedLocalizedError() {
        XCTAssertEqual(
            ShortcutPlaybackError.instantMixUnavailable.localizedStringResource,
            "shortcut_error_instant_mix_unavailable"
        )
    }

}
