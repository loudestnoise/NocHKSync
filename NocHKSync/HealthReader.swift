import Foundation
import HealthKit

/// Read-only access to the HealthKit data this app uploads.
struct HealthReader {
    let store = HKHealthStore()

    static let heartRateType = HKQuantityType(.heartRate)
    static let stepType = HKQuantityType(.stepCount)
    private static let readTypes: Set<HKObjectType> = [heartRateType, stepType]
    private static let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// Whether iOS still needs to show the permission sheet. HealthKit never reveals whether
    /// read access was granted, only whether the user has been asked.
    func needsAuthorizationPrompt() async -> Bool {
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        return status != .unnecessary
    }

    /// One page of heart rate samples added since `anchor`, limited to samples on or after `start`.
    func heartRatePage(since start: Date, anchor: HKQueryAnchor?, limit: Int)
        async throws -> (samples: [HeartRateUpload], anchor: HKQueryAnchor)
    {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: Self.heartRateType, predicate: predicate)],
            anchor: anchor,
            limit: limit
        )
        let result = try await descriptor.result(for: store)
        let uploads = result.addedSamples.map { sample in
            let tz = (sample.metadata?[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:))
                ?? .current
            return HeartRateUpload(
                timestamp: sample.startDate,
                utcOffset: tz.secondsFromGMT(for: sample.startDate) / 60,
                bpm: Int(sample.quantity.doubleValue(for: Self.bpmUnit).rounded()),
                accuracy: 0,
                device: sample.device?.name ?? sample.sourceRevision.source.name,
                app: SyncEngine.appName,
                dataSource: SyncEngine.dataSource,
                // HealthKit sample UUIDs are stable, so re-uploads update in place on the server.
                syncIdentifier: "hk-hr-\(sample.uuid.uuidString)"
            )
        }
        return (uploads, result.newAnchor)
    }

    /// Hourly step totals between `start` and `end`. HealthKit's statistics query merges
    /// overlapping iPhone and Apple Watch samples, so totals are not double counted.
    func hourlySteps(from start: Date, to end: Date) async throws -> [StepCountUpload] {
        let calendar = Calendar.current
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: Self.stepType,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end)
            ),
            options: .cumulativeSum,
            anchorDate: calendar.startOfDay(for: start),
            intervalComponents: DateComponents(hour: 1)
        )
        let collection = try await descriptor.result(for: store)
        var uploads: [StepCountUpload] = []
        collection.enumerateStatistics(from: start, to: end) { stats, _ in
            guard let sum = stats.sumQuantity() else { return }
            let steps = Int(sum.doubleValue(for: .count()).rounded())
            guard steps > 0 else { return }
            let bucket = stats.startDate
            uploads.append(StepCountUpload(
                timestamp: bucket,
                utcOffset: TimeZone.current.secondsFromGMT(for: bucket) / 60,
                metric: steps,
                source: 0,
                device: "Apple Health",
                app: SyncEngine.appName,
                dataSource: SyncEngine.dataSource,
                // One record per hour bucket; re-syncing a partial hour updates its total in place.
                syncIdentifier: "hk-steps-\(Int(bucket.timeIntervalSince1970))"
            ))
        }
        return uploads
    }
}
