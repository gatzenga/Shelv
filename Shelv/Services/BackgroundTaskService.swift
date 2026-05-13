import BackgroundTasks

actor BackgroundTaskService {
    static let shared = BackgroundTaskService()

    static let downloadIdentifier = "ch.vkugler.Shelv.download"
    static let lyricsIdentifier   = "ch.vkugler.Shelv.lyrics"

    // MARK: - Submission

    func runWithBackgroundTask(
        identifier: String,
        title: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        if #available(iOS 26, *) {
            runContinued(identifier: identifier, title: title, work: work)
        } else {
            runProcessing(identifier: identifier, work: work)
        }
    }

    // MARK: - iOS 26

    @available(iOS 26, *)
    private func runContinued(
        identifier: String,
        title: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        storeWork(identifier: identifier, work: work)
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: ""
        )
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - iOS 18

    private func runProcessing(
        identifier: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        storeWork(identifier: identifier, work: work)
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Work storage

    private var pendingWork: [String: (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void] = [:]

    func storeWork(
        identifier: String,
        work: @escaping (_ progress: Progress, _ isCancelled: @escaping () -> Bool) async -> Void
    ) {
        pendingWork[identifier] = work
    }

    func handleBGTask(_ bgTask: BGTask) {
        guard let work = pendingWork[bgTask.identifier] else {
            bgTask.setTaskCompleted(success: false)
            return
        }
        pendingWork.removeValue(forKey: bgTask.identifier)

        var cancelled = false
        bgTask.expirationHandler = { cancelled = true }

        let progress = Progress(totalUnitCount: 100)

        if #available(iOS 26, *), let continuedTask = bgTask as? BGContinuedProcessingTask {
            continuedTask.progress.addChild(progress, withPendingUnitCount: 100)
        }

        Task {
            await work(progress) { cancelled }
            bgTask.setTaskCompleted(success: !cancelled)
        }
    }

    func cancelTask(identifier: String) {
        pendingWork.removeValue(forKey: identifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
