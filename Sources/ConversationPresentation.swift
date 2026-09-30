import Foundation

struct NamedContact: Hashable {
    let id: String
    let name: String
    let addresses: [String]
}

struct ContactNames {
    private var matches: [String: Set<NamedContact>] = [:]
    var count = 0

    init(_ contacts: [NamedContact] = []) {
        count = contacts.count
        for contact in contacts where !contact.name.isEmpty {
            for address in contact.addresses {
                for key in Self.keys(address) { matches[key, default: []].insert(contact) }
            }
        }
    }
    static func keys(_ address: String) -> [String] {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("@") { return ["email:" + value] }
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return ["literal:" + value] }
        let digits = value.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return [] }
        var keys = ["phone:" + digits]
        // Limited, explicit North-American equivalence; never match arbitrary suffixes.
        if digits.count == 11 && digits.hasPrefix("1") { keys.append("nanp:" + digits.dropFirst()) }
        else if digits.count == 10 && !value.hasPrefix("+") { keys.append("nanp:" + digits) }
        return keys
    }
    private func candidates(_ address: String) -> Set<NamedContact> {
        let keys = Self.keys(address)
        if let exact = keys.first.flatMap({ matches[$0] }), !exact.isEmpty { return exact }
        return keys.dropFirst().reduce(into: Set<NamedContact>()) { result, key in result.formUnion(matches[key] ?? []) }
    }
    func name(for address: String) -> String? {
        let candidates = candidates(address)
        guard candidates.count == 1 else { return nil }
        return candidates.first?.name
    }
    func contains(_ address: String) -> Bool { !candidates(address).isEmpty }
    func display(_ address: String) -> String { name(for: address) ?? address }
    func title(for chat: Conversation) -> String {
        if chat.id == -1 { return chat.title }
        if !chat.displayName.isEmpty { return chat.displayName }
        return chat.addresses.isEmpty ? chat.title : chat.addresses.map(display).joined(separator: ", ")
    }
}

enum ConversationCategory: String, CaseIterable, Identifiable {
    case people = "People"
    case businesses = "Businesses"
    case all = "All"
    var id: String { rawValue }
}

enum BusinessClassifier {
    static func reason(for chat: Conversation, contacts: ContactNames) -> String? {
        guard chat.id != -1, !chat.isGroup, chat.addresses.count == 1,
              let address = chat.addresses.first, !contacts.contains(address) else { return nil }
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // Email addresses may be real people. A missing '+' is not evidence on its own.
        guard !value.isEmpty, !value.contains("@") else { return nil }
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            let digits = value.filter { $0.isASCII && $0.isNumber }
            if (3...6).contains(digits.count) { return "Likely business: \(digits.count)-digit short code" }
            if !(7...15).contains(digits.count) { return "Likely business: unusual phone-number length" }
            return nil
        }
        guard !value.lowercased().hasPrefix("chat"), UUID(uuidString: value) == nil else { return nil }
        return "Likely business: alphanumeric sender ID"
    }
}

struct MessageEvent {
    enum Kind { case participantAdded, participantRemoved, phoneNumberChanged, groupRenamed, participantLeft, iconChanged, iconRemoved, locationStarted, locationStopped }
    let kind: Kind
    var address: String?
    var groupName: String?

    func description(contacts: ContactNames = ContactNames()) -> String {
        let person = address.map(contacts.display) ?? "a participant"
        switch kind {
        case .participantAdded: return "Participant-added event: \(person)"
        case .participantRemoved: return "Participant-removed event: \(person)"
        case .phoneNumberChanged: return "Possible number-change / membership event: \(person)"
        case .groupRenamed: return "Group-name-change event: \(groupName ?? "Unknown name")"
        case .participantLeft: return "A participant left the group"
        case .iconChanged: return "Group picture changed"
        case .iconRemoved: return "Group picture removed"
        case .locationStarted: return "Location-sharing-started event"
        case .locationStopped: return "Location-sharing-stopped event"
        }
    }
    static func decode(item: Int64, action: Int64, handle: Int64, otherHandle: Int64,
                       otherAddress: String?, groupName: String?, shareStatus: Int64) -> MessageEvent? {
        switch (item, action) {
        case (1, 0) where otherHandle > 0:
            return MessageEvent(kind: handle == otherHandle ? .phoneNumberChanged : .participantAdded, address: otherAddress)
        case (1, 1) where otherHandle > 0: return MessageEvent(kind: .participantRemoved, address: otherAddress)
        case (2, _) where groupName?.isEmpty == false: return MessageEvent(kind: .groupRenamed, groupName: groupName)
        case (3, 0): return MessageEvent(kind: .participantLeft)
        case (3, 1): return MessageEvent(kind: .iconChanged)
        case (3, 2): return MessageEvent(kind: .iconRemoved)
        case (4, 0): return MessageEvent(kind: shareStatus == 0 ? .locationStarted : .locationStopped)
        default: return nil
        }
    }
}
