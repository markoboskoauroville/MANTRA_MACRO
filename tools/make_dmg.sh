#!/bin/sh
# make_dmg.sh: the installer, a disk image with the app, a shortcut to Applications and the first-launch note
# (Marko, 31.10.2026: "please make a nice installation file. Then let people use it."). Run after build.sh.
set -e
cd "$(dirname "$0")/.."
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Macro Recorder (Mantra)"
STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "build/$NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
Mantra Macro Recorder $V  —  https://mantramacrorecorder.pages.dev

1. Drag "Macro Recorder (Mantra)" onto the Applications folder.
2. Open it from Applications. The first time, macOS says it cannot check the app, because it is signed by its author
   and not through Apple's paid program. Open System Settings > Privacy & Security, scroll down, and press
   "Open Anyway" next to Macro Recorder (Mantra). (On older macOS: right-click the app > Open > Open.)
3. Allow what it asks for, each in System Settings > Privacy & Security:
   Accessibility (to play clicks and keys), Input Monitoring (to record them), Screen Recording (to find a button by
   its picture). The app's PERMISSIONS panel shows each one and opens the right page.
4. The red-ring icon in the menu bar opens it. Control+Option+Command+R records, Control+Option+Command+P plays.

Macros are plain AutoHotkey v2 scripts in ~/.mantra_macro/macros. The language is in the app (DOCS).
Free to use. If it helps you, put something in the bowl on the website.
TXT
cp "build/$NAME.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
OUT="build/MantraMacroRecorder-$V.dmg"; rm -f "$OUT" build/tmp.dmg
hdiutil create -quiet -volname "Mantra Macro Recorder $V" -srcfolder "$STAGE" -fs HFS+ -format UDRW build/tmp.dmg
D=$(hdiutil attach -nobrowse -noverify -noautoopen build/tmp.dmg | awk '/\/Volumes\//{print $3" "$4" "$5" "$6}' | sed 's/ *$//')
command -v SetFile >/dev/null && SetFile -a C "$D" || true
hdiutil detach -quiet "$D"
hdiutil convert -quiet build/tmp.dmg -format UDZO -imagekey zlib-level=9 -o "$OUT"; rm -f build/tmp.dmg
codesign --force -s "Mantra Apps" "$OUT"
ls -l "$OUT"
