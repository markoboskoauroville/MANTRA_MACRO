#!/bin/sh
# build.sh: Macro Recorder (Mantra).app, swiftc straight, no Xcode, signed "Mantra Apps"
# (MANTRA_MANIFEST mac-app-signing.md, swift-apps.md). The version is the one number in app/App.swift.
set -e
cd "$(dirname "$0")"
# ./build.sh               build, install, then publish: DMG + page (download-always-latest.md, 1.11.2026)
# ./build.sh --no-publish  build and install only
PUBLISH=1; for a in "$@"; do case "$a" in --no-publish) PUBLISH=0;; esac; done
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Macro Recorder (Mantra)"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# one app for Apple Silicon and Intel (v7: released to everyone, 31.10.2026)
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -o build/MacroRecorder-arm64 app/*.swift
swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos14.0 -o build/MacroRecorder-x86_64 app/*.swift
lipo -create build/MacroRecorder-arm64 build/MacroRecorder-x86_64 -output "$APP/Contents/MacOS/MacroRecorder"
# the icon carries the version (version-visible.md): drawn again at every build
(cd icon && swift make_icon.swift "$V" >/dev/null)
I=build/AppIcon.iconset; rm -rf $I; mkdir -p $I
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon_1024.png --out $I/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon/icon_1024.png --out $I/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $I -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>community.auroville.macrorecorder</string>
<key>CFBundleExecutable</key><string>MacroRecorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
cp docs/SCRIPT.md "$APP/Contents/Resources/SCRIPT.md"
codesign --force -s "Mantra Apps" "$APP"
rm -rf "/Applications/$NAME.app"; cp -R "$APP" /Applications/
echo "built $APP (v$V) and installed it in /Applications"
# v16 (Marko, 3.11.2026: "always restarting the app before I'm testing it, so I never end up testing the old version"):
# the running copy is asked to quit and the new one opened, every build; the pids are printed
OLD=$(pgrep -x MacroRecorder || true)
[ -n "$OLD" ] && osascript -e 'quit app id "community.auroville.macrorecorder"' >/dev/null 2>&1 || true
for i in $(seq 1 20); do pgrep -x MacroRecorder >/dev/null || break; sleep 0.3; done
pgrep -x MacroRecorder >/dev/null && pkill -x MacroRecorder || true
for i in 1 2 3 4 5; do open -g -a "/Applications/$NAME.app" 2>/dev/null; sleep 2; pgrep -x MacroRecorder >/dev/null && break; done
echo "restarted: old pid ${OLD:-none}, new pid $(pgrep -x MacroRecorder || echo NOT RUNNING), v$V"
# the release step: every new version reaches the page in the same run (MANTRA_MANIFEST download-always-latest.md)
if [ "$PUBLISH" = 1 ]; then
  tools/make_dmg.sh
  tools/deploy_site.sh
else
  echo "not published (--no-publish)"
fi
