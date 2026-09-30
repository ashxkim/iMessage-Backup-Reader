import Foundation
import SQLite3

struct ReaderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Only the private working copy is ever opened by SQLite.
final class Database {
    private var handle: OpaquePointer?
    init(_ path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            sqlite3_close(handle)
            handle = nil
            throw ReaderError(detail)
        }
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA trusted_schema=OFF")
        try execute("PRAGMA query_only=ON")
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws { try rows(sql) { _ in } }
    func rows(_ sql: String, integers: [Int64] = [], _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReaderError(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in integers.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try body(Row(statement: statement!))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ReaderError(String(cString: sqlite3_errmsg(handle))) }
    }
    func scalar(_ sql: String, integers: [Int64] = []) throws -> Int64 {
        var value: Int64 = 0
        try rows(sql, integers: integers) { value = $0.integer(0) }
        return value
    }
    func columns(_ table: String) throws -> Set<String> {
        var names = Set<String>()
        try rows("PRAGMA table_info(\(table))") { names.insert($0.text(1) ?? "") }
        return names
    }
}

struct Row {
    let statement: OpaquePointer
    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func number(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func text(_ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index)))
        return String(bytes: bytes, encoding: .utf8)
    }
    func data(_ index: Int32) -> Data? {
        guard let value = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

enum BodyDecoder {
    // Extract the length-delimited NSString payload, never instantiate archived classes.
    // This intentionally supports plain text, not the entire private attributed-string format.
    static func decode(_ data: Data?) -> String? {
        guard let data, data.count > 12, data.count < 32 * 1024 * 1024 else { return nil }
        let bytes = [UInt8](data)
        let signature = String(bytes: bytes[2..<13], encoding: .ascii)
        guard signature == "streamtyped" || signature == "typedstream",
              let ns = data.range(of: Data("NSString".utf8)),
              let marker = data.range(of: Data([0x01, 0x2b]), in: ns.upperBound..<data.endIndex) else { return nil }
        var index = marker.upperBound
        guard index < bytes.count else { return nil }
        let head = bytes[index]
        index += 1
        var length = Int(head)
        if head == 0x81 || head == 0x82 {
            let width = head == 0x81 ? 2 : 4
            guard index + width <= bytes.count else { return nil }
            length = 0
            for offset in 0..<width {
                let shift = signature == "streamtyped" ? offset : width - 1 - offset
                length |= Int(bytes[index + offset]) << (8 * shift)
            }
            index += width
        } else if (0x80...0x91).contains(head) { return nil }
        guard length <= bytes.count - index, index + length < bytes.count,
              bytes[index + length] == 0x86 else { return nil }
        return String(bytes: bytes[index..<(index + length)], encoding: .utf8)
    }
    static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "[Attachment]")
            .replacingOccurrences(of: "\u{FFFD}", with: "[App content]")
    }
}

func messageDate(_ raw: Double) -> Date? {
    guard raw != 0, raw.isFinite else { return nil }
    let seconds = abs(raw) > 100_000_000_000 ? raw / 1_000_000_000 : raw
    return Date(timeIntervalSinceReferenceDate: seconds)
}

struct Conversation: Identifiable {
    let id: Int64
    let title: String
    let participants: String
    var count: Int
    var latest: Date?
    var addresses: [String] = []
    var displayName = ""
    var guid = ""
    var isGroup = false
    var inferredCount = 0
}
struct Attachment: Identifiable {
    let id: Int64
    let name: String
    let path: String?
    let bytes: Int64
    let mime: String
}
struct Message: Identifiable {
    let id: Int64
    let sender: String
    let fromMe: Bool
    let date: Date?
    let body: String
    let note: String?
    var attachments: [Attachment] = []
    var event: MessageEvent?
    var hasReadableText = true
    var placementReason: String?
}
struct MessagePage {
    let messages: [Message]
    let total: Int
    let page: Int
    static let size = 200
}

enum UnlinkedScope: String, CaseIterable, Identifiable {
    case all = "All records"
    case remaining = "Unplaced messages"
    case participantAdditions = "Participant-added events"
    case ordinary = "Ordinary messages"
    case numberChangeCandidates = "Possible phone changes / membership events"
    case locationSharing = "Location sharing"
    case reactions = "Reactions"
    case otherEvents = "Other events"
    var id: String { rawValue }
    static let eventSections: [UnlinkedScope] = [.participantAdditions, .numberChangeCandidates, .locationSharing, .reactions, .otherEvents]
}
struct BackupSummary {
    let messages: Int
    let conversations: Int
    let attachments: Int
    let unassigned: Int
    let oldest: Date?
    let newest: Date?
    let includesWAL: Bool
    let attachmentMetadataAvailable: Bool
}
struct AttachmentReport {
    var present = 0
    var missing = 0
    var differentSize = 0
    var unknown = 0
    var examples: [String] = []
    var total: Int { present + missing + differentSize + unknown }
}

final class MessageStore {
    let source: URL
    let root: URL
    let temporary: URL
    private var database: Database?
    private var schema: [String: Set<String>] = [:]
    private(set) var includesWAL = false
    private var db: Database { database! }
    private struct Placement {
        let chat: Int64
        let date: Date?
        let reason: String
    }
    private var placements: [Int64: Placement] = [:]
    private var placementsReady = false

    init(url: URL) throws {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &directory) else {
            throw ReaderError("The selected file or folder is unavailable. Reconnect the SD card and try again.")
        }
        source = directory.boolValue ? url.appendingPathComponent("chat.db") : url
        root = source.deletingLastPathComponent().resolvingSymlinksInPath()
        guard fm.isReadableFile(atPath: source.path) else {
            throw ReaderError("Cannot read chat.db. Choose the Messages folder containing chat.db, or chat.db itself. For ~/Library/Messages, allow Messages Reader in System Settings → Privacy & Security → Full Disk Access, then quit and reopen the app.")
        }
        temporary = fm.temporaryDirectory.appendingPathComponent("MessagesReader-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copiedWAL = false
        do {
            // The source must be quiescent during copying. Retry detectable changes; never
            // checkpoint or create sidecars on the original volume (including read-only SDs).
            var stable = false
            for attempt in 0..<3 {
                let before = try Self.fingerprint(source)
                for suffix in ["", "-wal", "-journal"] {
                    let input = URL(fileURLWithPath: source.path + suffix)
                    let output = temporary.appendingPathComponent("chat.db" + suffix)
                    if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                    if fm.fileExists(atPath: input.path) {
                        try fm.copyItem(at: input, to: output)
                        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                    }
                }
                if before == (try Self.fingerprint(source)) { stable = true; break }
                if attempt == 2 { break }
            }
            guard stable else { throw ReaderError("Messages changed while being read. Close Messages and retry, or open an offline backup.") }
            copiedWAL = fm.fileExists(atPath: temporary.appendingPathComponent("chat.db-wal").path)
            database = try Database(temporary.appendingPathComponent("chat.db").path)
            var integrity: [String] = []
            try db.rows("PRAGMA quick_check") { integrity.append($0.text(0) ?? "Unknown error") }
            guard integrity == ["ok"] else {
                throw ReaderError("This database failed its structural check. It may be incomplete or damaged. Try copying the entire Messages folder again. \(integrity.prefix(3).joined(separator: "; "))")
            }
            for table in ["message", "chat", "handle", "chat_message_join", "chat_handle_join", "chat_recoverable_message_join", "attachment", "message_attachment_join"] {
                schema[table] = try db.columns(table)
            }
            guard schema["message"]!.contains("date"), schema["message"]!.contains("is_from_me"),
                  schema["chat"]?.isEmpty == false,
                  schema["chat_message_join"]!.isSuperset(of: ["chat_id", "message_id"]) else {
                throw ReaderError("This is not a supported Mac Messages chat.db database. Choose a Messages folder copied from a Mac.")
            }
        } catch {
            database = nil
            try? fm.removeItem(at: temporary)
            throw error
        }
        includesWAL = copiedWAL
    }
    deinit {
        database = nil
        try? FileManager.default.removeItem(at: temporary)
    }
    private static func fingerprint(_ source: URL) throws -> [String] {
        try ["", "-wal", "-journal"].map { suffix in
            let path = source.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { return "missing" }
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return "\(attrs[.size] ?? "")|\(String(describing: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970))|\(attrs[.systemFileNumber] ?? "")"
        }
    }
    private func column(_ table: String, _ name: String, _ alias: String, fallback: String = "NULL") -> String {
        schema[table]?.contains(name) == true ? "\(alias).\"\(name)\"" : fallback
    }
    private var dateSQL: String {
        "CASE WHEN ABS(COALESCE(m.date,0)) > 100000000000 THEN m.date/1000000000.0 ELSE COALESCE(m.date,0) END"
    }
    private let unassignedSQL = "NOT EXISTS (SELECT 1 FROM chat_message_join j JOIN chat c ON c.ROWID=j.chat_id WHERE j.message_id=m.ROWID)"

    func summary() throws -> BackupSummary {
        var oldest: Date?, newest: Date?
        try db.rows("SELECT MIN(\(dateSQL)), MAX(\(dateSQL)) FROM message m WHERE m.date != 0") {
            oldest = messageDate($0.number(0)); newest = messageDate($0.number(1))
        }
        return BackupSummary(messages: Int(try db.scalar("SELECT COUNT(*) FROM message")),
                             conversations: Int(try db.scalar("SELECT COUNT(*) FROM chat")),
                             attachments: schema["attachment"]?.isEmpty == false ? Int(try db.scalar("SELECT COUNT(*) FROM attachment")) : 0,
                             unassigned: Int(try db.scalar("SELECT COUNT(*) FROM message m WHERE \(unassignedSQL)")),
                             oldest: oldest, newest: newest, includesWAL: includesWAL,
                             attachmentMetadataAvailable: schema["attachment"]?.contains("filename") == true)
    }
    private func savedConversations() throws -> [Conversation] {
        var participants: [Int64: [String]] = [:]
        if schema["chat_handle_join"]!.isSuperset(of: ["chat_id", "handle_id"]), schema["handle"]!.contains("id") {
            try db.rows("SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id ORDER BY h.id") {
                participants[$0.integer(0), default: []].append($0.text(1) ?? "Unknown")
            }
        }
        var result: [Conversation] = []
        let sql = """
        SELECT c.ROWID, \(column("chat", "display_name", "c")), \(column("chat", "chat_identifier", "c")),
               COUNT(DISTINCT m.ROWID), MAX(\(dateSQL)),
               \(column("chat", "guid", "c")), \(column("chat", "style", "c", fallback: "0"))
        FROM chat c LEFT JOIN chat_message_join j ON j.chat_id=c.ROWID
        LEFT JOIN message m ON m.ROWID=j.message_id GROUP BY c.ROWID ORDER BY 5 DESC, c.ROWID DESC
        """
        try db.rows(sql) { row in
            let id = row.integer(0)
            let addresses = participants[id] ?? []
            let identifier = row.text(2) ?? ""
            let people = addresses.joined(separator: ", ")
            let name = row.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = !name.isEmpty ? name : (!people.isEmpty ? people : row.text(2) ?? "Conversation \(id)")
            let isGroup = addresses.count > 1 || row.integer(6) == 43 || identifier.lowercased().hasPrefix("chat")
            result.append(Conversation(id: id, title: title, participants: people, count: Int(row.integer(3)), latest: messageDate(row.number(4)),
                                       addresses: addresses.isEmpty && !isGroup && !identifier.isEmpty ? [identifier] : addresses,
                                       displayName: name, guid: row.text(5) ?? "", isGroup: isGroup))
        }
        return result
    }
    // This index only affects the reader's presentation. Never manufacture source chat links.
    private func preparePlacements() throws {
        guard !placementsReady else { return }
        let chats = try savedConversations()
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        func addressKey(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var memberships: [String: Set<Int64>] = [:]
        for chat in chats {
            for address in chat.addresses where !address.isEmpty { memberships[addressKey(address), default: []].insert(chat.id) }
        }
        let hasHandles = schema["handle"]!.contains("id") && schema["message"]!.contains("handle_id")
        if hasHandles {
            // Historical senders also count: someone removed from a group may no longer
            // appear in chat_handle_join, but that group is still a competing possibility.
            try db.rows("SELECT DISTINCT h.id,j.chat_id FROM message m JOIN handle h ON h.ROWID=m.handle_id JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id") {
                if let address = $0.text(0), !address.isEmpty { memberships[addressKey(address), default: []].insert($0.integer(1)) }
            }
        }
        var recoverable: [Int64: Set<Int64>] = [:]
        if schema["chat_recoverable_message_join"]!.isSuperset(of: ["message_id", "chat_id"]) {
            try db.rows("SELECT message_id,chat_id FROM chat_recoverable_message_join") {
                recoverable[$0.integer(0), default: []].insert($0.integer(1))
            }
        }
        var linkedGUIDs: [String: Set<Int64>] = [:]
        if schema["message"]!.contains("guid") {
            try db.rows("SELECT m.guid,j.chat_id FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE m.guid IS NOT NULL") {
                if let guid = $0.text(0) { linkedGUIDs[guid, default: []].insert($0.integer(1)) }
            }
        }
        var resolved: [Int64: Placement] = [:]
        let sql = """
        SELECT m.ROWID,m.date,\(hasHandles ? "h.id" : "NULL"),
            \(column("message", "cache_roomnames", "m")), \(column("message", "group_title", "m")),
            \(column("message", "reply_to_guid", "m")), \(column("message", "thread_originator_guid", "m"))
        FROM message m \(hasHandles ? "LEFT JOIN handle h ON h.ROWID=m.handle_id" : "")
        WHERE \(unassignedSQL) AND (\(unlinkedCondition(.ordinary)))
        """
        try db.rows(sql) { row in
            // Without a timestamp there is no honest chronological insertion point.
            guard let date = messageDate(row.number(1)) else { return }
            guard (row.text(3) ?? "").isEmpty, (row.text(4) ?? "").isEmpty else { return }
            let address = addressKey(row.text(2) ?? "")
            var explicit = recoverable[row.integer(0)] ?? []
            var hasReference = !explicit.isEmpty
            for index in [Int32(5), Int32(6)] {
                if let guid = row.text(index), !guid.isEmpty {
                    guard let targets = linkedGUIDs[guid], !targets.isEmpty else { return }
                    explicit.formUnion(targets)
                    hasReference = true
                }
            }
            let candidates = hasReference ? explicit : memberships[address] ?? []
            guard candidates.count == 1, let id = candidates.first, let chat = byID[id],
                  !chat.isGroup, chat.addresses.count == 1,
                  !chat.addresses[0].isEmpty,
                  (address.isEmpty ? hasReference : addressKey(chat.addresses[0]) == address) else { return }
            resolved[row.integer(0)] = Placement(chat: id, date: date,
                reason: hasReference ? "A saved reply or recoverable-message reference points to this two-person chat."
                    : "This sender appears in only one saved conversation, a two-person chat.")
        }
        placements = resolved
        placementsReady = true
    }
    private var unplacedSQL: String {
        placements.isEmpty ? unassignedSQL : "\(unassignedSQL) AND m.ROWID NOT IN (\(placements.keys.sorted().map(String.init).joined(separator: ",")))"
    }
    func conversations() throws -> [Conversation] {
        try preparePlacements()
        var result = try savedConversations()
        let grouped = Dictionary(grouping: placements.values, by: \.chat)
        for index in result.indices {
            let inferred = grouped[result[index].id] ?? []
            result[index].inferredCount = inferred.count
            result[index].count += inferred.count
            result[index].latest = ([result[index].latest] + inferred.map(\.date)).compactMap { $0 }.max()
        }
        result.sort { ($0.latest ?? .distantPast, $0.id) > ($1.latest ?? .distantPast, $1.id) }
        let orphanCount = Int(try db.scalar("SELECT COUNT(*) FROM message m WHERE \(unplacedSQL)"))
        if orphanCount > 0 {
            result.append(Conversation(id: -1, title: "Without a chat ID", participants: "Unplaced messages and events", count: orphanCount, latest: nil))
        }
        return result
    }
    private func decodeMessage(_ row: Row) -> Message {
        let attributed = row.data(3)
        let decoded = BodyDecoder.decode(attributed)
        let plain = row.text(2)
        let original = decoded ?? ((plain?.isEmpty == false) ? plain : nil)
        let kind = row.integer(7)
        let item = row.integer(8)
        let event = MessageEvent.decode(item: item, action: row.integer(11), handle: row.integer(13), otherHandle: row.integer(12),
                                        otherAddress: row.text(16), groupName: row.text(14), shareStatus: row.integer(15))
        var note: String?
        if kind != 0 { note = "Reaction or associated event (\(kind))" }
        else if item != 0 { note = event == nil ? "Conversation event (\(item))" : "Interpreted from historical event metadata" }
        else if row.text(9)?.isEmpty == false { note = "App or rich content" }
        if attributed != nil && decoded == nil {
            note = [note, plain?.isEmpty == false ? "Showing plain-text fallback" : "Text format not decoded"].compactMap { $0 }.joined(separator: " · ")
        }
        let subject = row.text(10).flatMap { $0.isEmpty ? nil : $0 }
        let body = [subject, original.map(BodyDecoder.visible)].compactMap { $0 }.joined(separator: "\n")
        return Message(id: row.integer(0), sender: row.integer(4) != 0 ? "You" : row.text(6) ?? "Unknown sender",
                       fromMe: row.integer(4) != 0, date: messageDate(row.number(5)),
                       body: body.isEmpty ? event?.description() ?? "[Non-text or empty message]" : body, note: note,
                       event: event, hasReadableText: !body.isEmpty, placementReason: placements[row.integer(0)]?.reason)
    }
    private func unlinkedCondition(_ scope: UnlinkedScope) -> String {
        func field(_ name: String) -> String { "COALESCE(\(column("message", name, "m", fallback: "0")),0)" }
        let item = field("item_type"), action = field("group_action_type")
        let other = field("other_handle"), sender = field("handle_id"), association = field("associated_message_type")
        let added = "(\(item)=1 AND \(action)=0 AND \(other)>0 AND \(other)!=\(sender) AND \(association)=0)"
        switch scope {
        case .all: return "1"
        case .remaining: return unlinkedCondition(.ordinary)
        case .participantAdditions: return added
        case .ordinary: return "\(item)=0 AND \(association)=0"
        case .numberChangeCandidates: return "\(item)=1 AND \(action)=0 AND \(other)>0 AND \(other)=\(sender) AND \(association)=0"
        case .locationSharing: return "\(item)=4 AND \(association)=0"
        case .reactions: return "\(association)!=0"
        case .otherEvents:
            return "\(item)!=0 AND \(association)=0 AND NOT (\(added)) AND NOT (\(unlinkedCondition(.numberChangeCandidates))) AND NOT (\(unlinkedCondition(.locationSharing)))"
        }
    }
    func unlinkedCounts() throws -> [UnlinkedScope: Int] {
        try preparePlacements()
        let scopes = UnlinkedScope.allCases
        let expressions = scopes.map { "COALESCE(SUM(CASE WHEN \(unlinkedCondition($0)) THEN 1 ELSE 0 END),0)" }.joined(separator: ",")
        var result: [UnlinkedScope: Int] = [:]
        try db.rows("SELECT \(expressions) FROM message m WHERE \(unplacedSQL)") { row in
            for (index, scope) in scopes.enumerated() { result[scope] = Int(row.integer(Int32(index))) }
        }
        return result
    }
    func messages(chat: Int64, page requestedPage: Int, search: String = "", unlinkedScope: UnlinkedScope = .all) throws -> MessagePage {
        try preparePlacements()
        let inferredIDs = placements.filter { $0.value.chat == chat }.keys.sorted().map(String.init).joined(separator: ",")
        let saved = "EXISTS (SELECT 1 FROM chat_message_join j WHERE j.message_id=m.ROWID AND j.chat_id=?)"
        let predicate = chat == -1 ? "\(unplacedSQL) AND (\(unlinkedCondition(unlinkedScope)))" : "(\(saved)\(inferredIDs.isEmpty ? "" : " OR m.ROWID IN (\(inferredIDs))"))"
        let params: [Int64] = chat == -1 ? [] : [chat]
        let handleJoin = schema["handle"]!.contains("id") && schema["message"]!.contains("handle_id")
        let otherJoin = schema["handle"]!.contains("id") && schema["message"]!.contains("other_handle")
        let sql = """
        SELECT m.ROWID, \(column("message", "guid", "m")), \(column("message", "text", "m")),
            \(column("message", "attributedBody", "m")), m.is_from_me, m.date,
            \(handleJoin ? "h.id" : "NULL"), \(column("message", "associated_message_type", "m", fallback: "0")),
            \(column("message", "item_type", "m", fallback: "0")), \(column("message", "balloon_bundle_id", "m")),
            \(column("message", "subject", "m")), \(column("message", "group_action_type", "m", fallback: "0")),
            \(column("message", "other_handle", "m", fallback: "0")), \(column("message", "handle_id", "m", fallback: "0")),
            \(column("message", "group_title", "m")), \(column("message", "share_status", "m", fallback: "0")),
            \(otherJoin ? "oh.id" : "NULL")
        FROM message m \(handleJoin ? "LEFT JOIN handle h ON h.ROWID=m.handle_id" : "")
            \(otherJoin ? "LEFT JOIN handle oh ON oh.ROWID=m.other_handle" : "")
        WHERE \(predicate) ORDER BY \(dateSQL) DESC, m.ROWID DESC
        """
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var total = 0
        var items: [Message] = []
        var page = max(0, requestedPage)
        if query.isEmpty {
            total = Int(try db.scalar("SELECT COUNT(*) FROM message m WHERE \(predicate)", integers: params))
            page = min(page, max(0, (total - 1) / MessagePage.size))
            try db.rows(sql + " LIMIT \(MessagePage.size) OFFSET \(page * MessagePage.size)", integers: params) { items.append(decodeMessage($0)) }
        } else {
            // Stream every row so attributedBody-only messages are searchable too.
            // Retain only the requested page, even for huge conversations.
            try db.rows(sql, integers: params) {
                let message = decodeMessage($0)
                if message.body.localizedCaseInsensitiveContains(query) || message.sender.localizedCaseInsensitiveContains(query) {
                    if total >= page * MessagePage.size && total < (page + 1) * MessagePage.size { items.append(message) }
                    total += 1
                }
            }
        }
        if !items.isEmpty, schema["message_attachment_join"]!.isSuperset(of: ["message_id", "attachment_id"]), schema["attachment"]?.isEmpty == false {
            var attached: [Int64: [Attachment]] = [:]
            let ids = items.map { String($0.id) }.joined(separator: ",")
            try db.rows("SELECT j.message_id, \(attachmentSelect) FROM message_attachment_join j JOIN attachment a ON a.ROWID=j.attachment_id WHERE j.message_id IN (\(ids)) ORDER BY a.ROWID") {
                attached[$0.integer(0), default: []].append(attachment($0, start: 1))
            }
            for index in items.indices { items[index].attachments = attached[items[index].id] ?? [] }
        }
        return MessagePage(messages: items.reversed(), total: total, page: page)
    }
    private var attachmentSelect: String {
        "a.ROWID, \(column("attachment", "transfer_name", "a")), \(column("attachment", "filename", "a")), \(column("attachment", "total_bytes", "a", fallback: "0")), \(column("attachment", "mime_type", "a"))"
    }
    private func attachment(_ row: Row, start: Int32) -> Attachment {
        let path = row.text(start + 2)
        let name = row.text(start + 1).flatMap { $0.isEmpty ? nil : $0 } ?? path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unnamed attachment"
        return Attachment(id: row.integer(start), name: name, path: path, bytes: row.integer(start + 3), mime: row.text(start + 4) ?? "File")
    }
    func attachmentURL(_ attachment: Attachment) -> URL? {
        guard let path = attachment.path, !path.isEmpty else { return nil }
        let relative: String
        if let range = path.range(of: "Attachments/") { relative = String(path[range.lowerBound...]) }
        else if !path.hasPrefix("/") && !path.hasPrefix("~") { relative = path }
        else { return nil }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        // Never fall back to the original Mac's attachment paths, which would mask backup gaps.
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }
    func readableAttachmentURL(_ attachment: Attachment) throws -> URL {
        guard let url = attachmentURL(attachment) else {
            throw ReaderError("\(attachment.name) has no usable file path inside the selected backup.")
        }
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &directory) else {
            throw ReaderError("\(attachment.name) is missing from the selected backup. It may not have been copied or downloaded from iCloud. Reconnect the drive if it was removed.\n\nExpected location: \(url.path)")
        }
        guard !directory.boolValue, fm.isReadableFile(atPath: url.path) else {
            throw ReaderError("\(attachment.name) cannot be read as a file. Check access to the backup drive.\n\nLocation: \(url.path)")
        }
        return url
    }
    func scanAttachments() throws -> AttachmentReport {
        guard schema["attachment"]?.isEmpty == false else { throw ReaderError("This database has no attachment table.") }
        var report = AttachmentReport()
        try db.rows("SELECT \(attachmentSelect) FROM attachment a ORDER BY a.ROWID") { row in
            let item = attachment(row, start: 0)
            guard let url = attachmentURL(item) else {
                report.unknown += 1
                if report.examples.count < 20 { report.examples.append("No usable backup path: \(item.name)") }
                return
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular, FileManager.default.isReadableFile(atPath: url.path) else {
                    report.unknown += 1
                    if report.examples.count < 20 { report.examples.append("Unreadable file: \(item.name)") }
                    return
                }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                if item.bytes > 0 && size != item.bytes {
                    report.differentSize += 1
                    if report.examples.count < 20 { report.examples.append("Size differs: \(item.name) (expected \(item.bytes), found \(size) bytes)") }
                } else { report.present += 1 }
            } catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code) {
                    report.missing += 1
                    if report.examples.count < 20 { report.examples.append("Missing: \(item.name)") }
                } else {
                    report.unknown += 1
                    if report.examples.count < 20 { report.examples.append("Could not check: \(item.name)") }
                }
            }
        }
        return report
    }
}
