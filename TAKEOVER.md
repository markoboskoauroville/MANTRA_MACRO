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
