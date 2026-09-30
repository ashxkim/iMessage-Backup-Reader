#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
release_arch="${ARCH:-$(uname -m)}"
case "$release_arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $release_arch" >&2; exit 1 ;; esac
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)
mkdir -p build/releases
release_stage=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$release_stage"' EXIT
release_app="$release_stage/Messages Reader.app"
ARCH="$release_arch" APP_OUTPUT="$release_app" ./scripts/build.sh
codesign --verify --strict "$release_app"
release_name="iMessage-Backup-Reader-${release_version}-macOS-${release_arch}.zip"
ditto -c -k --keepParent --norsrc "$release_app" "$PWD/build/releases/$release_name"
cd build/releases
LC_ALL=C shasum -a 256 "$release_name" > "$release_name.sha256"
echo "Packaged: $PWD/$release_name"
