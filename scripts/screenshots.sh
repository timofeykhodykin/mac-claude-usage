#!/bin/bash
# Regenerates the README screenshots in docs/ by rendering the real SwiftUI views offscreen
# with sample data (no polling, no Keychain access, no settings changes).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=".build/screenshots/Shots.app/Contents"
mkdir -p "$WORK/MacOS" "$WORK/Resources" docs
cp Resources/*.png "$WORK/Resources/"
cat > "$WORK/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>dev.mac-claude-usage.screenshots</string>
    <key>CFBundleExecutable</key><string>shots</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

SOURCES=$(find Sources/MacClaudeUsage -name "*.swift" ! -name Main.swift)
# shellcheck disable=SC2086
swiftc -swift-version 5 -O -o "$WORK/MacOS/shots" scripts/screenshots/main.swift $SOURCES
"$WORK/MacOS/shots" "$PWD/docs"
echo "Screenshots written to docs/"
