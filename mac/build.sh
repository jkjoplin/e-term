#!/bin/sh
# Builds Eink Focus.app from EinkFocus.swift into mac/build/.
#
# Usage: mac/build.sh             build only
#        mac/build.sh --install   build, copy to /Applications, and restart the app
#
# The app records this checkout's path in its Info.plist (EinkFocusRoot), so it finds
# config/eink-focus.json and the kterm terminfo source here. docs/configuration.md
# lists the other places it looks for its config. Because of that path, a built app
# is for this Mac; build it on each Mac instead of sharing the .app.
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
APP="$HERE/build/Eink Focus.app"
DEST="/Applications/Eink Focus.app"

command -v swiftc >/dev/null || { echo "swiftc is missing. Install the Xcode command line tools: xcode-select --install"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/EinkFocus" "$HERE/EinkFocus.swift"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/kindle/kterm/terminfo/kterm-256color.src" "$APP/Contents/Resources/kterm-256color.src"
/usr/libexec/PlistBuddy -c "Add :EinkFocusRoot string $ROOT" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x EinkFocus 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed $DEST and started it."
fi
