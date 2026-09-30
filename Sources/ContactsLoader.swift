import Contacts
import Foundation

enum ContactsLoader {
    static var allowed: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized
    }
    static func load(requestPermission: Bool, completion: @escaping (Result<ContactNames, Error>) -> Void) {
        let store = CNContactStore()
        func fetch() {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let keys: [CNKeyDescriptor] = [
                        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                        CNContactPhoneNumbersKey as CNKeyDescriptor,
                        CNContactEmailAddressesKey as CNKeyDescriptor,
                        CNContactOrganizationNameKey as CNKeyDescriptor
                    ]
                    let request = CNContactFetchRequest(keysToFetch: keys)
                    request.unifyResults = true
                    var entries: [NamedContact] = []
                    try store.enumerateContacts(with: request) { contact, _ in
                        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
                        let addresses = contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }
                        if !name.isEmpty && !addresses.isEmpty {
                            entries.append(NamedContact(id: contact.identifier, name: name, addresses: addresses))
                        }
                    }
                    completion(.success(ContactNames(entries)))
                } catch { completion(.failure(error)) }
            }
        }
        if allowed { fetch() }
        else if requestPermission && CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            store.requestAccess(for: .contacts) { granted, error in
                if granted { fetch() }
                else { completion(.failure(error ?? ReaderError("Contacts access wasn’t allowed. You can enable Messages Reader in System Settings → Privacy & Security → Contacts. Numbers and email addresses will still work without access."))) }
            }
        } else {
            completion(.failure(ReaderError("Allow Messages Reader in System Settings → Privacy & Security → Contacts, then click Refresh names. Your contacts are only used on this Mac to match phone numbers and email addresses.")))
        }
    }
}
