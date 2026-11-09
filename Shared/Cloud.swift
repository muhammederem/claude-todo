import CloudKit
import Foundation

/// A reply sent from the iPhone; the Mac picks it up and passes it to the session.
struct PhoneReply: Identifiable, Hashable {
    enum Status: String { case pending, delivered, waiting, failed }

    let id: String            // record name
    var sessionID: String
    var itemTitle: String
    var text: String
    var created: Date
    var status: Status
    /// What the Mac did with it, e.g. "Typed into the iTerm tab" or "Opened in Warp".
    var note: String
}

/// Sync between the Mac app and the iPhone through the user's own private iCloud database.
/// Everything lives in one custom zone, so both sides can follow changes without query indexes.
enum Cloud {
    static let containerID = "iCloud.com.muhammederem.claude-todo"
    static let zoneID = CKRecordZone.ID(zoneName: "ClaudeTodo", ownerName: CKCurrentUserDefaultName)
    static var db: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }

    private static let snapshotID = CKRecord.ID(recordName: "snapshot", zoneID: zoneID)
    static let replyType = "Reply"
    static let alertType = "Alert"

    static func available() async -> Bool {
        (try? await CKContainer(identifier: containerID).accountStatus()) == .available
    }

    static func ensureZone() async throws {
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    // MARK: Snapshot (Mac → iPhone)

    /// The whole board as one record; it is small (a few KB) and always replaced as a whole.
    static func saveSnapshot(_ state: WidgetState) async throws {
        let data = try JSONEncoder().encode(state)
        let record = (try? await db.record(for: snapshotID)) ?? CKRecord(recordType: "Snapshot", recordID: snapshotID)
        record["payload"] = data as NSData
        record["macSeen"] = Date() as NSDate
        _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    /// The board and when the Mac last wrote it.
    static func fetchSnapshot() async throws -> (state: WidgetState, macSeen: Date)? {
        guard let record = try? await db.record(for: snapshotID),
              let data = record["payload"] as? Data,
              let state = try? JSONDecoder().decode(WidgetState.self, from: data) else { return nil }
        return (state, record["macSeen"] as? Date ?? record.modificationDate ?? .distantPast)
    }

    // MARK: Replies (iPhone → Mac)

    static func sendReply(sessionID: String, itemTitle: String, text: String) async throws {
        let record = CKRecord(recordType: replyType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        record["sessionID"] = sessionID
        record["itemTitle"] = itemTitle
        record["text"] = text
        record["status"] = PhoneReply.Status.pending.rawValue
        record["note"] = ""
        _ = try await db.modifyRecords(saving: [record], deleting: [])
    }

    static func reply(from record: CKRecord) -> PhoneReply? {
        guard record.recordType == replyType, let session = record["sessionID"] as? String,
              let text = record["text"] as? String else { return nil }
        return PhoneReply(id: record.recordID.recordName, sessionID: session, itemTitle: record["itemTitle"] as? String ?? "",
                          text: text, created: record.creationDate ?? Date(),
                          status: PhoneReply.Status(rawValue: record["status"] as? String ?? "") ?? .pending,
                          note: record["note"] as? String ?? "")
    }

    static func update(_ reply: PhoneReply) async throws {
        let id = CKRecord.ID(recordName: reply.id, zoneID: zoneID)
        let record = try await db.record(for: id)
        record["status"] = reply.status.rawValue
        record["note"] = reply.note
        _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
    }

    /// Every reply record changed since `token`, plus the token to pass next time.
    static func changedReplies(since token: CKServerChangeToken?) async throws -> ([PhoneReply], CKServerChangeToken?) {
        var replies: [PhoneReply] = []
        var token = token
        var more = true
        while more {
            let changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                if case .success(let modification) = result, let r = reply(from: modification.record) { replies.append(r) }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return (replies, token)
    }

    /// Recent replies, newest first, for the iPhone's "sent" list.
    static func recentReplies() async throws -> [PhoneReply] {
        let (all, _) = try await changedReplies(since: nil)
        return all.sorted { $0.created > $1.created }
    }

    static func delete(replyIDs: [String]) async throws {
        _ = try await db.modifyRecords(saving: [], deleting: replyIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
    }

    /// Drops alerts older than a day and settled replies older than three days, so the zone stays small.
    static func cleanup() async throws {
        let changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: nil)
        let now = Date()
        var old: [CKRecord.ID] = []
        for (id, result) in changes.modificationResultsByID {
            guard case .success(let modification) = result else { continue }
            let record = modification.record
            let age = now.timeIntervalSince(record.creationDate ?? now)
            if record.recordType == alertType, age > 24 * 3600 { old.append(id) }
            if record.recordType == replyType, record["status"] as? String != PhoneReply.Status.pending.rawValue,
               age > 3 * 24 * 3600 { old.append(id) }
        }
        if !old.isEmpty { _ = try await db.modifyRecords(saving: [], deleting: old) }
    }

    // MARK: Alerts (Mac → iPhone notification)

    /// One record per task that has waited on the user; the iPhone's subscription turns it into a notification.
    static func postAlert(title: String, body: String, sessionID: String, itemTitle: String, suggestion: String) async throws {
        let record = CKRecord(recordType: alertType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        record["title"] = title
        record["body"] = body
        record["sessionID"] = sessionID
        record["itemTitle"] = itemTitle
        record["suggestion"] = suggestion
        _ = try await db.modifyRecords(saving: [record], deleting: [])
    }
}
