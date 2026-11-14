#!/bin/zsh
# Builds Longhand into dist/Longhand.app so it can be double-clicked.
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

xcodegen generate >/dev/null

xcodebuild \
  -project Longhand.xcodeproj \
  -scheme Longhand \
  -configuration Release \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p dist
rm -rf dist/Longhand.app
cp -R .build/Build/Products/Release/Longhand.app dist/
codesign --force --sign - dist/Longhand.app

# A copy with its own identity for hidden test runs (--selftest, --perftest, screenshots).
# Run from the real app, a hidden copy swallowed the owner's own launches: macOS switched
# to the running hidden copy instead of opening a window (2026-11-13).
rm -rf "dist/Longhand Test.app"
cp -R dist/Longhand.app "dist/Longhand Test.app"
plist="dist/Longhand Test.app/Contents/Info.plist"
id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id.test" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Longhand Test" "$plist"
codesign --force --sign - "dist/Longhand Test.app"

echo
echo "Built dist/Longhand.app (and dist/Longhand Test.app for test runs)"
