# Back up your Messages

[Home](../README.md) · [Backup guide](backup-guide.md) · [Using the app](user-guide.md) · [Contributing](../CONTRIBUTING.md)

This app reads a **Mac's local Messages folder**. It does not create a backup itself, download your iCloud history, or read an encrypted iPhone/Finder backup.

## Copy the folder to an SD card or external drive

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

## If macOS blocks access

For reading the live folder in this app, allow **Messages Reader** in **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it. If you use Terminal to copy the protected folder, macOS may require Full Disk Access for your terminal app instead. A copied folder on an external drive may only require access to that drive. Resolve permissions or disk-space errors before treating a copy as complete.

## Check your copy

**Backup details** gives original message/conversation/attachment record counts, oldest/newest message dates, and a SQLite structural check. It distinguishes the original count without saved chat links from inferred placements and the remaining unplaced records; displayed conversation counts include inferred messages. **Check attachment files** checks each recorded attachment path inside the selected backup, and compares file size when a positive size is recorded. It reports missing files, size differences, and entries it cannot check, with up to 20 examples. It does not hash contents or enumerate unreferenced files.

Open the copied folder, review **Backup details**, and run **Check attachment files**. Inspect older and newer conversations and preview a few important attachments. Compare the source and backup's counts and date ranges while the source is unchanged. The structural check and matching counts are useful evidence, but **do not prove that every message or attachment was backed up**. The app cannot recover files that were not downloaded or already missing on the source Mac.

A Messages folder contains private conversations and files. Keep it separate from this repository and do not attach it to public GitHub issues. [Time Machine](https://support.apple.com/104984) is an additional Mac backup option; verify that the data you need is actually present in any backup you rely on.
