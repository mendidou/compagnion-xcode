import CloudKit
import Foundation

/// Discovers the Mac's relay room ID from the private CloudKit database.
/// Both Mac and iOS share the same private database via the same iCloud account,
/// making this a zero-config pairing mechanism.
///
/// Requires the iCloud + CloudKit capability in Xcode with container:
///   iCloud.SimulatorMirror.SimulatorMirror
final class CloudKitDiscovery {

    // TODO: Replace with your actual CloudKit container identifier
    // Must match the identifier in CloudKitPublisher.swift on the Mac side
    private let container = CKContainer(identifier: "iCloud.SimulatorMirror.SimulatorMirror")

    /// Fetches the current device ID from CloudKit. Returns nil on failure or if not yet published.
    func fetchDeviceId() async -> String? {
        let recordID = CKRecord.ID(recordName: "main")
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            return record["deviceId"] as? String
        } catch {
            print("[CloudKit] Failed to fetch device ID: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sets up a CloudKit subscription so the iOS app is notified when the Mac updates its record.
    /// Also polls every 30 seconds as a fallback for when silent push notifications are suppressed.
    func subscribeToChanges(onUpdate: @escaping (String) -> Void) {
        // Save a push-subscription for immediate updates when the Mac publishes a new ID
        let predicate = NSPredicate(value: true)
        let subscription = CKQuerySubscription(
            recordType: "ServerInfo",
            predicate: predicate,
            subscriptionID: "server-info-changes",
            options: [.firesOnRecordUpdate, .firesOnRecordCreation]
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        container.privateCloudDatabase.save(subscription) { _, error in
            if let error {
                print("[CloudKit] Subscription save failed: \(error.localizedDescription)")
            }
        }

        // Periodic polling as a fallback (30-second interval)
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                if let id = await fetchDeviceId() {
                    await MainActor.run { onUpdate(id) }
                }
            }
        }
    }
}
