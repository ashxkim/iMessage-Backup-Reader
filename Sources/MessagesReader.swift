import SwiftUI
import AppKit
import QuickLookUI

struct AttachmentPreview: Identifiable {
    let attachment: Attachment
    let url: URL
    var id: URL { url }
}

// All access is confined to ReaderModel.worker, including destruction.
private final class StoreSlot: @unchecked Sendable {
    var store: MessageStore?
}

@MainActor
final class ReaderModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedID: Int64?
    @Published var summary: BackupSummary?
    @Published var sourcePath = ""
    @Published var page: MessagePage?
    @Published var busy = false
    @Published var activity = ""
    @Published var error: String?
    @Published var report: AttachmentReport?
    @Published var showSummary = false
    @Published var conversationFilter = ""
    @Published var search = ""
    @Published var appliedSearch = ""
    @Published var preview: AttachmentPreview?
    @Published var contacts = ContactNames()
    @Published var contactsLoading = false
    @Published var contactsLoaded = false
    @Published var category = ConversationCategory.people
    @Published var unlinkedCounts: [UnlinkedScope: Int] = [:]
    @Published var expandedEvents: Set<UnlinkedScope> = []
    @Published var eventPages: [UnlinkedScope: MessagePage] = [:]
    @Published var loadingEvents: Set<UnlinkedScope> = []
    @Published private var categoryOverrides = UserDefaults.standard.dictionary(forKey: "conversationCategories") as? [String: String] ?? [:]
    private let worker = DispatchQueue(label: "MessagesReader.database", qos: .userInitiated)
    // This property is accessed only on worker, as are all MessageStore methods.
    private let slot = StoreSlot()
    private var generation = 0
    private var eventGeneration = 0
    private var eventRequests: [UnlinkedScope: Int] = [:]

    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    var unlinkedConversation: Conversation? { conversations.first { $0.id == -1 } }
    var businessCount: Int { conversations.filter { $0.id != -1 && isBusiness($0) }.count }
    func title(_ chat: Conversation) -> String { contacts.title(for: chat) }
    private func preferenceKey(_ chat: Conversation) -> String {
        chat.guid.isEmpty ? sourcePath + "#" + String(chat.id) : "guid:" + chat.guid
    }
    func isBusiness(_ chat: Conversation) -> Bool {
        if let override = categoryOverrides[preferenceKey(chat)] { return override == ConversationCategory.businesses.rawValue }
        return BusinessClassifier.reason(for: chat, contacts: contacts) != nil
    }
    func groupingReason(_ chat: Conversation) -> String? {
        if let override = categoryOverrides[preferenceKey(chat)] { return "Manually placed in \(override)" }
        return BusinessClassifier.reason(for: chat, contacts: contacts)
    }
    func categorize(_ chat: Conversation, as destination: ConversationCategory?) {
        categoryOverrides[preferenceKey(chat)] = destination?.rawValue
        UserDefaults.standard.set(categoryOverrides, forKey: "conversationCategories")
        if category != .all, let destination { category = destination }
    }
    var filteredConversations: [Conversation] {
        conversations.filter { chat in
            guard chat.id != -1 else { return false }
            let matchesCategory = category == .all || (category == .businesses) == isBusiness(chat)
            let matchesSearch = conversationFilter.isEmpty || title(chat).localizedCaseInsensitiveContains(conversationFilter)
                || chat.title.localizedCaseInsensitiveContains(conversationFilter)
                || chat.addresses.joined(separator: " ").localizedCaseInsensitiveContains(conversationFilter)
            return matchesCategory && matchesSearch
        }
    }
    func loadContacts(requestPermission: Bool = true) {
        guard !contactsLoading else { return }
        if !requestPermission && !ContactsLoader.allowed {
            contacts = ContactNames()
            contactsLoaded = false
            return
        }
        contactsLoading = true
        ContactsLoader.load(requestPermission: requestPermission) { result in
            DispatchQueue.main.async {
                self.contactsLoading = false
                switch result {
                case .success(let contacts):
                    self.contacts = contacts
                    self.contactsLoaded = true
                case .failure(let error):
                    self.contacts = ContactNames()
                    self.contactsLoaded = false
                    if requestPermission { self.error = error.localizedDescription }
                }
            }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open a Messages backup"
        panel.message = "Choose the Messages folder containing chat.db, or select chat.db directly."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open backup"
        panel.begin { response in
            if response == .OK, let url = panel.url { self.open(url) }
        }
    }
    func open(_ url: URL) {
        guard !busy else { return }
        busy = true
        activity = "Opening and checking database…"
        generation += 1
        worker.async {
            do {
                let next = try MessageStore(url: url)
                let summary = try next.summary()
                let conversations = try next.conversations()
                let unlinkedCounts = try next.unlinkedCounts()
                self.slot.store = next
                DispatchQueue.main.async {
                    self.summary = summary
                    self.sourcePath = next.source.path
                    self.conversations = conversations
                    self.unlinkedCounts = unlinkedCounts
                    self.resetEventSections()
                    self.selectedID = nil
                    self.page = nil
                    self.report = nil
                    self.preview = nil
                    self.conversationFilter = ""
                    self.search = ""
                    self.appliedSearch = ""
                    self.category = .people
                    self.busy = false
                    self.showSummary = true
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.error = error.localizedDescription }
            }
        }
    }
    func selectConversation() {
        search = ""
        appliedSearch = ""
        page = nil
        resetEventSections()
        load(page: 0)
    }
    func find() {
        appliedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        resetEventSections(collapse: false)
        load(page: 0)
        if selectedID == -1 { for scope in expandedEvents { loadEvents(scope, page: 0) } }
    }
    func load(page pageNumber: Int) {
        guard let id = selectedID else { return }
        generation += 1
        let request = generation
        let query = appliedSearch
        busy = true
        activity = query.isEmpty ? "Loading messages…" : "Searching this conversation…"
        worker.async {
            do {
                guard let store = self.slot.store else { return }
                let result = try store.messages(chat: id, page: pageNumber, search: query, unlinkedScope: .remaining)
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.page = result
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.busy = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
    private func resetEventSections(collapse: Bool = true) {
        eventGeneration += 1
        eventRequests = [:]
        if collapse { expandedEvents = [] }
        eventPages = [:]
        loadingEvents = []
    }
    func toggleEvents(_ scope: UnlinkedScope) {
        if expandedEvents.contains(scope) { expandedEvents.remove(scope) }
        else {
            expandedEvents.insert(scope)
            if eventPages[scope] == nil && !loadingEvents.contains(scope) { loadEvents(scope, page: 0) }
        }
    }
    func loadEvents(_ scope: UnlinkedScope, page: Int) {
        guard selectedID == -1 else { return }
        eventRequests[scope, default: 0] += 1
        let request = eventRequests[scope]!
        let session = eventGeneration
        let query = appliedSearch
        loadingEvents.insert(scope)
        worker.async {
            do {
                guard let store = self.slot.store else { return }
                let result = try store.messages(chat: -1, page: page, search: query, unlinkedScope: scope)
                DispatchQueue.main.async {
                    guard session == self.eventGeneration && request == self.eventRequests[scope] && self.selectedID == -1 else { return }
                    self.eventPages[scope] = result
                    self.loadingEvents.remove(scope)
                }
            } catch {
                DispatchQueue.main.async {
                    guard session == self.eventGeneration && request == self.eventRequests[scope] else { return }
                    self.loadingEvents.remove(scope)
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func scan() {
        guard !busy else { return }
        busy = true
        activity = "Checking attachment files in the selected folder…"
        worker.async {
            do {
                guard let store = self.slot.store else { return }
                let report = try store.scanAttachments()
                DispatchQueue.main.async { self.report = report; self.busy = false }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.busy = false }
            }
        }
    }
    func openAttachment(_ attachment: Attachment, inFinder: Bool = false) {
        let request = generation
        worker.async {
            do {
                guard let store = self.slot.store else { return }
                let url = try store.readableAttachmentURL(attachment)
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    if inFinder {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        self.preview = AttachmentPreview(attachment: attachment, url: url)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func close() {
        generation += 1
        conversations = []
        selectedID = nil
        page = nil
        summary = nil
        report = nil
        unlinkedCounts = [:]
        resetEventSections()
        preview = nil
        sourcePath = ""
        showSummary = false
        busy = false
        worker.async { self.slot.store = nil }
    }
    func shutdown() { worker.sync { slot.store = nil } }
}

@main
struct MessagesReaderApp: App {
    @StateObject private var model = ReaderModel()
    var body: some Scene {
        WindowGroup("Messages Reader") {
            ReaderView(model: model)
                .frame(minWidth: 860, minHeight: 580)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.loadContacts(requestPermission: false)
                    // Explicit command-line input is useful for fixtures and repeatable checks.
                    let args = CommandLine.arguments
                    if model.summary == nil, let index = args.firstIndex(of: "--open"), index + 1 < args.count {
                        model.open(URL(fileURLWithPath: args[index + 1]))
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Messages Folder…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.busy)
                Button("Open This Mac’s Messages") {
                    model.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages"))
                }.disabled(model.busy)
                Divider()
                Button("Close Backup") { model.close() }.disabled(model.summary == nil || model.busy)
                Divider()
                Button("Use Contact Names…") { model.loadContacts() }.disabled(model.contactsLoading)
            }
        }
    }
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages Reader").font(.headline)
                    Text(model.sourcePath.isEmpty ? "A local window into your Messages backup" : model.sourcePath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(model.sourcePath)
                }
                Spacer()
                if model.summary != nil {
                    Label("Read only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    Button("Backup details") { model.showSummary = true }
                }
                Button("Open folder…") { model.chooseFolder() }.disabled(model.busy)
            }.padding(16)
            Divider()
            if model.summary == nil { welcome }
            else {
                HSplitView {
                    sidebar.frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                    conversation.frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if model.busy {
                Divider()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.activity).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSummary) { SummaryView(model: model) }
        .sheet(item: $model.preview) { preview in
            AttachmentPreviewSheet(preview: preview) {
                model.openAttachment(preview.attachment, inFinder: true)
            }
        }
        .alert("Messages Reader", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.selectedID) { _ in model.selectConversation() }

    }
    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 52, weight: .light)).foregroundStyle(.blue)
            Text("Read your Messages backup").font(.largeTitle.weight(.semibold))
            Text("Choose the Messages folder on your SD card,\nor any folder containing chat.db.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Messages folder…") { model.chooseFolder() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            Button("Open this Mac’s Messages") {
                model.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages"))
            }.buttonStyle(.link).disabled(model.busy)
            Text("Text, dates, and attachment placeholders. Everything stays on this Mac.\nYour original files are never changed.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 10)
            Spacer()
            Text("For this Mac’s Library folder, macOS may require Full Disk Access for Messages Reader.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Find a name, number, or conversation", text: $model.conversationFilter)
                .textFieldStyle(.roundedBorder).padding(12)
            HStack {
                Button(model.contactsLoaded ? "Refresh names" : "Use contact names") { model.loadContacts() }
                    .controlSize(.small).disabled(model.contactsLoading)
                    .help("Match this Mac’s Contacts to phone numbers and email addresses. Names stay on this Mac.")
                if model.contactsLoading { ProgressView().controlSize(.small) }
                else if model.contactsLoaded { Text("\(model.contacts.count.formatted()) contacts").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Picker("Conversation category", selection: $model.category) {
                ForEach(ConversationCategory.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 10)
            HStack {
                Text("\(model.filteredConversations.count.formatted()) conversations").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 14).padding(.bottom, 6)
            if model.category == .businesses {
                Text("Guessed from sender format. Right-click any chat to move it.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 6)
            } else if model.category == .people && model.businessCount > 0 {
                Text("\(model.businessCount.formatted()) chats in Businesses")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            List(selection: $model.selectedID) {
                ForEach(model.filteredConversations) { chat in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.title(chat)).fontWeight(.medium).lineLimit(2)
                        HStack {
                            Text("\(chat.count.formatted()) records")
                            Spacer()
                            if let date = chat.latest { Text(date, style: .date) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).tag(chat.id)
                    .help(([chat.addresses.joined(separator: ", "), model.groupingReason(chat)].compactMap { $0 }).joined(separator: "\n"))
                    .contextMenu {
                        Button("Move to People") { model.categorize(chat, as: .people) }
                        Button("Move to Businesses") { model.categorize(chat, as: .businesses) }
                        Divider()
                        Button("Use automatic grouping") { model.categorize(chat, as: nil) }
                    }
                }
            }.listStyle(.sidebar)
            if let unlinked = model.unlinkedConversation {
                Divider()
                Button { model.selectedID = unlinked.id } label: {
                    HStack {
                        Image(systemName: "link.badge.plus")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Without a chat ID")
                            Text("\(unlinked.count.formatted()) records").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(10).contentShape(Rectangle())
                        .background(model.selectedID == unlinked.id ? Color.blue.opacity(0.15) : Color.clear).cornerRadius(8)
                }.buttonStyle(.plain).padding(6)
            }
        }
    }
    @ViewBuilder private var conversation: some View {
        if let chat = model.selected {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title(chat)).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if !chat.participants.isEmpty && chat.participants != chat.title {
                        Text(chat.participants).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if chat.id == -1 {
                        Text("Unplaced messages stay here when the saved records do not identify one two-person conversation. Events are grouped below and start collapsed.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if chat.inferredCount > 0 {
                        Text("\(chat.inferredCount.formatted()) messages have inferred placement. Each is marked below and may not belong to this conversation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Search text in this conversation", text: $model.search)
                            .textFieldStyle(.roundedBorder).onSubmit { model.find() }
                        Button("Search") { model.find() }.disabled(model.busy)
                        if !model.appliedSearch.isEmpty {
                            Button("Clear") { model.search = ""; model.find() }.disabled(model.busy)
                        }
                    }
                }.padding(16)
                Divider()
                if let page = model.page, chat.id == -1 {
                    unplacedTimeline(page)
                } else if let page = model.page {
                    pagination(page)
                    Divider()
                    if page.messages.isEmpty {
                        VStack(spacing: 8) {
                            Text(model.appliedSearch.isEmpty ? "No records in this view" : "No matching text").font(.headline)
                            Text("Search covers all readable text in this conversation.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 16) {
                                    ForEach(page.messages) { message in
                                        MessageRow(message: message, contacts: model.contacts, openAttachment: { model.openAttachment($0) },
                                                   showInFinder: { model.openAttachment($0, inFinder: true) }).id(message.id)
                                    }
                                }.padding(20)
                            }
                            .onAppear { scrollToBottom(proxy, page) }
                            .onChange(of: page.messages.last?.id) { _ in scrollToBottom(proxy, page) }
                        }
                    }
                } else { Spacer(); Text("Loading conversation…").foregroundStyle(.secondary); Spacer() }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.bubble").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                Text("Choose a conversation").font(.title2)
                Text("Messages appear here with sender and date.\nClick an attachment to preview it, or right-click to show it in Finder.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func unplacedTimeline(_ page: MessagePage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(UnlinkedScope.eventSections.filter { model.unlinkedCounts[$0, default: 0] > 0 }) { scope in
                    eventSection(scope)
                    Divider()
                }
                HStack {
                    Text("Unplaced messages").font(.headline)
                    Spacer()
                    Text("\(model.unlinkedCounts[.remaining, default: 0].formatted()) records").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
                pagination(page)
                if page.messages.isEmpty {
                    Text(model.appliedSearch.isEmpty ? "No unplaced ordinary messages." : "No ordinary messages match. Expand the event sections to inspect their search results.")
                        .foregroundStyle(.secondary).padding(20)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(page.messages) { message in
                            MessageRow(message: message, contacts: model.contacts,
                                       openAttachment: { model.openAttachment($0) },
                                       showInFinder: { model.openAttachment($0, inFinder: true) })
                        }
                    }.padding(20)
                }
            }
        }
    }
    private func eventSection(_ scope: UnlinkedScope) -> some View {
        let expanded = model.expandedEvents.contains(scope)
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.toggleEvents(scope) } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("\(scope.rawValue) (\(model.unlinkedCounts[scope, default: 0].formatted()))").fontWeight(.medium)
                    Spacer()
                    Text(expanded ? "Collapse" : "Expand").foregroundStyle(.secondary)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                if scope == .numberChangeCandidates {
                    Text("These records reference the same participant twice. They could represent a phone change or group-membership bookkeeping; the metadata does not confirm which.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
                }
                if model.loadingEvents.contains(scope) {
                    HStack { ProgressView().controlSize(.small); Text("Loading events…").font(.caption) }.padding(12)
                } else if let page = model.eventPages[scope] {
                    HStack(spacing: 10) {
                        Button("← Older events") { model.loadEvents(scope, page: page.page + 1) }
                            .disabled((page.page + 1) * MessagePage.size >= page.total)
                        Text("\(page.messages.count) shown · \(page.total.formatted())\(model.appliedSearch.isEmpty ? " events" : " matches")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Newer events →") { model.loadEvents(scope, page: page.page - 1) }.disabled(page.page == 0)
                    }.padding(.horizontal, 12).padding(.bottom, 8)
                    if page.messages.isEmpty {
                        Text("No events in this section match the search.").font(.caption).foregroundStyle(.secondary).padding(12)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(page.messages) { message in
                                    MessageRow(message: message, contacts: model.contacts,
                                               openAttachment: { model.openAttachment($0) },
                                               showInFinder: { model.openAttachment($0, inFinder: true) })
                                }
                            }.padding(12)
                        }.frame(height: 220).id(page.page)
                    }
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    private func scrollToBottom(_ proxy: ScrollViewProxy, _ page: MessagePage) {
        if let id = page.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
    }
    private func pagination(_ page: MessagePage) -> some View {
        let maxPage = max(0, (page.total - 1) / MessagePage.size)
        let upper = max(0, page.total - page.page * MessagePage.size)
        let lower = page.total == 0 ? 0 : max(1, upper - page.messages.count + 1)
        return HStack(spacing: 10) {
            Button("Oldest") { model.load(page: maxPage) }.disabled(model.busy || page.page >= maxPage)
            Button("← Older") { model.load(page: page.page + 1) }.disabled(model.busy || page.page >= maxPage)
            Spacer()
            Text("\(lower.formatted())–\(upper.formatted()) of \(page.total.formatted())\(model.appliedSearch.isEmpty ? "" : " matches")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Newer →") { model.load(page: page.page - 1) }.disabled(model.busy || page.page == 0)
            Button("Latest") { model.load(page: 0) }.disabled(model.busy || page.page == 0)
        }.padding(10)
    }
}

struct MessageRow: View {
    let message: Message
    let contacts: ContactNames
    let openAttachment: (Attachment) -> Void
    let showInFinder: (Attachment) -> Void
    var body: some View {
        HStack(alignment: .top) {
            if message.fromMe { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.fromMe ? "You" : contacts.display(message.sender)).fontWeight(.semibold).help(message.sender)
                    if let date = message.date { Text(date.formatted(date: .abbreviated, time: .standard)) }
                    else { Text("Unknown date") }
                }.font(.caption).foregroundStyle(.secondary)
                Text(!message.hasReadableText ? message.event?.description(contacts: contacts) ?? message.body : message.body)
                    .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(message.attachments) { item in
                    Button { openAttachment(item) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.mime.hasPrefix("image/") ? "photo" : item.mime.hasPrefix("video/") ? "video" : "doc")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).fontWeight(.medium).multilineTextAlignment(.leading)
                                Text("\(item.mime)\(item.bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file) : "") · Click to preview")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "eye").foregroundStyle(.secondary)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45)).cornerRadius(7).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Preview \(item.name) from this backup. Right-click for Show in Finder.")
                    .accessibilityLabel("Preview attachment: \(item.name)")
                    .contextMenu {
                        Button("Preview") { openAttachment(item) }
                        Button("Show in Finder") { showInFinder(item) }
                    }
                }
                if let reason = message.placementReason {
                    Label("Inferred placement — no chat ID. This message may not belong to this conversation.", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .help(reason)
                }
                if let note = message.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(12)
            .frame(maxWidth: 640, alignment: .leading)
            .background(message.fromMe ? Color.blue.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            if !message.fromMe { Spacer(minLength: 60) }
        }.frame(maxWidth: .infinity)
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct AttachmentPreviewSheet: View {
    let preview: AttachmentPreview
    let showInFinder: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(preview.attachment.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder", action: showInFinder)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            QuickLookPreview(url: preview.url)
            Divider()
            Text(preview.url.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 780, height: 580)
    }
}

struct SummaryView: View {
    @ObservedObject var model: ReaderModel
    private func dateText(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "No dated messages" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Backup details").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { model.showSummary = false }.keyboardShortcut(.defaultAction)
            }
            Text(model.sourcePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let summary = model.summary {
                HStack(spacing: 24) {
                    metric(summary.messages, "Message records")
                    metric(summary.conversations, "Conversations")
                    metric(summary.attachments, "Attachment records")
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow { Text("Oldest message").foregroundStyle(.secondary); Text(dateText(summary.oldest)) }
                    GridRow { Text("Newest message").foregroundStyle(.secondary); Text(dateText(summary.newest)) }
                    GridRow { Text("Database check").foregroundStyle(.secondary); Text("Passed structural check").foregroundStyle(.green) }
                    GridRow { Text("Companion WAL file").foregroundStyle(.secondary); Text(summary.includesWAL ? "Included in this read" : "Not present in selected folder") }
                }.font(.callout)
                if summary.unassigned > 0 {
                    Text("\(summary.unassigned.formatted()) records have no saved conversation link. \(model.conversations.reduce(0) { $0 + $1.inferredCount }.formatted()) have inferred placements. The remaining \(model.unlinkedCounts[.all, default: 0].formatted()) records are under “Without a chat ID.”").font(.callout)
                }
                Divider()
                HStack {
                    Text("Attachment check").font(.headline)
                    Spacer()
                    Button(model.report == nil ? "Check attachment files" : "Check again") { model.scan() }.disabled(model.busy || !summary.attachmentMetadataAvailable)
                }
                Text("Checks paths and recorded file sizes inside this backup. Does not download or open attachments.")
                    .font(.caption).foregroundStyle(.secondary)
                if let report = model.report {
                    Text("\(report.present.formatted()) present · \(report.missing.formatted()) missing · \(report.differentSize.formatted()) size differences · \(report.unknown.formatted()) could not check")
                        .font(.callout.weight(.medium)).textSelection(.enabled)
                    if !report.examples.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(report.examples.enumerated()), id: \.offset) { _, item in Text(item).font(.caption).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                        Text("Showing up to 20 issues.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.busy { HStack { ProgressView().controlSize(.small); Text(model.activity).font(.caption) } }
                if !summary.attachmentMetadataAvailable { Text("Attachment paths are unavailable in this database.").font(.caption) }
                Divider()
                Text("These checks help spot gaps, but cannot prove the backup contains every message. Counts include reactions and system events. Files kept only in iCloud may be missing locally. Compare dates and counts with the source Mac before deleting anything.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 650)
    }
    private func metric(_ count: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.formatted()).font(.title.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
