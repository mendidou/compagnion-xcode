import CloudKit
import Foundation

/// Publishes this Mac's relay room ID to the private CloudKit database.
/// The iOS app (on the same iCloud account) reads this to discover the room ID
/// without any manual configuration.
///
/// Requires the iCloud + CloudKit capability in Xcode with container:
///   iCloud.SimulatorMirror.SimulatorMirror
final class CloudKitPublisher {

    // TODO: Replace with your actual CloudKit container identifier
    // Must match the identifier in CloudKitDiscovery.swift on the iOS side
    private let container = CKContainer(identifier: "iCloud.SimulatorMirror.SimulatorMirror")

    /// Saves the device ID to the private CloudKit database under record "main".
    /// Subsequent calls overwrite the previous record (upsert via known record name).
    func publishDeviceId(_ id: String) {
        let recordID = CKRecord.ID(recordName: "main")
        let record = CKRecord(recordType: "ServerInfo", recordID: recordID)
        record["deviceId"] = id as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        container.privateCloudDatabase.save(record) { _, error in
            if let error {
                print("[CloudKit] Failed to publish device ID: \(error.localizedDescription)")
            } else {
                print("[CloudKit] Device ID published: \(id.prefix(8))…")
            }
        }
    }
}
