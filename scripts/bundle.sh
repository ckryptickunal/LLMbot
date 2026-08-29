#!/bin/zsh
# Build BotHarness and assemble a runnable .app bundle.
#
# Swift Package Manager emits a bare executable; macOS needs a bundle with an Info.plist
# for window management, TCC permission prompts, and a Dock identity. We assemble it by
# hand because that works with Command Line Tools alone — no Xcode, no asset catalogs,
# no project file. See docs/guides/ENVIRONMENT.md.
#
#   scripts/bundle.sh            release build (default)
#   scripts/bundle.sh debug      debug build, faster to iterate on

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
NAME="BotHarness"
BUNDLE_ID="app.botharness.mac"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)"

print -P "%F{cyan}building $NAME ($CONFIG) — $VERSION%f"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/$NAME"
[[ -x "$BIN" ]] || { print -u2 "build produced no executable at $BIN"; exit 1; }

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

# Usage-description strings are mandatory: macOS kills the process rather than showing a
# permission prompt if the matching NS*UsageDescription key is absent. The wording here is
# what the user actually reads in the system dialog, so it explains the real reason.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Bot-Harness</string>
    <key>CFBundleDisplayName</key><string>Bot-Harness</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRequiresAquaSystemAppearance</key><false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Bot-Harness uses the microphone so you can talk to your bots instead of typing.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Bot-Harness controls other apps on your Mac to carry out the tasks you give your bots.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Bot-Harness reads and writes files in the folders you give a bot as its workspace.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Bot-Harness reads and writes files in the folders you give a bot as its workspace.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Bot-Harness reads and writes files in the folders you give a bot as its workspace.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Adequate for running locally; rejected by Gatekeeper if the bundle is ever
# quarantined (i.e. downloaded or AirDropped). Distribution needs a Developer ID + notarisation.
# Set BOTHARNESS_SIGN_IDENTITY to sign with a real certificate instead.
IDENTITY="${BOTHARNESS_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

print -P "%F{green}built%f  $APP  ($VERSION, signed with '${IDENTITY}')"
print    "run with: open $APP"

if [[ "$IDENTITY" == "-" ]]; then
  print -P "\n%F{yellow}note%f  Ad-hoc signing changes the app's identity on every rebuild, so macOS may"
  print    "      re-ask for Accessibility and Screen Recording after each build. Set"
  print    "      BOTHARNESS_SIGN_IDENTITY to a stable certificate to avoid that."
fi
