# TAKEOVER: the macro recorder on a fresh Mac

1. `git clone https://github.com/markoboskoauroville/MANTRA_MACRO ~/Developer/MANTRA_MACRO`
2. The "Mantra Apps" signing certificate in the login keychain (MANTRA_MANIFEST modules/mac-app-signing.md).
3. `sh tests/run_script_tests.sh && sh build.sh`: the language's 58 checks and RECALIBRATE's 15, then
   `/Applications/Macro Recorder (Mantra).app`, signed, bundle id `community.auroville.macrorecorder`.
4. Open it (from the star's row, or the Finder). Allow it, once, in System Settings → Privacy & Security:
   **Accessibility** (to play clicks and keys), **Input Monitoring** (to record them; asked at the first
   RECORD), **Screen Recording** (to look for pictures, and for RECALIBRATE's window pictures; asked at the first FIND or ClickImage).
5. ⌃⌥⌘R records, ⌃⌥⌘P plays, ⌃⌥⌘. stops, ⌥digit loads a slot, ⌃digit runs it, ⌃⌥⌘M the window.

State is under `~/.mantra_macro/`; copy that folder to carry the macros, the pictures and the slots to
another Mac. Nothing starts by itself: the star brings it back at login only if it was on.

- 31.10.2026: done, built v4 31.10.2026: TOP on the first row between the gap and PERMISSIONS/✕, green = the window floats above every other; it uses the app's own setting onTop in ~/.mantra_macro/settings.json (already there and applied at launch), so KEEP ON TOP in WINDOW AND FOLDER went (the same switch twice), and QUIT at the bottom went (swift-apps.md No QUIT; OFF quits, now after answering the press). Every word carries an Accessibility identifier (on, off, top, close, …). Checked at the minimum width 380 by a window capture (nothing cut or overlapping) and TOP pressed through AX twice (window layer 3, then 0). Relaunched: no REC/PLAY note on screen, v3 quit through its Quit menu item (AX), v4 opened with --login, window closed again
- 31.10.2026: v5 built and installed (pid 95894 → 69629): the inbox (~/.mantra_macro/inbox, app/Inbox.swift) and tools/macro (linked as ~/.local/bin/macro); tested: a MouseGetPos/FileAppend script answered ok, a broken line answered with its error and line; first real use: Space in DaVinci Resolve. Claude Code uses it instead of Hammerspoon from now on.
- 31.10.2026: v6 built and installed (pid 69629 → 84916): MenuSelect (Accessibility, "…" = "...") and WinGetPos (CGWindowList); 56 language checks pass; used at once in Resolve (Fairlight > Presets Library, the Voice Training dialogs).
- 31.10.2026: v7 built (universal, lipo arm64 + x86_64), installed, relaunched (pid 84916 → 42781): menu-bar icon (seen in the menu bar via System Events), RELEASES → mantramacrorecorder.pages.dev; 56 language checks pass. DMG 1.16 MB (mounted, signature valid, both architectures). Site written in site/public; the first deploy waits for Marko's yes (the permission check stopped the publish). Star row removed.
- 1.11.2026: v8 built (universal), installed, relaunched (pid 15997 → 55219 after the test builds): RECALIBRATE. A named
  recording stores the view of each window clicked in (`~/.mantra_macro/refs/<name>/`); RECAL / `macro recalibrate` /
  `Recalibrate "name"` moves every literal click to where the window is now, checked by picture; AUTO RECALIBRATE does
  it before play when the window moved; VIEW / `macro view` stores a view for an older macro; `macro record` / `macro
  stop` for Claude. Tested end to end on a throwaway window on the MacBook screen (README, LESSONS 40–45): move+resize,
  shrink with AUTO, pure move, a patch hidden (refused, kept), two targets swapped (found by picture 97 %); every play
  logged the five targets in order. Not tested: a real change of screen scale (the BenQ was off limits).


## Publishing: the download button always gives the newest version (1.11.2026)

MANTRA_MANIFEST modules/download-always-latest.md. The button on https://mantramacrorecorder.pages.dev links one address that never
changes: **https://mantramacrorecorder.pages.dev/download/MacroRecorder.dmg**. Nobody edits the page for a new version.

- `./build.sh` builds, signs, installs, then publishes by itself: `tools/make_dmg.sh` (build/MantraMacroRecorder-<V>.dmg) and
  `tools/deploy_site.sh`. `./build.sh --no-publish` builds and installs only.
- `tools/deploy_site.sh` takes V from `let VERSION` in app/App.swift, refuses a DMG of 25 MB or more (Cloudflare Pages' limit:
  then a GitHub release, per the module), removes every .dmg from site/public, copies the DMG to
  site/public/download/MacroRecorder.dmg, adds the `site/public/_redirects` line(s) that send the old versioned names
  (`/MantraMacroRecorder-*`) to it with a 301, writes the version and the size into `<span id="app-version">` and
  `<span id="app-size">` of index.html, runs the SEO kit with `--download download/MacroRecorder.dmg`, checks no versioned
  name is left on the page, and deploys with wrangler. To publish the current version again without building:
  `tools/deploy_site.sh` (the DMG in build/ must exist).
- The check after a release: `curl -sI https://mantramacrorecorder.pages.dev/download/MacroRecorder.dmg` answers 200 and the page shows
  the new version.
- 1.11.2026: v8 put behind the fixed address, live checked: 200, the same bytes as build/MantraMacroRecorder-8.dmg (1366077), MantraMacroRecorder-8.dmg → 301, the page says Version 8.

## v9 (1.11.2026): Run runs an executable

`Run "/path/script.sh [args]"`: an executable file (not a folder or .app) is started as a process, as AutoHotkey's Run
does; documents, apps and addresses open as before (Engine.swift run). For Elevate Media Project Monitor's ▶ FINISH
macro, which opens iTerm with a command instead of typing into it. Published v9 (DMG + page).
