import Foundation
import HealthKit
import Observation

/// How a sync attempt ended, so automatic syncs can decide whether to retry or alert.
enum SyncOutcome {
    case success
    case failed(String)
    /// Health data is encrypted while the phone is locked; not the user's problem, just retry.
    case healthLocked
    case alreadyRunning
}

@Observable
final class SyncEngine {
    /// One engine for the UI and for background wakes, which can launch the app with no UI.
    static let shared = SyncEngine()

    static let appName = "NocHKSync"
    static let dataSource = "apple-health"
    static let maxDays = 90

    private enum Key {
        static let serverURL = "serverURL"
        static let days = "syncDays"
        static let token = "nocturneToken"
        static let hrAnchor = "heartRateAnchor"
        static let stepsSyncedAt = "stepsSyncedAt"
        static let lastSyncAt = "lastSyncAt"
        static let backgroundEnabled = "backgroundSyncEnabled"
        static let failures = "consecutiveAutoFailures"
    }

    let defaults = UserDefaults.standard
    let health = HealthReader()

    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Key.serverURL); resolvedClient = nil }
    }
    var token: String {
        didSet { KeychainStore.write(token, for: Key.token); resolvedClient = nil }
    }

    /// The client whose scheme was worked out from `serverURL`; cleared when settings change.
    private var resolvedClient: NocturneClient?
    var days: Int { didSet { defaults.set(days, forKey: Key.days) } }

    private(set) var isSyncing = false
    private(set) var status = ""
    private(set) var lastSyncAt: Date?
    private(set) var needsHealthPrompt = true
    private(set) var log: [String] = []

    /// Whether daily background sync is on. Change it through `setBackgroundSync(enabled:)`.
    var backgroundSyncEnabled: Bool { didSet { defaults.set(backgroundSyncEnabled, forKey: Key.backgroundEnabled) } }
    /// Failed automatic attempts in a row; any successful sync resets it.
    var consecutiveFailures: Int { didSet { defaults.set(consecutiveFailures, forKey: Key.failures) } }
    @ObservationIgnored var observerQueries: [HKObserverQuery] = []

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }
    var healthAvailable: Bool { health.isAvailable }

    init() {
        serverURL = defaults.string(forKey: Key.serverURL) ?? ""
        token = KeychainStore.read(Key.token) ?? ""
        let storedDays = defaults.integer(forKey: Key.days)
        days = storedDays == 0 ? Self.maxDays : storedDays
        lastSyncAt = defaults.object(forKey: Key.lastSyncAt) as? Date
        backgroundSyncEnabled = defaults.bool(forKey: Key.backgroundEnabled)
        consecutiveFailures = defaults.integer(forKey: Key.failures)
    }

    // MARK: - Actions

    func refreshHealthStatus() async {
        needsHealthPrompt = await health.needsAuthorizationPrompt()
    }

    func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
            append("Health permission sheet completed.")
        } catch {
            append("Health permission failed: \(error.localizedDescription)")
        }
        await refreshHealthStatus()
    }

    func testConnection() async {
        status = "Testing connection…"
        do {
            let client = try await makeClient()
            try await client.checkConnection()
            status = "Connection OK."
            append("Connection test passed using \(client.baseURL.absoluteString).")
        } catch {
            status = "Connection failed."
            append("Connection test failed: \(error.localizedDescription)")
        }
    }

    /// Runs an incremental sync on app foreground when the last one is older than 15 minutes.
    func autoSyncIfDue() async {
        guard isConfigured, !needsHealthPrompt, !isSyncing else { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < 15 * 60 { return }
        await sync(full: false)
    }

    /// Uploads heart rate and steps. A full sync re-reads the whole window; otherwise heart rate
    /// resumes from the stored HealthKit anchor and steps re-send the last 24 hours before the
    /// previous sync, which catches Apple Watch data that reached the phone late.
    @discardableResult
    func sync(full: Bool) async -> SyncOutcome {
        guard !isSyncing else { return .alreadyRunning }
        isSyncing = true
        defer { isSyncing = false }

        let now = Date()
        let windowStart = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        if full {
            defaults.removeObject(forKey: Key.hrAnchor)
            defaults.removeObject(forKey: Key.stepsSyncedAt)
        }

        do {
            let client = try await makeClient()
            let hrCount = try await syncHeartRate(client: client, windowStart: windowStart)
            let stepCount = try await syncSteps(client: client, windowStart: windowStart, now: now)
            lastSyncAt = now
            defaults.set(now, forKey: Key.lastSyncAt)
            consecutiveFailures = 0
            status = "Synced \(hrCount) heart rate readings and \(stepCount) hourly step totals."
            append(status)
            return .success
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            status = "Health data is locked until the phone is unlocked."
            append(status)
            return .healthLocked
        } catch {
            status = "Sync failed."
            append("Sync failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Sync steps

    private func syncHeartRate(client: NocturneClient, windowStart: Date) async throws -> Int {
        let pageSize = 5000
        var anchor = loadAnchor()
        var total = 0
        while true {
            status = "Reading heart rate… \(total) uploaded"
            let page = try await health.heartRatePage(since: windowStart, anchor: anchor, limit: pageSize)
            if !page.samples.isEmpty {
                status = "Uploading heart rate… \(total) uploaded"
                try await client.uploadHeartRates(page.samples)
                total += page.samples.count
            }
            // Persist the anchor only after its page uploaded, so a failure resumes from here.
            anchor = page.anchor
            saveAnchor(page.anchor)
            if page.samples.count < pageSize { break }
        }
        return total
    }

    private func syncSteps(client: NocturneClient, windowStart: Date, now: Date) async throws -> Int {
        var start = windowStart
        if let last = defaults.object(forKey: Key.stepsSyncedAt) as? Date {
            start = max(windowStart, last.addingTimeInterval(-24 * 3600))
        }
        let calendar = Calendar.current
        start = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        status = "Reading steps…"
        let uploads = try await health.hourlySteps(from: start, to: now)
        status = "Uploading \(uploads.count) step totals…"
        try await client.uploadStepCounts(uploads)
        defaults.set(now, forKey: Key.stepsSyncedAt)
        return uploads.count
    }

    // MARK: - Helpers

    private func makeClient() async throws -> NocturneClient {
        if let resolvedClient { return resolvedClient }
        status = "Finding server…"
        let client = try await NocturneClient.resolve(input: serverURL, token: token)
        if client.baseURL.scheme == "http" {
            append("HTTPS unavailable; using plain HTTP on the local network.")
        }
        resolvedClient = client
        return client
    }

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: Key.hrAnchor) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            defaults.set(data, forKey: Key.hrAnchor)
        }
    }

    func append(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(time)  \(message)", at: 0)
        if log.count > 50 { log.removeLast() }
    }
}
