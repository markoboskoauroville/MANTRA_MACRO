#!/bin/sh
# build.sh: Macro Recorder (Mantra).app, swiftc straight, no Xcode, signed "Mantra Apps"
# (MANTRA_MANIFEST mac-app-signing.md, swift-apps.md). The version is the one number in app/App.swift.
set -e
cd "$(dirname "$0")"
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
