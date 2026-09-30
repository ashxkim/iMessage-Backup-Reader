#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch="${ARCH:-$(uname -m)}"
app_output="${APP_OUTPUT:-$PWD/Messages Reader.app}"
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
mkdir -p build/module-cache "$app_output/Contents/MacOS" "$app_output/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" \
  -module-cache-path "$PWD/build/module-cache" \
  Sources/ReaderCore.swift Sources/ConversationPresentation.swift Sources/ContactsLoader.swift Sources/MessagesReader.swift \
  -o "$app_output/Contents/MacOS/MessagesReader"
cp scripts/Info.plist "$app_output/Contents/Info.plist"
cp LICENSE "$app_output/Contents/Resources/LICENSE"
codesign --force --sign - "$app_output"
echo "Built: $app_output"
