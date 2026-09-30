# Build and contribute

[Home](README.md) · [Backup guide](docs/backup-guide.md) · [Using the app](docs/user-guide.md)

Bug reports and focused pull requests are welcome. Include your macOS version, app version, and a description of the issue. Use synthetic or redacted examples; never post your `chat.db`, real message text, phone numbers, or private attachments. Run `./scripts/test.sh` and `./scripts/build.sh` before proposing a code change.

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
