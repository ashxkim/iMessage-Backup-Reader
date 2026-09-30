import Foundation
import SQLite3

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ReaderError("TEST FAILED: \(message)") }
}
final class FixtureDB {
    var handle: OpaquePointer?
    init(_ path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else { throw ReaderError("Fixture open failed") }
    }
    deinit { sqlite3_close(handle) }
    func run(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ReaderError(String(cString: sqlite3_errmsg(handle))) }
    }
    func body(_ value: String, id: Int) throws {
        let data = NSArchiver.archivedData(withRootObject: NSAttributedString(string: value))
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try run("UPDATE message SET text=NULL, attributedBody=X'\(hex)' WHERE ROWID=\(id)")
    }
}

func createFixture(at root: URL) throws -> FixtureDB {
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("Attachments/demo"), withIntermediateDirectories: true)
    let db = try FixtureDB(root.appendingPathComponent("chat.db").path)
    try db.run("""
    CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER,
                          associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, balloon_bundle_id TEXT, subject TEXT);
    CREATE TABLE chat (display_name TEXT, chat_identifier TEXT);
    CREATE TABLE handle (id TEXT);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE attachment (transfer_name TEXT, filename TEXT, total_bytes INTEGER, mime_type TEXT);
    CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
    CREATE INDEX cm_chat ON chat_message_join(chat_id, message_id);
    INSERT INTO handle VALUES ('friend@example.com'), ('+1 (555) 010-1234');
    INSERT INTO chat VALUES ('Weekend plans', 'chat-demo'), ('', 'friend@example.com'), ('Empty conversation', 'empty');
    INSERT INTO chat_handle_join VALUES (1,1), (1,2), (2,1);
    """)
    for id in 1...405 {
        let value = "Test message \(id) — This is a sample conversation."
        try db.run("INSERT INTO message(ROWID,guid,text,date,is_from_me,handle_id) VALUES (\(id),'guid-\(id)','\(value)',\(800000000000000000 + Int64(id) * 1000000000),\(id % 2),1)")
        try db.run("INSERT INTO chat_message_join VALUES(1,\(id))")
    }
    try db.body("Photo from the weekend 📷\nUnicode works: 안녕 café 👩🏽‍💻\n\u{FFFC}", id: 405)
    try db.body("A long message: " + String(repeating: "hello 🌎 ", count: 100), id: 404)
    try db.run("""
    INSERT INTO message(ROWID,guid,text,date,is_from_me,handle_id,associated_message_type) VALUES(406,'reaction',NULL,800000500000000000,0,1,2001);
    INSERT INTO chat_message_join VALUES(1,406);
    INSERT INTO message(ROWID,guid,text,date,is_from_me,handle_id) VALUES(407,'old','An older SMS',500000000,0,1);
    INSERT INTO chat_message_join VALUES(2,407);
    INSERT INTO message(ROWID,guid,text,date,is_from_me,handle_id) VALUES(408,'orphan','Unassigned message',0,1,0);
    INSERT INTO attachment VALUES ('photo.jpg','~/Library/Messages/Attachments/demo/photo.jpg',5,'image/jpeg'),
      ('missing.mov','/Users/old/Library/Messages/Attachments/demo/missing.mov',100,'video/quicktime'),
      ('partial.pdf','Attachments/demo/partial.pdf',500,'application/pdf'),
      ('cloud.heic',NULL,100,'image/heic'),
      ('unsafe.txt','Attachments/../../outside.txt',3,'text/plain');
    INSERT INTO message_attachment_join VALUES(405,1),(405,2),(404,3);
    """)
    try Data("photo".utf8).write(to: root.appendingPathComponent("Attachments/demo/photo.jpg"))
    try Data("short".utf8).write(to: root.appendingPathComponent("Attachments/demo/partial.pdf"))
    return db
}

@main struct ReaderTests {
    static func main() throws {
        let fm = FileManager.default
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--demo" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            _ = try createFixture(at: root)
            print("Created synthetic demo at \(root.path)")
            return
        }
        let root = fm.temporaryDirectory.appendingPathComponent("ReaderTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let backup = root.appendingPathComponent("Messages")
        var fixture: FixtureDB? = try createFixture(at: backup)
        fixture = nil
        let source = backup.appendingPathComponent("chat.db")
        let before = try Data(contentsOf: source)
        var store: MessageStore? = try MessageStore(url: backup)
        let working = store!.temporary
        let summary = try store!.summary()
        try require(summary.messages == 408 && summary.conversations == 3 && summary.attachments == 5, "summary counts")
        try require(summary.unassigned == 1, "orphan count")
        try require(summary.oldest == messageDate(500000000), "mixed timestamp units")
        let chats = try store!.conversations()
        try require(chats.count == 4 && chats[0].title == "Weekend plans" && chats[0].count == 406, "conversation title, count and sorting")
        try require(chats.first { $0.id == 2 }?.title == "friend@example.com", "participant fallback")
        let newest = try store!.messages(chat: 1, page: 0)
        let middle = try store!.messages(chat: 1, page: 1)
        let oldest = try store!.messages(chat: 1, page: 2)
        try require(newest.messages.count == 200 && middle.messages.count == 200 && oldest.messages.count == 6, "pagination lengths")
        try require(newest.messages.last?.id == 406 && oldest.messages.first?.id == 1, "chronological order")
        let ids = (newest.messages + middle.messages + oldest.messages).map(\.id)
        try require(Set(ids).count == 406, "pagination covers every message once")
        let photo = newest.messages.first { $0.id == 405 }!
        try require(photo.body.contains("안녕 café 👩🏽‍💻") && photo.body.contains("[Attachment]"), "attributed unicode text")
        try require(photo.attachments.count == 2 && photo.attachments[0].name == "photo.jpg", "attachment placeholders")
        try require(newest.messages.last?.note?.contains("Reaction") == true, "reaction placeholder")
        let search = try store!.messages(chat: 1, page: 0, search: "안녕")
        try require(search.total == 1 && search.messages.first?.id == 405, "search encoded-only text")
        let oldSearch = try store!.messages(chat: 1, page: 0, search: "Test message 1 —")
        try require(oldSearch.total == 1 && oldSearch.messages.first?.id == 1, "search beyond newest page")
        let report = try store!.scanAttachments()
        try require(report.present == 1 && report.missing == 1 && report.differentSize == 1 && report.unknown == 2, "attachment path and size scan: \(report)")
        let resolvedPhoto = try store!.readableAttachmentURL(photo.attachments[0])
        try require(resolvedPhoto == backup.appendingPathComponent("Attachments/demo/photo.jpg").resolvingSymlinksInPath(), "attachment opens from backup root")
        do {
            _ = try store!.readableAttachmentURL(photo.attachments[1])
            throw ReaderError("TEST FAILED: missing attachment accepted")
        } catch let error as ReaderError {
            try require(error.message.contains("missing from the selected backup"), "missing attachment explains backup gap")
        }
        let escaped = Attachment(id: 99, name: "outside.txt", path: "Attachments/../../outside.txt", bytes: 3, mime: "text/plain")
        try require(store!.attachmentURL(escaped) == nil, "attachment traversal rejected")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside backup".utf8).write(to: outside)
        try fm.createSymbolicLink(at: backup.appendingPathComponent("Attachments/demo/link.txt"), withDestinationURL: outside)
        let linked = Attachment(id: 100, name: "link.txt", path: "Attachments/demo/link.txt", bytes: 3, mime: "text/plain")
        try require(store!.attachmentURL(linked) == nil, "attachment symlinks cannot escape backup")
        let noChat = try store!.messages(chat: -1, page: 0)
        try require(noChat.total == 1 && noChat.messages[0].id == 408, "unassigned messages readable")
        let empty = try store!.messages(chat: 3, page: 0)
        try require(empty.total == 0 && empty.messages.isEmpty, "empty chat")
        store = nil
        try require(!fm.fileExists(atPath: working.path), "temporary snapshot cleanup")
        let after = try Data(contentsOf: source)
        try require(before == after, "source database unchanged")
        let filenames = try fm.contentsOfDirectory(atPath: backup.path).sorted()
        try require(filenames == ["Attachments", "chat.db"], "no source sidecars created")
        print("PASS: browse, paging, search, unicode, placeholders, attachments, timestamps, cleanup, source preservation")
        print("PASS: attachment preview path resolution, missing files, traversal and symlink containment")

        for length in [0, 1, 127, 128, 145, 146, 255, 256, 4000, 70000] {
            let value = String(repeating: "a", count: length) + "👋"
            let data = NSArchiver.archivedData(withRootObject: NSAttributedString(string: value))
            try require(BodyDecoder.decode(data) == value, "typedstream byte length \(length)")
            try require(BodyDecoder.decode(data.prefix(20)) == nil, "truncated stream rejected")
        }
        try require(BodyDecoder.decode(Data(repeating: 255, count: 100)) == nil, "invalid body rejected")
        print("PASS: short, medium, long and malformed attributed bodies")

        // Keep a writer open: committed WAL-only data must appear in the reader without
        // checkpointing, modifying, or depending on a source SHM file.
        fixture = try FixtureDB(source.path)
        try fixture!.run("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try fixture!.run("INSERT INTO message(guid,text,date,is_from_me) VALUES('wal-only','Newest WAL message',900000000000000000,1)")
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walBefore = try Data(contentsOf: wal)
        let dbBeforeWALRead = try Data(contentsOf: source)
        store = try MessageStore(url: source)
        let walSummary = try store!.summary()
        try require(walSummary.includesWAL && walSummary.messages == 409, "WAL-only record included")
        store = nil
        let walAfter = try Data(contentsOf: wal)
        let dbAfterWALRead = try Data(contentsOf: source)
        try require(walBefore == walAfter && dbBeforeWALRead == dbAfterWALRead, "WAL and DB preserved")
        let readOnly = root.appendingPathComponent("ReadOnlySD")
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let cardDB = readOnly.appendingPathComponent("chat.db")
        let cardWAL = readOnly.appendingPathComponent("chat.db-wal")
        try dbBeforeWALRead.write(to: cardDB)
        try walBefore.write(to: cardWAL)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: cardDB.path)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: cardWAL.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        store = try MessageStore(url: readOnly)
        let cardSummary = try store!.summary()
        try require(cardSummary.messages == 409 && cardSummary.includesWAL, "read-only SD backup without SHM includes WAL")
        store = nil
        let cardFiles = try fm.contentsOfDirectory(atPath: readOnly.path).sorted()
        try require(cardFiles == ["chat.db", "chat.db-wal"], "read-only SD has no new sidecars")
        fixture = nil
        print("PASS: WAL recovery, original WAL/database preservation, read-only media without SHM")

        // Legacy schemas may omit optional text, attachment, handle and event fields.
        let legacy = root.appendingPathComponent("legacy")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        var oldDB: FixtureDB? = try FixtureDB(legacy.appendingPathComponent("chat.db").path)
        try oldDB!.run("CREATE TABLE message(text TEXT,date INTEGER,is_from_me INTEGER); CREATE TABLE chat(chat_identifier TEXT); CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER); INSERT INTO message VALUES('Legacy SMS',600000000,1); INSERT INTO chat VALUES('555'); INSERT INTO chat_message_join VALUES(1,1);")
        oldDB = nil
        let oldStore = try MessageStore(url: legacy)
        let oldMessages = try oldStore.messages(chat: 1, page: 0)
        try require(oldMessages.messages.first?.body == "Legacy SMS", "legacy optional-column tolerance")
        let bad = root.appendingPathComponent("bad.db")
        try Data("not a database".utf8).write(to: bad)
        do { _ = try MessageStore(url: bad); throw ReaderError("TEST FAILED: malformed DB accepted") }
        catch let error as ReaderError where error.message.hasPrefix("TEST FAILED") { throw error }
        catch { }
        print("PASS: legacy schema and invalid database handling")

        let names = ContactNames([
            NamedContact(id: "friend", name: "Sam Example", addresses: ["+1 (212) 555-0123", "friend@EXAMPLE.com"]),
            NamedContact(id: "uk", name: "Alex Abroad", addresses: ["+44 7700 900123"]),
            NamedContact(id: "saved-short", name: "Saved Short Contact", addresses: ["54321"])
        ])
        try require(names.name(for: "+12125550123") == "Sam Example", "formatted phone contact match")
        try require(names.name(for: "2125550123") == "Sam Example", "North-American number without country code")
        try require(names.name(for: "FRIEND@example.com") == "Sam Example", "case-insensitive email contact match")
        try require(names.name(for: "+447700900123") == "Alex Abroad", "international contact match")
        try require(names.name(for: "7700900123") == nil, "do not guess international suffix matches")
        let ambiguous = ContactNames([
            NamedContact(id: "one", name: "One", addresses: ["+12125550123"]),
            NamedContact(id: "two", name: "Two", addresses: ["+12125550123"])
        ])
        try require(ambiguous.name(for: "+12125550123") == nil, "ambiguous contact stays a number")
        func chat(_ address: String, group: Bool = false) -> Conversation {
            Conversation(id: 1, title: address, participants: address, count: 1, latest: nil, addresses: [address], isGroup: group)
        }
        try require(names.title(for: chat("friend@example.com")) == "Sam Example", "sidebar resolves contact name")
        var namedGroup = chat("friend@example.com", group: true)
        namedGroup.displayName = "Weekend plans"
        try require(names.title(for: namedGroup) == "Weekend plans", "explicit group names preserved")
        try require(BusinessClassifier.reason(for: chat("12345"), contacts: names) != nil, "short-code detection")
        try require(BusinessClassifier.reason(for: chat("DELIVERY"), contacts: names) != nil, "alphanumeric sender detection")
        for address in ["2125550123", "+447700900123", "5551234", "someone@example.com", "54321"] {
            try require(BusinessClassifier.reason(for: chat(address), contacts: names) == nil, "plausible personal or saved sender kept: \(address)")
        }
        try require(BusinessClassifier.reason(for: chat("12345", group: true), contacts: names) == nil, "groups not auto-filtered as businesses")
        try require(BusinessClassifier.reason(for: chat("1234567890123456"), contacts: names) != nil, "unusual-length sender detection")
        print("PASS: contact matching, ambiguous contacts, group names, short-code filtering and international-number exceptions")

        let eventRoot = root.appendingPathComponent("Events")
        try fm.createDirectory(at: eventRoot, withIntermediateDirectories: true)
        var eventDB: FixtureDB? = try FixtureDB(eventRoot.appendingPathComponent("chat.db").path)
        try eventDB!.run("""
        CREATE TABLE message(text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,item_type INTEGER,group_action_type INTEGER,other_handle INTEGER,group_title TEXT,share_status INTEGER);
        CREATE TABLE chat(chat_identifier TEXT,style INTEGER,guid TEXT);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE handle(id TEXT);
        INSERT INTO handle VALUES('+12125550123'),('friend@example.com');
        INSERT INTO message VALUES(NULL,700000000,0,1,1,0,2,NULL,0), (NULL,700000001,0,1,1,0,1,NULL,0), (NULL,700000002,0,1,4,0,0,NULL,0);
        INSERT INTO chat VALUES('chat-synthetic',43,'group-guid');
        """)
        eventDB = nil
        let eventsStore = try MessageStore(url: eventRoot)
        let events = try eventsStore.messages(chat: -1, page: 0)
        try require(events.messages[0].event?.description(contacts: names) == "Participant-added event: Sam Example", "group event interpretation and contact name")
        try require(events.messages[1].body.hasPrefix("Possible number-change / membership event:"), "ambiguous self-referencing handle event")
        try require(events.messages[2].body == "Location-sharing-started event", "historical location event")
        let eventChats = try eventsStore.conversations()
        try require(eventChats.first { $0.id == 1 }?.isGroup == true && eventChats.first { $0.id == 1 }?.guid == "group-guid", "group metadata and stable preference identity")
        print("PASS: participant, phone-number and location event rendering; original record count preserved")

        eventDB = try FixtureDB(eventRoot.appendingPathComponent("chat.db").path)
        for index in 0..<205 {
            try eventDB!.run("INSERT INTO message(ROWID,text,date,is_from_me,handle_id,item_type,group_action_type,other_handle) VALUES(\(index + 4),'Ordinary record \(index)',\(700000010 + index),0,1,0,0,0)")
            try eventDB!.run("INSERT INTO message(ROWID,date,is_from_me,handle_id,item_type,group_action_type,other_handle) VALUES(\(index + 209),\(700001010 + index),0,1,1,0,2)")
        }
        try eventDB!.run("INSERT INTO message(ROWID,date,is_from_me,handle_id,item_type,group_action_type,other_handle) VALUES(414,700002000,0,1,1,0,2); INSERT INTO chat_message_join VALUES(1,414)")
        eventDB = nil
        let foldedStore = try MessageStore(url: eventRoot)
        let counts = try foldedStore.unlinkedCounts()
        try require(counts[.all] == 413 && counts[.remaining] == 205 && counts[.participantAdditions] == 206, "folding partitions all unlinked rows")
        try require(counts[.ordinary] == 205 && counts[.numberChangeCandidates] == 1 && counts[.locationSharing] == 1 && counts[.reactions] == 0, "investigation filter counts")
        let visibleFirst = try foldedStore.messages(chat: -1, page: 0, unlinkedScope: .remaining)
        let visibleLast = try foldedStore.messages(chat: -1, page: 1, unlinkedScope: .remaining)
        let foldedFirst = try foldedStore.messages(chat: -1, page: 0, unlinkedScope: .participantAdditions)
        let foldedLast = try foldedStore.messages(chat: -1, page: 1, unlinkedScope: .participantAdditions)
        let visibleIDs = Set((visibleFirst.messages + visibleLast.messages).map(\.id))
        let foldedIDs = Set((foldedFirst.messages + foldedLast.messages).map(\.id))
        try require(visibleIDs.count == 205 && foldedIDs.count == 206 && visibleIDs.isDisjoint(with: foldedIDs), "independent paging without duplicated or omitted records")
        var sectionIDs = foldedIDs
        for scope in UnlinkedScope.eventSections where scope != .participantAdditions {
            let section = try foldedStore.messages(chat: -1, page: 0, unlinkedScope: scope)
            let ids = Set(section.messages.map(\.id))
            try require(sectionIDs.isDisjoint(with: ids) && visibleIDs.isDisjoint(with: ids), "event sections do not overlap")
            sectionIDs.formUnion(ids)
        }
        try require(visibleIDs.union(sectionIDs).count == 413 && !visibleIDs.contains(2) && !visibleIDs.contains(3), "all events are in collapsible sections")
        let foldedSearch = try foldedStore.messages(chat: -1, page: 0, search: "friend@example.com", unlinkedScope: .participantAdditions)
        let ordinarySearch = try foldedStore.messages(chat: -1, page: 0, search: "Ordinary record 204", unlinkedScope: .ordinary)
        try require(foldedSearch.total == 206 && ordinarySearch.total == 1, "search respects investigation and collapsed scopes")
        let linkedEvent = try foldedStore.messages(chat: 1, page: 0, unlinkedScope: .remaining)
        try require(linkedEvent.total == 1 && linkedEvent.messages[0].id == 414, "ordinary linked conversations are unaffected by folding")
        let legacyCounts = try oldStore.unlinkedCounts()
        try require(legacyCounts[.all] == 0 && legacyCounts[.participantAdditions] == 0, "new filters tolerate missing legacy columns")
        print("PASS: collapsed event partition, independent pagination, investigation filters and scoped search")
        try testInferredPlacement(root: root)
        print("All tests passed.")
    }
}

// Missing conversation links must not turn group messages into direct messages.
func testInferredPlacement(root: URL) throws {
    let folder = root.appendingPathComponent("Placement")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("chat.db")
    var fixture: FixtureDB? = try FixtureDB(source.path)
    try fixture!.run("""
    CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,handle_id INTEGER,
        item_type INTEGER DEFAULT 0,associated_message_type INTEGER DEFAULT 0,cache_roomnames TEXT,
        group_title TEXT,reply_to_guid TEXT,thread_originator_guid TEXT);
    CREATE TABLE chat(chat_identifier TEXT,style INTEGER);
    CREATE TABLE handle(id TEXT);
    CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
    CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
    CREATE TABLE chat_recoverable_message_join(chat_id INTEGER,message_id INTEGER);
    CREATE TABLE attachment(filename TEXT,transfer_name TEXT);
    CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
    INSERT INTO handle VALUES('alice@example.com'),('bob@example.com'),('charlie@example.com'),
        ('dan@example.com'),('eve@example.com'),('fred@example.com'),('past-member@example.com');
    INSERT INTO chat VALUES('alice@example.com',45),('chat-group',43),('charlie@example.com',45),
        ('bob@example.com',45),('dan@example.com',45),('dan@example.com',45),('eve@example.com',45),
        ('chat-one-remaining-person',43),('past-member@example.com',45);
    INSERT INTO chat_handle_join VALUES(1,1),(2,1),(2,2),(3,3),(4,2),(5,4),(6,4),(8,6),(9,7);
    INSERT INTO message(ROWID,guid,text,date,is_from_me,handle_id) VALUES
        (1,'older','Linked older',700000100,0,3),(2,'newer','Linked newer',700000300000000000,1,3),
        (3,'inferred-in','Inferred incoming',700000200,0,3),(4,'inferred-out','Inferred outgoing',700000200000000000,1,3),
        (5,'alice-unknown','Could be group',700000200,0,1),(6,'bob-unknown','Could be group too',700000200,0,2),
        (7,'dan-unknown','Duplicate direct chats',700000200,0,4),(8,'no-handle','Unknown recipient',700000200,1,0),
        (9,'fred-unknown','Group with one remaining person',700000200,0,6),(10,'eve-unknown','Identifier fallback',700000200,0,5),
        (11,'room','Group room metadata',700000200,0,3),(12,'reply-direct','Reply to direct',700000200,0,1),
        (13,'direct-parent','Parent in direct',700000100,1,1),(14,'reply-group','Reply to group',700000200,0,1),
        (15,'group-parent','Parent in group',700000100,0,1),(16,'recover','Recoverable direct reference',700000200,0,1),
        (17,'conflict','Contradictory references',700000200,0,1),(18,'missing-parent','Unknown reply target',700000200,0,3),
        (19,'no-date','Missing timestamp',0,0,3),(20,'location',NULL,700000200,0,3),
        (21,'reaction',NULL,700000200,0,3),(22,'other-event',NULL,700000200,0,3),
        (23,'dangling-chat','Missing recoverable chat',700000200,0,3),
        (24,'reply-without-handle','You replied to direct parent',700000200,1,0),
        (25,'group-name','Group title metadata',700000200,0,3),
        (26,'past-group-member','Historical participant',700000100,0,7),
        (27,'past-ambiguous','Historical group candidate',700000200,0,7),
        (28,'wrong-sender','Reply sender mismatches direct chat',700000200,0,3);
    INSERT INTO chat_message_join VALUES(3,1),(3,2),(3,2),(1,13),(2,15),(2,26);
    UPDATE message SET cache_roomnames='chat-missing' WHERE ROWID=11;
    UPDATE message SET group_title='Group name' WHERE ROWID=25;
    UPDATE message SET reply_to_guid='direct-parent' WHERE ROWID IN (12,24,28);
    UPDATE message SET thread_originator_guid='group-parent' WHERE ROWID=14;
    UPDATE message SET reply_to_guid='group-parent' WHERE ROWID=17;
    UPDATE message SET reply_to_guid='not-in-backup' WHERE ROWID=18;
    UPDATE message SET item_type=4 WHERE ROWID=20;
    UPDATE message SET associated_message_type=2001 WHERE ROWID=21;
    UPDATE message SET item_type=99 WHERE ROWID=22;
    INSERT INTO chat_recoverable_message_join VALUES(1,16),(1,17),(999,23);
    INSERT INTO attachment VALUES('Attachments/photo.jpg','photo.jpg');
    INSERT INTO message_attachment_join VALUES(3,1);
    """)
    fixture = nil
    let original = try Data(contentsOf: source)
    let store = try MessageStore(url: folder)
    // Exercise messages before conversations: inference should not depend on UI call order.
    let direct = try store.messages(chat: 3, page: 0)
    try require(direct.messages.map(\.id) == [1,3,4,2], "inferred rows interleave with saved rows by mixed-unit timestamps and stable ID tie-break")
    try require(direct.messages.filter { $0.placementReason != nil }.map(\.id) == [3,4], "only inferred messages carry the uncertainty note")
    try require(direct.messages.first { $0.id == 3 }?.attachments.count == 1, "inferred attachments preserved")
    let explicit = try store.messages(chat: 1, page: 0)
    try require(Set(explicit.messages.map(\.id)) == Set([13,12,16,24]), "unique direct reply and recoverable references allow placement")
    let orphan = try store.messages(chat: -1, page: 0)
    let expectedUnplaced: Set<Int64> = [5,6,7,8,9,11,14,17,18,19,20,21,22,23,25,27,28]
    try require(Set(orphan.messages.map(\.id)) == expectedUnplaced, "group, unknown, conflicting and duplicate candidates stay unplaced")
    let chats = try store.conversations()
    try require(chats.first { $0.id == 3 }?.count == 4 && chats.first { $0.id == 3 }?.inferredCount == 2, "conversation counts include inferred records once")
    try require(chats.first { $0.id == 7 }?.count == 1 && chats.first { $0.id == 7 }?.latest == messageDate(700000200), "chat identifier fallback and inferred latest date")
    try require(chats.first { $0.id == -1 }?.title == "Without a chat ID" && chats.first { $0.id == -1 }?.count == 17, "unplaced sidebar count and name")
    let counts = try store.unlinkedCounts()
    try require(counts[.all] == 17 && counts[.remaining] == 14 && counts[.reactions] == 1 && counts[.locationSharing] == 1 && counts[.otherEvents] == 1, "unplaced timeline plus event buckets account for every record")
    let search = try store.messages(chat: 3, page: 0, search: "Inferred incoming")
    let absent = try store.messages(chat: -1, page: 0, search: "Inferred incoming")
    try require(search.messages.first?.id == 3 && search.total == 1 && absent.total == 0, "search finds moved records only in the destination")
    let summary = try store.summary()
    try require(summary.messages == 28 && summary.unassigned == 23 && chats.reduce(0) { $0 + $1.count } == 28, "raw backup totals retained and display accounts for all records")
    let sourceAfter = try Data(contentsOf: source)
    try require(sourceAfter == original, "inference does not edit the backup")

    fixture = try FixtureDB(source.path)
    for index in 0..<205 {
        try fixture!.run("INSERT INTO message(ROWID,guid,text,date,is_from_me,handle_id) VALUES(\(100 + index),'paged-\(index)','Paged inferred message',\(700000400 + index),\(index % 2),3)")
    }
    fixture = nil
    let paged = try MessageStore(url: folder)
    let latest = try paged.messages(chat: 3, page: 0)
    let oldest = try paged.messages(chat: 3, page: 1)
    let ids = (oldest.messages + latest.messages).map(\.id)
    try require(latest.total == 209 && latest.messages.count == 200 && oldest.messages.count == 9 && Set(ids).count == 209, "inferred and saved records page together without omissions or duplicates")
    try require(Array(ids.prefix(4)) == [1,3,4,2] && ids.last == 304, "merged pagination remains chronological")
    print("PASS: conservative direct-chat placement, explicit references, group ambiguity, timestamp insertion, labels, attachment/search/paging and source preservation")
}
