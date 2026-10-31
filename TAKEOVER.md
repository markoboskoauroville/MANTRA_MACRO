# TAKEOVER: the macro recorder on a fresh Mac

1. `git clone https://github.com/markoboskoauroville/MANTRA_MACRO ~/Developer/MANTRA_MACRO`
2. The "Mantra Apps" signing certificate in the login keychain (MANTRA_MANIFEST modules/mac-app-signing.md).
3. `sh tests/run_script_tests.sh && sh build.sh`: the language's 55 checks, then
   `/Applications/Macro Recorder (Mantra).app`, signed, bundle id `community.auroville.macrorecorder`.
4. Open it (from the star's row, or the Finder). Allow it, once, in System Settings → Privacy & Security:
   **Accessibility** (to play clicks and keys), **Input Monitoring** (to record them; asked at the first
   RECORD), **Screen Recording** (to look for pictures; asked at the first FIND or ClickImage).
5. ⌃⌥⌘R records, ⌃⌥⌘P plays, ⌃⌥⌘. stops, ⌥digit loads a slot, ⌃digit runs it, ⌃⌥⌘M the window.

State is under `~/.mantra_macro/`; copy that folder to carry the macros, the pictures and the slots to
another Mac. Nothing starts by itself: the star brings it back at login only if it was on.

- 31.10.2026: done, built v4 31.10.2026: TOP on the first row between the gap and PERMISSIONS/✕, green = the window floats above every other; it uses the app's own setting onTop in ~/.mantra_macro/settings.json (already there and applied at launch), so KEEP ON TOP in WINDOW AND FOLDER went (the same switch twice), and QUIT at the bottom went (swift-apps.md No QUIT; OFF quits, now after answering the press). Every word carries an Accessibility identifier (on, off, top, close, …). Checked at the minimum width 380 by a window capture (nothing cut or overlapping) and TOP pressed through AX twice (window layer 3, then 0). Relaunched: no REC/PLAY note on screen, v3 quit through its Quit menu item (AX), v4 opened with --login, window closed again
- 31.10.2026: v5 built and installed (pid 95894 → 69629): the inbox (~/.mantra_macro/inbox, app/Inbox.swift) and tools/macro (linked as ~/.local/bin/macro); tested: a MouseGetPos/FileAppend script answered ok, a broken line answered with its error and line; first real use: Space in DaVinci Resolve. Claude Code uses it instead of Hammerspoon from now on.
- 31.10.2026: v6 built and installed (pid 69629 → 84916): MenuSelect (Accessibility, "…" = "...") and WinGetPos (CGWindowList); 56 language checks pass; used at once in Resolve (Fairlight > Presets Library, the Voice Training dialogs).
