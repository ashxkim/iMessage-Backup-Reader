# Using iMessage Backup Reader

[Home](../README.md) · [Backup guide](backup-guide.md) · [Using the app](user-guide.md) · [Contributing](../CONTRIBUTING.md)

## Open and browse

1. Open **Messages Reader.app**.
2. Click **Choose Messages folder…** and select the backed-up `Messages` folder, or its `chat.db` file.
3. Review **Backup details**, then choose a conversation. **Older / Newer** pages through 200 records at a time. **Oldest / Latest** jumps to either end.
4. Use **Search** to search all readable text in the selected conversation, including older pages and encoded message bodies. The sidebar filter searches conversation names and phone numbers/email addresses.
5. Click an attachment card to open a **Quick Look preview**. Click **Show in Finder** in the preview, or right-click the card and choose **Show in Finder**, to select the actual backed-up file on your drive. Missing files produce a clear explanation instead of opening a different copy elsewhere on your Mac.
6. Click **Use contact names** and allow the macOS Contacts prompt to display names from this Mac's Contacts. This updates conversation titles, message senders, and participants mentioned in event records. **Refresh names** reloads Contacts. Matching names are kept in memory; the backup is not edited. Numbers/emails remain visible in conversation details or sender tooltips. Unknown or ambiguous matches stay as numbers/emails.
7. The sidebar starts on **People**. **Businesses** contains suspected short-code or alphanumeric senders; **All** shows both. Search applies to the chosen tab and matches names as well as raw numbers/emails. Right-click a conversation to **Move to People**, **Move to Businesses**, or **Use automatic grouping**. These choices are saved locally for future opens. **Without a chat ID** remains accessible separately at the bottom.
8. Inside **Without a chat ID**, participant additions, possible phone changes/membership events, location events, reactions, and other events each have their own expandable section. All start collapsed and page independently. The main timeline contains only unplaced ordinary messages. Search applies to the ordinary timeline and to each event section when expanded. All original records are retained.
9. Ordinary records missing a chat link can appear in an existing **two-person conversation**, in timestamp order, with an orange **Inferred placement** note. This requires either one unambiguous direct-chat reference (a saved reply/thread or recoverable-message link), or a sender who occurs in only one saved conversation and that conversation is a direct chat. A two-person chat means you and one other participant. Known group metadata, competing conversations, conflicting references, and missing timestamps keep a message under **Without a chat ID**. Sender matches use the backup's addresses, not current Contacts names. Hover over the note to see the placement reason.

The interface is intentionally simple: readable text and attachment cards, with supported files available in Quick Look.

For this Mac's live Messages folder, click **Open this Mac’s Messages**. macOS may require **System Settings → Privacy & Security → Full Disk Access → Messages Reader**. Quit and reopen the app after allowing access. An SD-card backup usually just needs access to the chosen folder or removable volume.

## Formats and interpretation

- Conversation titles and contact names, with phone numbers/email addresses as a fallback. Contact names come from this Mac's current Contacts, not from the historic backup. Phone punctuation and common US/Canada country-code differences are normalized; arbitrary international suffix matches are not guessed.
- Incoming/outgoing text, emoji, line breaks, timestamps, and clickable attachment cards showing name/type/size. Quick Look previews supported images, videos, PDFs, and other documents without launching the attachment as a program.
- Plain-text extraction from common `attributedBody` typedstreams used by newer Messages databases. Unsupported bodies are explicitly marked; no message records are silently dropped.
- Reactions and conversation events as separate records/placeholders. Rich cards, stickers, audio, photos, videos, edit history, and threaded replies are not rendered inline like the official Messages app; supported attached files can be previewed separately.
- Unassigned records under **Without a chat ID** so they remain inspectable. Messages store the sender (`handle_id`) separately from conversation membership (`chat_message_join`), so a clear sender can remain even when no saved chat link exists. Knowing the sender alone cannot identify the original direct/group conversation. This section also includes event records; its count is not a count of missing text messages. Ordinary records with a single direct-chat reply or recoverable-message reference may be displayed in that chat, still clearly marked as inferred. They are not restored into Apple Messages.

The business grouping is a conservative guess, not a verified business directory. Unsaved 3–6-digit short codes, unusually short/long numbers, and alphanumeric sender IDs are separated. A missing `+` alone does not flag a sender; plausible 7–15-digit numbers, email addresses, saved contacts, and groups remain in People unless you move them. Businesses using normal phone numbers may remain in People. Nothing is deleted or excluded from All.

Historical event rows show readable labels for participant additions/removals, possible number changes, group name/picture changes, and location-sharing starts/stops when their metadata is recognized. Self-referencing participant rows are labeled **Possible number-change / membership event**: matching sender/other-participant IDs alone does not confirm a number changed, and these can appear in bursts alongside participant-added records. These are interpretations of Apple's private format, not proof that a contact recently performed an action. Inferred placement is a viewing aid, not a recovered original chat ID; an unknown or deleted group may still have been the original destination. Interpretation reference: [iMessage event field mapping](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/tables/messages/models/group_action.rs).

The reader opens Mac `chat.db` databases, not encrypted iPhone/Finder backups. Apple's database format is private and can change; this is a first-version reader, not a forensic recovery tool.

## Read-only behavior and privacy

The app reads the selected `chat.db` and its existing WAL/rollback journal into a private temporary directory. SQLite opens only that working copy, with queries restricted to reads. The source database, attachments, and sidecar files are not changed; the reader never creates a source WAL/SHM or checkpoints the original database. Attachment checks resolve paths only within the chosen folder and reject paths/symlinks that escape it. They never fall back to files still on the original Mac.

There is no networking, analytics, or upload code. The temporary database is removed when you close the backup, switch folders, or quit normally. A forced quit or crash can leave a `MessagesReader-*` directory under macOS's per-user temporary folder. The temporary database needs free local disk space roughly equal to the source database and WAL; attachment contents are not copied. No folder is reopened automatically, except when explicitly passed using `--open`.
