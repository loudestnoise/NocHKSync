import BackgroundTasks
import Foundation
import HealthKit
import UserNotifications

/// Daily background sync. Two triggers wake the app:
/// - HealthKit background delivery, which fires at most once a day when new heart rate or step data arrives.
/// - A background app refresh task, scheduled daily as a safety net and sooner after a failure to retry.
/// After `alertAfterFailures` failed automatic attempts in a row, a local notification is posted once.
enum BackgroundSync {
    /// Must match the `$(PRODUCT_BUNDLE_IDENTIFIER).refresh` entry in Info.plist.
    static let taskID = (Bundle.main.bundleIdentifier ?? "NocHKSync") + ".refresh"
    static let alertAfterFailures = 3
    /// An automatic sync is skipped if the last success is newer than this.
    static let minimumInterval: TimeInterval = 20 * 3600

    /// Called from `didFinishLaunching`. The handler runs on a background queue, so it is
    /// `@Sendable` and hops to the main actor explicitly.
    static func registerTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { @Sendable task in
            let work = Task { @MainActor in
                let outcome = await SyncEngine.shared.runAutomaticSync(trigger: "background refresh")
                task.setTaskCompleted(success: outcome.isSuccess)
            }
            task.expirationHandler = { @Sendable in work.cancel() }
        }
    }

    /// Replaces any pending refresh request. iOS treats the date as the earliest time, not an exact one.
    static func scheduleRefresh(after interval: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancelRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
    }

    /// Retry delay after the given number of consecutive failures: 30 min, 1 h, 2 h, … capped at 6 h.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(6 * 3600, 1800 * pow(2, Double(max(0, failures - 1))))
    }

    static func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func postFailureNotification(failures: Int, lastError: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Nocturne sync is failing"
        content.body = "NocHKSync couldn't upload to Nocturne \(failures) times in a row. Last error: \(lastError.prefix(150))"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "sync-failing", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension SyncOutcome {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}

extension SyncEngine {
    func setBackgroundSync(enabled: Bool) async {
        backgroundSyncEnabled = enabled
        if enabled {
            await BackgroundSync.requestNotificationPermission()
            await startBackgroundSyncIfEnabled()
            append("Daily background sync turned on.")
        } else {
            for query in observerQueries { health.store.stop(query) }
            observerQueries = []
            try? await health.store.disableAllBackgroundDelivery()
            BackgroundSync.cancelRefresh()
            append("Daily background sync turned off.")
        }
    }

    /// Runs at every launch, including background launches, because observer queries do not
    /// survive the app being terminated and must be recreated for HealthKit to wake it again.
    func startBackgroundSyncIfEnabled() async {
        guard backgroundSyncEnabled, observerQueries.isEmpty else { return }
        for type in [HealthReader.heartRateType, HealthReader.stepType] {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { @Sendable _, completion, error in
                Task { @MainActor in
                    if error == nil {
                        await SyncEngine.shared.runAutomaticSync(trigger: "new Health data")
                    }
                    // HealthKit backs off future wakes if this is not called.
                    completion()
                }
            }
            health.store.execute(query)
            observerQueries.append(query)
            do {
                try await health.store.enableBackgroundDelivery(for: type, frequency: .daily)
            } catch {
                append("Could not enable background delivery: \(error.localizedDescription)")
            }
        }
        BackgroundSync.scheduleRefresh(after: BackgroundSync.minimumInterval)
    }

    /// Sync from a background trigger. Skips if a recent sync succeeded and nothing is pending
    /// a retry. Failures schedule a retry with backoff and alert once the streak reaches the limit.
    @discardableResult
    func runAutomaticSync(trigger: String) async -> SyncOutcome {
        guard backgroundSyncEnabled, isConfigured else { return .success }
        let failures = consecutiveFailures
        if failures == 0, let last = lastSyncAt,
           Date().timeIntervalSince(last) < BackgroundSync.minimumInterval {
            return .success
        }

        append("Automatic sync started (\(trigger)).")
        let outcome = await sync(full: false)
        switch outcome {
        case .success:
            BackgroundSync.scheduleRefresh(after: 24 * 3600)
        case .healthLocked, .alreadyRunning:
            BackgroundSync.scheduleRefresh(after: 3600)
        case let .failed(message):
            let count = failures + 1
            consecutiveFailures = count
            BackgroundSync.scheduleRefresh(after: BackgroundSync.retryDelay(afterFailures: count))
            if count == BackgroundSync.alertAfterFailures {
                await BackgroundSync.postFailureNotification(failures: count, lastError: message)
            }
        }
        return outcome
    }
}
