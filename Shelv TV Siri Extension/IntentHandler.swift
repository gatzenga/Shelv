import Intents

final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        guard intent is INPlayMediaIntent else {
            fatalError("Unsupported Siri intent: \(type(of: intent))")
        }
        return PlayMediaIntentHandler()
    }
}

final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let request = ShelvSiriMediaRequest(intent: intent)
        guard !request.query.isEmpty || request.isActionableWithoutQuery,
              let identifier = request.identifier
        else {
            completion([INPlayMediaMediaItemResolutionResult.needsValue()])
            return
        }

        let item = INMediaItem(
            identifier: identifier,
            title: request.displayTitle,
            type: request.mediaType,
            artwork: nil
        )
        completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
    }

    func confirm(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        // Audio playback belongs in the app process. `handleInApp` makes the
        // system call UIApplicationDelegate.application(_:handle:completionHandler:),
        // where Shelv waits for confirmed playback before returning success.
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil))
    }
}
