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
source scripts/_toolchain.sh

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

# Signing identity.
#
# This matters far more than it looks. macOS ties TCC grants — Screen Recording and
# Accessibility, the two permissions this entire product runs on — to the app's designated
# requirement. An ad-hoc signature's requirement is a per-build cdhash, so every single
# rebuild would look to macOS like a different app and silently revoke both grants. During
# active development that is unbearable.
#
# So: sign with a real certificate if one exists, and only fall back to ad-hoc if none does.
IDENTITY="${BOTHARNESS_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
             | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  print -P "%F{yellow}warn%f  no signing identity found; falling back to ad-hoc."
  print    "      Screen Recording and Accessibility grants will be revoked on every rebuild."
fi

codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"

print -P "%F{green}built%f  $APP  ($VERSION, signed with '${IDENTITY}')"
print    "run with: open $APP"

# The designated requirement is what TCC keys grants against. Print it so a rebuild that
# silently changes identity is visible rather than mysterious.
print -P "\n%Bdesignated requirement%b"
codesign -d -r- "$APP" 2>&1 | grep -E '^designated' | sed 's/^/  /'

if [[ "$IDENTITY" == "-" ]]; then
  print -P "\n%F{yellow}note%f  Ad-hoc signed. macOS will re-ask for Accessibility and Screen Recording"
  print    "      after every rebuild. Set BOTHARNESS_SIGN_IDENTITY to avoid that."
fi
