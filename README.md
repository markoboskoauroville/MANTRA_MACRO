# MANTRA_MACRO — the macro recorder, and AutoHotkey on the Mac

**Records what Marko does and writes it down as a script he can read and edit. Ten slots on the
digit keys, every key his own, a script editor that suggests the next command, and an eye that
finds a button on the screen from a picture of it. Since 30.10.2026 a Swift app,
`/Applications/Macro Recorder (Mantra).app`, opened from its row in the star.**

Marko, 30.10.2026: "please convert the app open on the MacBook Display Recorder to a Swift app". The
Lua under Hammerspoon (macro.lua, script.lua, slots.lua, settings_page.lua, editor_page.lua, find.py)
became one Swift app in `app/`, with the same folder, the same settings.json, the same `.ahk` macros
and the same keys. The page on :8829 is now the app's window; the editor and the language are windows
of their own; the eye is Swift (ScreenCaptureKit and a template match with Accelerate), so it needs no
Python and no OpenCV. The Lua files stay in the repository until Marko has played his own macros with
the Swift app; nothing loads them any more.

Marko's requests, 4.9.2026 and 5.9.2026: "It records everything I'm doing and repeating.
Control+Option+Command+R records, P plays." · "Option 1 to 0 loads a stored macro, Control 1 to 0
runs it; I assign any macro to any slot with check marks and reorder them in the web interface."
· "A script editor so the user can edit the macros himself. Copy the syntax from AutoHotkey, so the
user also learns AutoHotkey. If statements, loop statements, and all the other features." · "Load
screenshots of the buttons, so the app can click by optical recognition of the patterns on my screen."

## Claude Code drives the Mac through it (v5, 31.10.2026)

Marko: *"Please don't use Hammerspoon anymore. We have application called Macro Recorder. If it cannot do something, you
need to improve it."* Any script dropped as `~/.mantra_macro/inbox/<id>.ahk` runs at once (one at a time, never while
recording) and its answer is written next to it as `<id>.result.json` (`{"ok":…, "message":…, "line":…}`). A file
holding only `run: <name>` plays that stored macro. The command does both and waits:

```
macro run "Resolve - Voice Convert Render"
macro do 'WinActivate "DaVinci Resolve"
Send "{Space}"'
macro do - < script.ahk
```

v6 (31.10.2026) added the two commands those scripts needed most: `MenuSelect` (an app's menu item by its names,
through Accessibility) and `WinGetPos` (a window's position and size, so clicks are relative to the window).

## Released on its own (v7, 31.10.2026)

Marko: *"Macro Recorder should have a website. Let's try to get some donations going ... make a nice installation file.
Then let people use it. It is not part of the Start menu anymore. It is now released as an independent release."*

- **Website:** https://mantramacrorecorder.pages.dev (`site/public`, deployed by `tools/deploy_site.sh`): what it does,
  the download with its counter (`data-dl-app="macro"`), install steps (Open Anyway: it is signed "Mantra Apps", not
  notarized), the keys, privacy, the donation bowl (Revolut), the visit counter, the Speechify line.
- **Installer:** `tools/make_dmg.sh` → `build/MantraMacroRecorder-<v>.dmg`: the app (Apple Silicon + Intel), a shortcut to
  Applications, "Read me first.txt", the app's icon on the volume.
- **App:** an icon in the menu bar (red while recording, green while playing) with open, record, play, the website, quit;
  the version link opens the website. The star's row is gone (STAR_SWIFT rows.json).

## RECALIBRATE: the clicks follow the window (v8, 1.11.2026)

Marko: *"If some actions were recorded for a certain piece of software, recalibrate should take a screenshot of that
software, so that all mouse actions land in the same places, corrected. The screen resolution may have changed, or the
user may have moved the window somewhere else on the screen ... by comparing the current view with the stored view."*

- **The view.** While it records, the window under the pointer is pictured the first time the pointer comes over it
  (before any click changes it). When a named recording stops, every window that was clicked in is stored with the
  macro: `~/.mantra_macro/refs/<macro>/view.json` (app, bundle id, title, frame in points, the screen's size and
  scale) and `w0.png` (the window alone, ScreenCaptureKit, even if covered). Floating windows count (level 0 to 19:
  an app with TOP on sits at 3). VIEW (or `macro view "<name>" ["App"]`) stores it again on demand, from the windows
  under the macro's clicks as they are now; that is how an older macro gets a view.
- **RECALIBRATE** (RECAL beside the macro, `macro recalibrate "<name>"`, or `Recalibrate "<name>"` in a script): the
  window is found again (same bundle id, same title, else its biggest window) and pictured. Each literal x, y inside
  the stored window gets up to sixteen likely places (on each axis kept to the left or right edge, the centre, or
  scaled); each is checked by matching a 48-point patch of the stored picture around the click in the new picture
  (normalised cross-correlation on grey at one pixel per point, so 2× and 1× screens compare; ±8 points around each
  place). The first place seen at 80 % or more wins; else the patch is searched in the whole window (found by
  picture). A plain area grows the patch to 80 and 128 points. Not seen anywhere: a window that only moved still
  moves the point by its offset (exact); a resized one keeps the old point and the report says NOT FOUND. The file is
  rewritten (numbers only, one `; recalibrated …` comment under the first line), the version before goes to
  `trash/<name> <stamp> (before recalibrate).ahk`, the new view is stored, and the report is
  `refs/<name>/report.txt`.
- **AUTO RECALIBRATE** (PLAYBACK, on as it comes, setting `autoRecal`): before a stored macro plays (slot, ▶, PLAY,
  `macro run`) its windows are looked up; one that moved or changed size is recalibrated first (it costs one window
  list when nothing moved).
- **For Claude:** `macro record "<name>"` and `macro stop` record through the inbox (only `stop:` is taken while it
  records), so a macro can be recorded and checked without the keys.

```
$ macro recalibrate "recal test"
window testwin: was 420×328 at 2700, 120 (scale 2.0×), now 560×420 at 2800, 300 (scale 2.0×)
line 4  Click 2765, 192  → 2865, 372  moved by offset (+100, +180), seen 100%
line 6  Click 3055, 200  → 3295, 380  kept to the right edge across, top edge down (+240, +180), seen 100%
line 10  Click 2772, 402  → 2872, 674  kept to the left edge across, bottom edge down (+100, +272), seen 100%
recal test: 5 moved, 0 where they were, 0 not found (kept)
```

## The keys, as they come

```
⌃⌥⌘R    record; press again to stop. A red dot with REC sits bottom right while it records.
⌃⌥⌘P    play what is in the player; press again to stop. A green dot with PLAY.
⌃⌥⌘.    stop whatever runs. A recording that is stopped this way is saved.
⌃⌥⌘N    new macro: a box asks the name, then it records until the record key.
⌃⌥⌘M    the settings window, small.
⌥1..⌥0  put the macro in that slot into the player.
⌃1..⌃0  run the macro in that slot, now.
```

Every one of these is changed from the settings page. The two slot chords are sets of modifiers
(⌃ ⌥ ⇧ ⌘, tick the ones you want); they must differ and each must hold at least one. A key already
in use is refused, never bound twice. "Back to the default keys" puts all of this back.

The David star in the menu bar turns red while recording and green while playing.

Note that ⌥ with a digit normally types a symbol (¡ ™ £ …). While the recorder runs, those ten
chords are its; untick it, or move loading to another chord, and they type again.

## A macro is a script

Every macro is `~/.mantra_macro/macros/<name>.ahk`, in the syntax of AutoHotkey v2. A recording is
written down as one the moment it stops:

```
; 5.9. 10.42, recorded 2026-09-05 10:42:07
Click 381, 644
Sleep 900
Send "^c"
Sleep 500
Send "Hello{Enter}"
```

The language is in **[docs/SCRIPT.md](docs/SCRIPT.md)**, served at `/docs` from the page: the mouse,
the keyboard (`^c`, `!{Tab}`, `#v`, `{Ctrl down}`), waiting, pictures (`ClickImage "button.png"`,
`WaitImage`, `ImageSearch`), variables and expressions, `If`, `Loop`, `While`, `For`, `Break`,
`Continue`, functions with `&ref` parameters and `global`, arrays and maps, text and number functions,
`WinActivate`, `Run`, `MsgBox`. Directives from a Windows script (`#Requires`, `#SingleInstance`,
`SendMode`) are read and ignored, so a script written for AutoHotkey runs as it is, with `#` meaning
Command.

A `.json` recording from before the language still lists and plays; it becomes a script when it is
saved from the editor. The raw events of every recording are also kept under `recordings/` by date.

## The script editor

```
http://127.0.0.1:8829/editor?name=<macro>
```

Opened from a macro's **Edit** on the settings page, from the star menu, or by "Write new" on the
page. CodeMirror with a mode for the language; as you type at the start of a line the commands are
suggested, the likely next one first (after a Click comes a Sleep, after a Sleep a Send or a Click,
after a WaitImage a Click); inside `{` the key names; inside the quotes of an image command the
pictures in the folder; elsewhere the functions, the `A_` variables and the names the script has
assigned. A panel on the right lists every command with its shape and one line of what it does; click
to insert. ⌘S saves, ⌘↩ saves and runs, Check parses without running. An error names its line and
lights it; a script that fails while running reports its line in the window too. ⌥⎋ (or Esc in the
menu's Complete) asks for the suggestions at any place.

## The eye

"Snap button" on the settings page starts the system's own cross-hair: drag over a button, and
`~/.mantra_macro/images/<name>.png` is there. In a script, `ClickImage "name.png"` finds it on the
screen and clicks its centre; `WaitImage "name.png", 10` waits for it to appear; `find` beside a
picture on the page looks for it now, moves the mouse there and says the score.

**A search zone, or every screen.** Each picture either searches all screens, or a rectangle you
draw. On the page, "zone" lets you draw the zone with the cross-hair (the same one that snaps a button)
over where the button appears; "all" clears it back to every screen; "Snap & set zone" does the two
steps together, snap then zone. A zone is faster (only
that rectangle is shot) and cannot be fooled by something similar elsewhere. Zones live in
`settings.json` beside the picture's name.

**A spinner while it looks.** A small turning spinner sits bottom middle with "searching for a
pattern" and goes when the search ends. Every status line of the recorder shows there, centred along
the bottom, not in a corner (his request, 6.9.2026). It can turn because the search does not block: each region is
shot and handed to `find.py` as a background task, and the script's coroutine waits for the result
rather than freezing Hammerspoon.

`find.py` does the looking with OpenCV: a fast coarse pass on a downscaled screen, then the one
candidate it likes is verified at full resolution, so speed never costs a wrong click. The picture is
tried at its own size first, then half and double for a different-DPI screen; the best match across
every screen searched wins. The snapshot rectangle is in the screen's own coordinates; the result
comes back in the global points the clicks use.

## The slots

Ten slots, in keyboard order 1 2 3 4 5 6 7 8 9 0. A macro sits in one slot at most. A new macro,
recorded or written, lands in the first free slot by itself. On the page each slot row has ▶ (run
now), ▲ ▼ (swap with the neighbour), × (empty it), and the rows drag to reorder. A slot whose macro
was renamed or removed in the Finder says "not in the folder" rather than pretending.

## The window

One window, resizable, opened from the star's row or the settings key ⌃⌥⌘M (which also closes it).
The first row is MACRO RECORDER  ON  OFF with ✕ at the far right: OFF lets go of every key and quits,
✕ closes only the window and the keys keep working. Top to bottom: the transport with a readout (RECORD,
PLAY, STOP, "Record new", "Write new"), the slots, the macros (click a name to rename it, a digit puts
it in that slot, ▶, LOAD, EDIT, BIN), the pictures (Snap button, Snap & set zone, FIND, ZONE, ALL, BIN),
the keys (CHANGE, then press the chord; the two slot chords as ⌃ ⌥ ⇧ ⌘ toggles), playback (speed,
delay between clicks), the window and the folders, the language. QUIT at the bottom right, the version
at the bottom left (a click opens the latest release). Words are the keys; green is on, grey off,
amber the one in the player.

The page and its server on :8829 are gone with the Lua: nothing listens on the network.

## Files

    app/App.swift          the app: the window, the menu, ON / OFF, the version
    app/Engine.swift       record (an event tap), play (the host the language runs on), the slots and the keys from
                           the keyboard, pictures and zones, the status line and the spinner bottom middle
    app/Script.swift       the language: lexer, parser, interpreter, Send strings, recording to script. Foundation only
    app/Store.swift        the folder, settings.json, the ten slots, the macros on disk
    app/Keys.swift         key names (Hammerspoon's, from the current layout), the global chords (Carbon), catching a chord
    app/Eye.swift          the eye: a picture found on a screen shot, ScreenCaptureKit + Accelerate
    app/Recalibrate.swift  v8: the stored view (refs/), the windows on screen, RECALIBRATE, VIEW, the view while recording
    app/Coords.swift       v8: the literal coordinates of a script read and written back, the likely places (pure)
    app/Window.swift       the window (SwiftUI)
    app/Editor.swift       the script editor and the language window
    icon/make_icon.swift   the icon, drawn, with the version under it
    build.sh               swiftc, the icon, signed "Mantra Apps", installed in /Applications
    docs/SCRIPT.md         the language, shown in the language window (copied into the app)
    tests/run_script_tests.sh  the language against a fake host (58 checks) and RECALIBRATE's coordinates
                           (tests/RecalTests.swift, 15 checks), no app needed
    tests/*.lua            the Lua tests of the Lua version, kept with it
    ~/.mantra_macro/settings.json   speed, clickDelay, keys, slots, zones, window
    ~/.mantra_macro/macros/         the macros, <name>.ahk
    ~/.mantra_macro/images/         the pictures
    ~/.mantra_macro/last.ahk        the plain last recording
    ~/.mantra_macro/recordings/     the raw events of every recording, kept
    ~/.mantra_macro/trash/          whatever the bin removed, and every macro as it was before a recalibration
    ~/.mantra_macro/refs/<name>/    v8: the macro's stored view (view.json, w0.png …, report.txt)

Build and test:

```
sh tests/run_script_tests.sh && sh build.sh
```

The star's row `macro` is `"kind": "app"` (STAR_SWIFT rows.json). A click on it opens the app; OFF in
the window quits it.
