# TAKEOVER: the macro recorder on a fresh Mac

## 13.11.2026: the Linux build is the second location's hand (v3)
Marko: "Macro Recorder needs to be translated to Linux, exactly the same as here." linux-v1/v2 (GTK + xdotool, the script language, the inbox) were
already on the VM (mantra-macro.service, DISPLAY=:1). v3 adds `linux/mantra_macro/verbs.py` and the `macro` words of the Mac, same arguments:
`capture-screen|capture-rect|capture-window` (ImageMagick import), `ocr`, `find-text`, `click-text`, `wait-text` (tesseract tsv, lines with their middle x,y),
`win-list`, `win-move`, `win-snap` (all Rectangle actions on the one screen), `win-minimize|maximize|restore|top|bottom` (wmctrl/xdotool), `ax-quit` (closes the
window), `lock|unlock|lock-status|request` (bookkeeping only), and `macro has|skills` through `macroskill`. Tests: tests/test_verbs.py (snap rectangles, tsv, verb
detection), 15 in all. Built by .github/workflows/linux.yml as linux-v3, installed with `sh linux/install.sh`.
**Differs from the Mac (v25/v26):** no Accessibility (`ax-read`, `ax-press`, `ax-focus-end`: needs gir1.2-atspi-2.0 and an app that exposes it; Chrome on the VM does
not by default), no `capture-page`, `recalibrate`/`view`, `layout`, `trigger`, `login-dialog`, no real input lock (the Mac swallows Marko's input with an event tap;
on X11 that would also swallow Claude's xdotool, and nobody sits at the VM during a run), one display (`next-display` is an error), `Recorder` uses X events,
the script language is the Python interpreter of linux/mantra_macro/script.py (not Script.swift), so rare constructs may differ: test a script on the VM before trusting it.
Shared with the Mac: the macros folder format (~/.mantra_macro/macros/*.ahk), the inbox protocol, the catalogue MACRO_SKILLS. Not auto-copied between machines:
macros hold screen coordinates.  Sync: groq_ai_studio/two_locations_sync.sh installs a newer linux-vN when MANTRA_MACRO/linux changed.

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
- 31.10.2026: v7 built (universal, lipo arm64 + x86_64), installed, relaunched (pid 84916 → 42781): menu-bar icon (seen in the menu bar via System Events), RELEASES → macrorecorder.markobosko.org; 56 language checks pass. DMG 1.16 MB (mounted, signature valid, both architectures). Site written in site/public; the first deploy waits for Marko's yes (the permission check stopped the publish). Star row removed.
- 1.11.2026: v8 built (universal), installed, relaunched (pid 15997 → 55219 after the test builds): RECALIBRATE. A named
  recording stores the view of each window clicked in (`~/.mantra_macro/refs/<name>/`); RECAL / `macro recalibrate` /
  `Recalibrate "name"` moves every literal click to where the window is now, checked by picture; AUTO RECALIBRATE does
  it before play when the window moved; VIEW / `macro view` stores a view for an older macro; `macro record` / `macro
  stop` for Claude. Tested end to end on a throwaway window on the MacBook screen (README, LESSONS 40–45): move+resize,
  shrink with AUTO, pure move, a patch hidden (refused, kept), two targets swapped (found by picture 97 %); every play
  logged the five targets in order. Not tested: a real change of screen scale (the BenQ was off limits).


## Publishing: the download button always gives the newest version (1.11.2026)

MANTRA_MANIFEST modules/download-always-latest.md. The button on https://macrorecorder.markobosko.org links one address that never
changes: **https://macrorecorder.markobosko.org/download/MacroRecorder.dmg**. Nobody edits the page for a new version.

- `./build.sh` builds, signs, installs, then publishes by itself: `tools/make_dmg.sh` (build/MantraMacroRecorder-<V>.dmg) and
  `tools/deploy_site.sh`. `./build.sh --no-publish` builds and installs only.
- `tools/deploy_site.sh` takes V from `let VERSION` in app/App.swift, refuses a DMG of 25 MB or more (Cloudflare Pages' limit:
  then a GitHub release, per the module), removes every .dmg from site/public, copies the DMG to
  site/public/download/MacroRecorder.dmg, adds the `site/public/_redirects` line(s) that send the old versioned names
  (`/MantraMacroRecorder-*`) to it with a 301, writes the version and the size into `<span id="app-version">` and
  `<span id="app-size">` of index.html, runs the SEO kit with `--download download/MacroRecorder.dmg`, checks no versioned
  name is left on the page, and deploys with wrangler. To publish the current version again without building:
  `tools/deploy_site.sh` (the DMG in build/ must exist).
- The check after a release: `curl -sI https://macrorecorder.markobosko.org/download/MacroRecorder.dmg` answers 200 and the page shows
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
  captures through these (MANTRA_MANIFEST macro-recorder.md, capture section). Published to macrorecorder.markobosko.org.
- Next if needed: capture a window's region only; a short frame burst (N frames, bounded) for a moving window.

## 3.11.2026 close, v14–v16
- Triggers: settings.json "triggers" {name: {key, mods, on}}, bound in Engine.bindKeys as Carbon hot keys; inbox
  `trigger: <name> | <key> | on|off`; CLI `macro trigger`. First one: "F1 Claude dictation" on F1 (on).
- v15: Overlay writes beside the status item (dot + text), no panel; spinner = "…".
- v16: AXClick "App", "label" (AX.center + a real click, pointer restored). build.sh restarts the app (old/new pid).
- Site macrorecorder.markobosko.org deployed by build.sh (v16 dmg); release v16 Latest.

## 8.11.2026, v18
- The top of the window (Marko: "drop-down menu with all the macros ... load, unload, edit, shortcut key ... only use F keys ... also none"): section MACRO under the first row: one drop-down with every macro (its key and "(unloaded)" beside the name), then LOAD (in the player, its key plays it; green while loaded), UNLOAD (out of the player, its key does nothing; the key is kept for the next LOAD), EDIT, and KEY: NONE / F1 … F12. The key lives in settings.json "triggers", never in the script (Engine.loadForTop / unload / setFKey; a recording must be EDITed into a script once before it can have a key).
- First GitHub workflow (.github/workflows/build.yml from MANTRA_MANIFEST mac-swift.yml); build.sh takes SIGN and NO_INSTALL=1. From now on: push, GitHub builds, the Mac installs the release zip and signs it "Mantra Apps".
- 9.11.2026, v20: window moving and arranging (app/WinMgr.swift, from Rectangle, MIT, THIRD_PARTY/). Commands in docs/SCRIPT.md "Windows: move and arrange".
- 13.11.2026: v24 built by GitHub (green, run 43470037253, release v24 Latest, NOT yet installed or relaunched: Marko was using the Mac): THE INPUT LOCK, a port of the phone's Lock.kt (app/Lock.swift). Every script that runs (macro do, macro run, slots, keys, a played recording, any inbox script) takes the lock for its length and lets it go at the end; the bar sits under the menu bar on every display (CLAUDE · 0:42 left · name, or MACRO when Marko started it; TAKE OVER at the right); an active event tap (.cgSessionEventTap, .defaultTap) swallows his mouse, scroll and keys, the macro's own events carry eventSourceUserData MACRO_MARK and pass (CGEvent.markedPost() in every place the engine posts); TAKE OVER or Escape held 1 s = overridden: the macro stops at its next step with "overridden by Marko", Claude's new runs are refused, the orange blob GIVE THE MAC BACK TO CLAUDE gives it back. `macro lock "<text>" [seconds]`, `macro unlock`, `macro lock-status`, `macro request "<what>"` and 127.0.0.1:8829 (GET /status, POST /lock /unlock /through /request) like the phone. BlockInput On/Off maps to it. Watchdog: lifted after run + 30 s (estimate x2 + 30), never beyond 10 minutes. Without Accessibility it does not block and says so. Not tested on the real Mac yet: see LESSONS 48.
- 13.11.2026: v25: the lock bar's text and TAKE OVER are one group centred on the screen's centre line (text a fixed 420 pt, time in monospaced digits, cap-height centred); the blob GIVE THE MAC BACK TO CLAUDE / CLAUDE ASKS FOR THE MAC takes exactly TAKE OVER's screen, centre, size (236x22) and shape, not draggable (eye trace, MANTRA_MANIFEST alignment.md). Panels are titled "Macro Recorder input lock bar/blob", sharingType .readOnly, window layer 25 (.statusBar), owner "MacroRecorder".
- 13.11.2026: v26 (Marko: "Everything is bottom center"): the lock bar sits at the bottom of every screen, just above the Dock (visibleFrame.minY), text and TAKE OVER one centred group; the blob takes the same bottom-centre spot and size. Supersedes the "under the menu bar" placement of v24/v25.
- 14.11.2026: v27, THE ONE GUARD (Marko: "this guard should be available for any action happening by Claude or any of my star apps ... When you finish, I want to have it back. Same prompt where I was. And even if I touch something during the block, you should catch it and write it down"). Cause found first: the Keyboard and Mouse Router (8870) that `macro` called was never installed, so every call "ran as before" unguarded; firefoxctl and wa_remote.py never asked for any guard; `browsingContext.activate` fronted Firefox and his typing went into the WhatsApp box. Now the lock here IS the guard: `app/Guard.swift` (GuardBook) snapshots the front app, its focused window, focused element and caret when the lock comes on, records every swallowed key (keycode, modifiers, characters) and click, and when it lifts (end, linger, TAKE OVER, watchdog) raises the app and window, re-focuses the element, restores the caret and replays his keys there in order (⌘ only A Z X C V ⌫ arrows; ⎋, ⌃C, ⌃D never), clicks noted only; if his app will not come front, nothing is typed and his text goes to the clipboard. Notice "3 s held · 17 keys replayed into iTerm2", log ~/.mantra_macro/guard_log.jsonl, GET /last. Lock.swift: owner queue (POST /lock {text,seconds,owner,pid,restore} answers busy for another holder; nested same owner; POST /unlock {owner,linger_ms}), the holder's pid watched (gone = lifted), the blobs free the Mac instead of re-locking ownerless. Client `tools/guard.py` = `guard` on the PATH (run/begin/end/status/last/log/wait-idle, Python `guard.held()`): waits until he is still 1.5 s (max 6 s), queues, kills `guard run`'s command on TAKE OVER (exit 130). `macro run|do|click-text` take it (2.5 s linger), `macro lock/unlock` are guard begin/end. Wired: firefoxctl activate/open, wa_remote.py (all page commands; draft/send refuse without it), chrometabs go/open, the whatsapp-web skill's wa_locked.sh. Test: tests/test_guard.py (new iTerm2 window with `cat -u`, new TextEdit doc): 4/4 PASS on the real Mac, 17 keys replayed exactly, front back; queue, holder-gone and a live `firefoxctl activate` checked. Built by GitHub (run 43580426995, green), release v27 Latest, installed, signed Mantra Apps, relaunched.
- 15.11.2026: v28, the lock for a holder that owns the keyboard (Talk Mode (Mantra) v11's SPACE MODE): POST /lock {owner, text, keys: "pass" (keys are not swallowed or recorded: the holder's own tap takes them), plain_bar: true (the bar shows the holder's sentence alone, as wide as it needs), blob: false (TAKE OVER / Escape end it straight to off, no GIVE THE MAC BACK blob), esc_hold: 2 (seconds Escape is held), beat: 5 (the watchdog: no POST /beat {owner} for 5 s = the holder hangs, the lock lifts; hard limit then 2 h)}; GET /status has `ended` (unlock, takeover, escape, heartbeat, holder-gone, time) and `options`. `--bar-shot <png> "<text>"` draws that bar off screen. The bar is built by one function (makeBar) for the lock and the shot.
- 16.11.2026: v29, PAUSE / RESUME (Marko: "All our tools need to be paused at the same time and need to have this kind of API calls to be stopped."). app/Pause.swift (PauseGate): `macro pause [who]`, `macro resume [who]`, `macro pause-status` (prints paused|running, exit 0); POST 127.0.0.1:8829/pause {by}, POST /resume, GET /pause {"paused", "state", "playing", "held_at_step", "queued", "since", "by"}; inbox `pause:` / `resume:` / `pause-status:` answered at once even while a macro runs; menu bar menu "Pause macros / Resume macros", icon and text PAUSED in orange. While paused: MacHost.check() and every Sleep hold at the step boundary (the short waits inside a click, drag or key never pause), a Sleep keeps its remaining time, Run/WinActivate/MenuSelect/Win* wait too; the inbox keeps new files queued (the CLI does not count its timeout while ~/.mantra_macro/paused exists); runScript refuses keys/slots/PLAY; a new guard holder (POST /lock) is answered busy+paused and guard.py waits for RESUME however long. A lock that is on at PAUSE gives Marko his place and held keys back (GuardBook.finish "paused") and its tap lets everything through, bar "PAUSED · your Mac is yours until RESUME"; watchdog, countdown and Escape-hold are frozen; RESUME adds the paused time to the deadline, writes his new place down (GuardBook.begin), fronts the macro's app again and swallows again. Never SIGSTOP the app. The state survives a restart (the file). Registered in ~/.config/claude-control/tools.json as "Macro Recorder" (cmd entries). Updater.swift (kits/mac-updater) added: asks to update at start. Built by GitHub (run 43856043143, green), release v29 Latest, installed, signed Mantra Apps, relaunched (pid 807 → 35413). Test (screen locked, harmless FileAppend macro): 8 steps of 1 s, paused after step 4, held 5.5 s (status paused, held_at_step true, lock on and paused), a second `macro do` queued (queued 1) and did not run, RESUME: steps 5-8 continued at the same 1 s rhythm, the queued one ran, both CLIs answered ok without timeout. Not tested by hand: his keys passing under a paused lock, the orange PAUSED in the menu bar (screen was locked).

## v31 (19.11.2026): exact file rename for generic downloads

`macro file-rename "<source path>" "<new filename>"` is a new Macro Recorder command for a just-saved file whose site-generated
name is generic. It only accepts a regular file, keeps the file in the same folder and preserves the extension; it refuses
an existing destination and verifies that the source disappeared and the destination retained the same byte count.
The save-dialog workflow uses existing `capture-screen`, `ax-read`, and `ocr` before pressing Save, then reads the dialog
back and verifies the exact output. `tests/FileRenameTests.swift` passes all 9 checks. `NO_INSTALL=1 SIGN=- ./build.sh --no-publish` builds v31 successfully.
GitHub run 44547780398 passed and published Macro Recorder v31 Latest:
https://github.com/markoboskoauroville/MANTRA_MACRO/releases/tag/v31. This session did not install v31 locally.
The combined test script runs the 9 rename checks first, then stops at its existing `Script.swift` compile errors
(`PageCapture`, `Pictures`, `AX`, and `InputLock` are not included in that test command); that unrelated harness was left
unchanged.

## Menu-bar hover card and pipes (v30, 16.11.2026)
Marko: "with all my apps on the menu bar, make a comprehensive pop-up menu. When I hover over, I want to see what is it and what is it doing." and "for my apps always make a pipes before and after so I know where one app ends and other begins." `app/HoverCard.swift` is the shared kit file (MANTRA_MANIFEST kits/menubar-hover, rule modules/menubar-hover.md): hovering the item about 0.4 s shows a card with name, what it is, state and live lines; a thin grey pipe stands before and after the visible title. The app supplies its lines in the `HoverCard.attach(...)` closure. Test without a mouse: launch with `--hovercard-shot`. Change the lines in the app; change the module only in the kit.

## v32 (22.11.2026): the text blob
Marko asked for it word for word 22.11.2026 (momentaryupdates.md). Files: app/BlobRules.swift (pure: clean, duration, wrap, stack,
done gate, placement, screen index), app/BlobPanel.swift (the window: never key or main), app/Blob.swift (BlobCenter, BlobView,
the focus-screen rule), hooks in Lock.swift (`off()` -> lockReleased, `engage()` -> lockTaken for CLAUDE locks; routes POST /blob and
GET /blobs in LockServer), `--blob-shot` in App.swift, `macro blob` in tools/macro. Tests: tests/run_blob_tests.sh, a step of
.github/workflows/build.yml before the build. Nothing was removed: every earlier command and control stays.
Install: `gh release download v32`, unzip into /Applications, `codesign --force -s "Mantra Apps"`, same bundle id
community.auroville.macrorecorder, so no permission is asked again. Not proven: how the blob reads over a full-screen app on each screen.
v33 (22.11.2026): quit refused while the input lock is held (`applicationShouldTerminate`, covers menu, OFF, Apple event, ax-quit); blob ✕ ("Close blob: <text>") and sticky blobs answer `macro ax-press`; Queen's skill tell-marko-on-screen (groq_ai_studio) runs `macro blob`.

## v34 (25.11.2026): the input guard as a lease, the bar always seen
Asked word for word in momentaryupdates.md (25.11.2026). Root causes with evidence: (1) the bar existed but was never on screen
because the app was hidden (launched hidden at login, AXHidden true): CGWindowList listed both bars without kCGWindowIsOnscreen,
screenshots of both displays showed no bar; unhiding the live process through AX made a blob appear at once. (2) workers held
`guard begin --seconds 180` across their thinking (guard_log: 257 s and 197 s held for a few seconds of clicks), and a worker
that ends without `guard end` inside a long-lived Claude process is never "gone". (3) keys replayed into Chrome: his app was taken
as the app in front at lock time, which the worker had already changed.
Changes: Lock.swift (lease 4 s idle / 60 s cap renewed once / 90 s watchdog, ownerPids, FIFO queue, POST /ping, POST
/release-all off the main thread, ⌃⌥⌘Esc, stale marker ~/.mantra_macro/lock_held, bar canHide false + screen-saver level +
on-screen check every second + rebuild on display change, bigger bar, AX press on TAKE OVER and the blob, status: lease, queue,
bar, front_now), Guard.swift (HandTracker: his last real touch; keys after an app switch to the clipboard; verified give-back;
holder re-front within 2 minutes; logLine), App.swift (startupCheck, HandTracker, screen observer, unhide at start), canHide false
on BlobPanel, Overlay, HoverCard. tools/guard.py (ping, release-all, run(), clear messages and exit codes), tools/guarded,
tests/test_lease.py. Docs: MANTRA_MANIFEST modules/input-guard.md, skill macro-skills.
Install: `gh release download v34`, quit the old app with `macro ax-quit` after `/status` says lock off, unzip into /Applications,
`codesign --force --deep -s "Mantra Apps"`, `open -g -a "Macro Recorder (Mantra)" --args --login` (as at login: no window, no
permission prompt; settings, macros and the PAUSE state live in ~/.mantra_macro and come back by themselves).

## v41 (28.11.2026): the Dashboard and the run log
New files: `app/Dashboard.swift` (RunLog, the rows, PLAY/PAUSE/STOP, the /dashboard API) and `app/DashboardView.swift` (the window). Touched:
`Engine.swift` (a `source` on every run, per-job pause `MacHost.paused` / `Engine.pauseRun` / `resumeRun`, run_start / run_end lines, hotkey
paused check), `VisualTrigger.swift` (a `paused` set, the score, trigger_fired line), `Script.swift` (ClickImage reports its score and point
through `ScriptHost.noteImageClick`), `Lock.swift` (route /dashboard*), `App.swift` (menu item "Dashboard (N watching)" updated every 0.5 s,
`_ = Dashboard.shared.launched`), `Inbox.swift` (source "inbox"). settings.json is untouched by the update: a trigger that was on stays on until
Marko presses STOP in the Dashboard. The first row on the day of release was "Auto Keep Button", WATCHING, left on on purpose.
Install as for v34 above: `gh release download v41`, unzip into /Applications, `codesign --force --deep -s "Mantra Apps"`, `open -g -a "Macro Recorder (Mantra)" --args --login`.
v42 (28.11.2026): the Dashboard window kept its own size (v41 grew to 3600 px: `NSHostingView.sizingOptions = []`), and it says when the app-wide PAUSE is on
(a RESUME button; the menu item reads "Dashboard (1 watching, ALL MACROS PAUSED)"): a trigger shown WATCHING does not fire while the app is paused.
