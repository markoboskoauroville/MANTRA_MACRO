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

## 2.11.2026 (v9 → v11)
- v10: `AX.swift`, inbox `ax-read` / `ax-press` / `ax-quit`, the Accessibility half of the common Star API (STAR_API).
- v11: `PageCapture.swift`, `CapturePage` / `macro capture-page`: the whole page as one picture (shots wait until the
  picture stands still, the overlap is found on 96-column row signatures near the expected scroll, pieces laid over
  each other's 4 edge rows). Tested on WhatsApp Web's chat list: 70 shots, 880×57432 px, clean joins. Published v11.

## 3.11.2026 (v12 → v13)

- v12 (2.11.2026, built then, committed 3.11.2026): `macro ax-focus-end "<app>" [role] [n]` focuses the n-th control of a
  role with the cursor at the end (for "he only pastes the key").
- v13: `capture-window`, `capture-screen`, `capture-rect` (app/Capture.swift, Inbox.swift, tools/macro). Every session
  captures through these (MANTRA_MANIFEST macro-recorder.md, capture section). Published to mantramacrorecorder.pages.dev.
- Next if needed: capture a window's region only; a short frame burst (N frames, bounded) for a moving window.

## 3.11.2026 close, v14–v16
- Triggers: settings.json "triggers" {name: {key, mods, on}}, bound in Engine.bindKeys as Carbon hot keys; inbox
  `trigger: <name> | <key> | on|off`; CLI `macro trigger`. First one: "F1 Claude dictation" on F1 (on).
- v15: Overlay writes beside the status item (dot + text), no panel; spinner = "…".
- v16: AXClick "App", "label" (AX.center + a real click, pointer restored). build.sh restarts the app (old/new pid).
- Site mantramacrorecorder.pages.dev deployed by build.sh (v16 dmg); release v16 Latest.

## 8.11.2026, v18
- The top of the window (Marko: "drop-down menu with all the macros ... load, unload, edit, shortcut key ... only use F keys ... also none"): section MACRO under the first row: one drop-down with every macro (its key and "(unloaded)" beside the name), then LOAD (in the player, its key plays it; green while loaded), UNLOAD (out of the player, its key does nothing; the key is kept for the next LOAD), EDIT, and KEY: NONE / F1 … F12. The key lives in settings.json "triggers", never in the script (Engine.loadForTop / unload / setFKey; a recording must be EDITed into a script once before it can have a key).
- First GitHub workflow (.github/workflows/build.yml from MANTRA_MANIFEST mac-swift.yml); build.sh takes SIGN and NO_INSTALL=1. From now on: push, GitHub builds, the Mac installs the release zip and signs it "Mantra Apps".
- 9.11.2026, v20: window moving and arranging (app/WinMgr.swift, from Rectangle, MIT, THIRD_PARTY/). Commands in docs/SCRIPT.md "Windows: move and arrange".
- 13.11.2026: v24 built by GitHub (green, run 43470037253, release v24 Latest, NOT yet installed or relaunched: Marko was using the Mac): THE INPUT LOCK, a port of the phone's Lock.kt (app/Lock.swift). Every script that runs (macro do, macro run, slots, keys, a played recording, any inbox script) takes the lock for its length and lets it go at the end; the bar sits under the menu bar on every display (CLAUDE · 0:42 left · name, or MACRO when Marko started it; TAKE OVER at the right); an active event tap (.cgSessionEventTap, .defaultTap) swallows his mouse, scroll and keys, the macro's own events carry eventSourceUserData MACRO_MARK and pass (CGEvent.markedPost() in every place the engine posts); TAKE OVER or Escape held 1 s = overridden: the macro stops at its next step with "overridden by Marko", Claude's new runs are refused, the orange blob GIVE THE MAC BACK TO CLAUDE gives it back. `macro lock "<text>" [seconds]`, `macro unlock`, `macro lock-status`, `macro request "<what>"` and 127.0.0.1:8829 (GET /status, POST /lock /unlock /through /request) like the phone. BlockInput On/Off maps to it. Watchdog: lifted after run + 30 s (estimate x2 + 30), never beyond 10 minutes. Without Accessibility it does not block and says so. Not tested on the real Mac yet: see LESSONS 48.
