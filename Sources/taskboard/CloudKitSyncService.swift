import CloudKit
import Foundation
import Security

extension Notification.Name {
    static let cloudKitDataDidChange = Notification.Name("taskboard.cloudKitDataDidChange")
}

enum CloudSyncStatus: Equatable {
    case idle
    case syncing
    case synced
    case error(String)

    var label: String {
        switch self {
        case .idle: "Offline ready"
        case .syncing: "Syncing…"
        case .synced: "Synced"
        case .error: "Offline"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .synced: "checkmark.icloud.fill"
        case .error: "icloud.slash"
        }
    }
}

@MainActor
final class CloudKitSyncService {
    static let containerIdentifier = "iCloud.com.wiktorjarochiewicz.taskboard"

    static var isEntitled: Bool {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return services.contains("CloudKit")
#else
        // iOS CloudKit apps are provisioned with this entitlement by Xcode.
        return true
#endif
    }

    private static let recordType = "TaskBoardSnapshot"
    private static let recordName = "primary"
    private static let subscriptionID = "taskboard-snapshot-changes"

    private let database: CKDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var pendingSave: Task<Void, Never>?

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        database = container.privateCloudDatabase
    }

    func start() async throws -> TaskBoardSnapshot? {
        try await fetchSnapshot()
    }

    func fetchSnapshot() async throws -> TaskBoardSnapshot? {
        do {
            let record = try await database.record(for: Self.recordID)
            guard let data = record["payload"] as? Data else { return nil }
            return try decoder.decode(TaskBoardSnapshot.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func save(snapshot: TaskBoardSnapshot) async throws {
        let record: CKRecord
        do {
            record = try await database.record(for: Self.recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: Self.recordType, recordID: Self.recordID)
        }

        record["payload"] = try encoder.encode(snapshot) as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        _ = try await database.save(record)
    }

    func scheduleSave(
        snapshot: TaskBoardSnapshot,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, let self else { return }
                try await self.save(snapshot: snapshot)
                completion(.success(()))
            } catch is CancellationError {
                return
            } catch {
                completion(.failure(error))
            }
        }
    }

    func createSubscriptionIfNeeded() async throws {
        do {
            _ = try await database.subscription(for: Self.subscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Continue and create it below.
        }

        let subscription = CKQuerySubscription(
            recordType: Self.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        _ = try await database.save(subscription)
    }

    private static var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName)
    }
}
