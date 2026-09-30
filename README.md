# iMessage Backup Reader

A small, offline Mac app for reading a `~/Library/Messages` folder copied to an SD card or another drive. Uses Apple's built-in SwiftUI and SQLite; no server, account, dependencies, or runtime installation needed for the built app.

## Download and run — no Xcode needed

Download the app ZIP from [GitHub Releases](https://github.com/ashxkim/iMessage-Backup-Reader/releases/latest), unzip it, and move **Messages Reader.app** to Applications or another folder you prefer. Open the app and choose your backed-up Messages folder.

- Requires **macOS 13 or later**.
- Choose **arm64** for Apple Silicon (M-series) Macs; **x86_64** for Intel Macs when that release asset is available.
- The prebuilt app uses libraries included with macOS. **You do not need Xcode, Homebrew, Python, or Terminal to run it.** GitHub's automatic “Source code” downloads are for building the app yourself.
- Current builds are ad-hoc signed, **not Apple-notarized**. macOS may block the initial launch. If you trust this project, follow [Apple's instructions for opening an unnotarized app](https://support.apple.com/en-us/102445), using **System Settings → Privacy & Security → Open Anyway** when offered. Do not disable Gatekeeper globally.

## Back up `~/Library/Messages`

This app reads a **Mac's local Messages folder**. It does not create a backup itself, download your iCloud history, or read an encrypted iPhone/Finder backup.

### Copy the folder to an SD card or external drive

1. On the source Mac, open **Messages** and check that the conversations you want are present. If you use Messages in iCloud, let syncing finish first; **Messages → Settings → iMessage → Sync Now** can request a sync when available. Open important attachments to check that they are downloaded. A folder copy includes only files stored locally, so iCloud-only attachments may be absent. See [Apple's Messages in iCloud guide](https://support.apple.com/guide/icloud/mm0de0d4528d/icloud).
2. Quit Messages with **Command-Q**. Avoid sending messages or changing the library while copying. Quitting the app reduces activity, but background services may still change the database: a live Finder copy is not a guaranteed consistent snapshot. For an archival copy, use an offline source or a consistent filesystem snapshot that contains the whole folder.
3. Connect your SD card or external drive and create a **new, empty, dated backup folder**, for example `Messages backup 2026-09-30`. Make sure there is enough free space for the entire Messages folder, including attachments. Use a separate folder for each backup instead of merging copies made at different times.
4. In **Finder**, choose **Go → Go to Folder…** (**Shift-Command-G**), enter `~/Library`, and press Return. The `~` means your home folder; this is different from `/Library`.
5. Select the **Messages** folder, press **Command-C**, open your new backup folder on the external drive, and press **Command-V**. **Copy the entire folder**, including its subfolders and any `chat.db-wal`, `chat.db-shm`, or `chat.db-journal` files present. Leave the original in place.
6. Wait for Finder to finish and resolve any copy errors. In Messages Reader, choose the copied **Messages** folder, then follow the verification steps below. Keep the original and another independent backup while checking the copy.
7. Close the backup in the reader before ejecting the drive with Finder.

The copied folder should look approximately like this; keep other files and folders too:

```text
Messages backup 2026-09-30/
  Messages/
    chat.db
    chat.db-wal       # include if present
    chat.db-shm       # include if present
    chat.db-journal   # include if present
    Attachments/
      ...
```

**Why copy more than `chat.db`?** Recent committed messages can live in the companion WAL file, and attachment contents live separately. Missing companion files can leave out data or produce an inconsistent database. Their absence is normal when the source has no such files; do not create empty replacements or combine them with a different backup. See [SQLite's WAL documentation](https://www.sqlite.org/wal.html).

### If macOS blocks access

For reading the live folder in this app, allow **Messages Reader** in **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. If you use Terminal to copy the protected folder, macOS may require Full Disk Access for your terminal app instead. A copied folder on an external drive may only require access to that drive. Resolve permissions or disk-space errors before treating a copy as complete.

### Check your copy

Open the copied folder, review **Backup details**, and run **Check attachment files**. Inspect older and newer conversations and preview a few important attachments. Compare the source and backup's counts and date ranges while the source is unchanged. The structural check and matching counts are useful evidence, but **do not prove that every message or attachment was backed up**. The app cannot recover files that were not downloaded or already missing on the source Mac.

A Messages folder contains private conversations and files. Keep it separate from this repository and do not attach it to public GitHub issues. [Time Machine](https://support.apple.com/104984) is an additional Mac backup option; verify that the data you need is actually present in any backup you rely on.

## Browse your backup

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

## What it shows

- Conversation titles and contact names, with phone numbers/email addresses as a fallback. Contact names come from this Mac's current Contacts, not from the historic backup. Phone punctuation and common US/Canada country-code differences are normalized; arbitrary international suffix matches are not guessed.
- Incoming/outgoing text, emoji, line breaks, timestamps, and clickable attachment cards showing name/type/size. Quick Look previews supported images, videos, PDFs, and other documents without launching the attachment as a program.
- Plain-text extraction from common `attributedBody` typedstreams used by newer Messages databases. Unsupported bodies are explicitly marked; no message records are silently dropped.
- Reactions and conversation events as separate records/placeholders. Rich cards, stickers, audio, photos, videos, edit history, and threaded replies are not rendered inline like the official Messages app; supported attached files can be previewed separately.
- Unassigned records under **Without a chat ID** so they remain inspectable. Messages store the sender (`handle_id`) separately from conversation membership (`chat_message_join`), so a clear sender can remain even when no saved chat link exists. Knowing the sender alone cannot identify the original direct/group conversation. This section also includes event records; its count is not a count of missing text messages. Ordinary records with a single direct-chat reply or recoverable-message reference may be displayed in that chat, still clearly marked as inferred. They are not restored into Apple Messages.

The business grouping is a conservative guess, not a verified business directory. Unsaved 3–6-digit short codes, unusually short/long numbers, and alphanumeric sender IDs are separated. A missing `+` alone does not flag a sender; plausible 7–15-digit numbers, email addresses, saved contacts, and groups remain in People unless you move them. Businesses using normal phone numbers may remain in People. Nothing is deleted or excluded from All.

Historical event rows show readable labels for participant additions/removals, possible number changes, group name/picture changes, and location-sharing starts/stops when their metadata is recognized. Self-referencing participant rows are labeled **Possible number-change / membership event**: matching sender/other-participant IDs alone does not confirm a number changed, and these can appear in bursts alongside participant-added records. These are interpretations of Apple's private format, not proof that a contact recently performed an action. Inferred placement is a viewing aid, not a recovered original chat ID; an unknown or deleted group may still have been the original destination. Interpretation reference: [iMessage event field mapping](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/tables/messages/models/group_action.rs).

The reader opens Mac `chat.db` databases, not encrypted iPhone/Finder backups. Apple's database format is private and can change; this is a first-version reader, not a forensic recovery tool.

## Checking the SD-card backup

**Backup details** gives original message/conversation/attachment record counts, oldest/newest message dates, and a SQLite structural check. It distinguishes the original count without saved chat links from inferred placements and the remaining unplaced records; displayed conversation counts include inferred messages. **Check attachment files** checks each recorded attachment path inside the selected backup, and compares file size when a positive size is recorded. It reports missing files, size differences, and entries it cannot check, with up to 20 examples. It does not hash contents or enumerate unreferenced files.

Open the original folder and the backup in turn to compare their counts and date ranges, then inspect important conversations. Matching counts are useful evidence, not proof of identical contents. Counts include reactions/system records. Attachments that were only in iCloud or already missing on the original Mac will not magically exist in a local copy. This app does not download them.

## Read-only behavior and privacy

The app reads the selected `chat.db` and its existing WAL/rollback journal into a private temporary directory. SQLite opens only that working copy, with queries restricted to reads. The source database, attachments, and sidecar files are not changed; the reader never creates a source WAL/SHM or checkpoints the original database. Attachment checks resolve paths only within the chosen folder and reject paths/symlinks that escape it. They never fall back to files still on the original Mac.

There is no networking, analytics, or upload code. The temporary database is removed when you close the backup, switch folders, or quit normally. A forced quit or crash can leave a `MessagesReader-*` directory under macOS's per-user temporary folder. The temporary database needs free local disk space roughly equal to the source database and WAL; attachment contents are not copied. No folder is reopened automatically, except when explicitly passed using `--open`.

## Build and test

Only contributors building from source need Apple's [Xcode Command Line Tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools); the full Xcode application is not required. Install the tools with `xcode-select --install` if needed, then run from this repository:

```sh
./scripts/build.sh
open 'Messages Reader.app'
./scripts/test.sh
```

Or double-click **Build and Run.command**. Set `ARCH=x86_64` or `ARCH=arm64` when building for a different Mac processor. All source code is in `Sources/`. Tests use synthetic messages, not personal Messages data, and cover WAL-only records, source preservation, old/new date units, legacy schemas, encoded text, Unicode, pagination, search, attachment checks, disjoint event sections, conservative direct-chat inference, and ambiguous group/reference cases.

Implementation references: [SQLite WAL documentation](https://www.sqlite.org/wal.html), [typedstream wire format](https://github.com/dgelessus/python-typedstream/blob/master/src/typedstream/stream.py), and [iMessage database field reference](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/tables/messages/message.rs). The app contains its own small plain-text extractor; it does not embed these projects.


## Package a release

```sh
./scripts/test.sh
ARCH=arm64 ./scripts/package.sh
# Optional Intel build:
ARCH=x86_64 ./scripts/package.sh
```

The packaging script builds in a temporary staging folder and writes the app ZIP and SHA-256 checksum to `build/releases/`. It includes the MIT license inside the app bundle. It does not package any message databases, attachments, local preferences, test fixtures, or investigation reports. Upload the ZIP and checksum as **release assets**, rather than committing binaries to the source repository. The script creates an ad-hoc signed build; Developer ID signing and Apple notarization require a separate release process.

## Contributing

Bug reports and focused pull requests are welcome. Include your macOS version, app version, and a description of the issue. Use synthetic or redacted examples; never post your `chat.db`, real message text, phone numbers, or private attachments. Run `./scripts/test.sh` and `./scripts/build.sh` before proposing a code change.

## License

[MIT](LICENSE). This is an independent project, not affiliated with Apple. iMessage is a trademark of Apple Inc.
