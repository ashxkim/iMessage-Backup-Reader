#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/ReaderCore.swift Sources/ConversationPresentation.swift Tests/ReaderTests.swift -o build/ReaderTests
build/ReaderTests "$@"
