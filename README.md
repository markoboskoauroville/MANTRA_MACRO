# MANTRA_MACRO — the macro recorder, and AutoHotkey on the Mac

**Records what Marko does and writes it down as a script he can read and edit. Ten slots on the
digit keys, every key his own, a script editor that suggests the next command, and an eye that
finds a button on the screen from a picture of it. Started only from the double star menu.**

Marko's requests, 4.9.2026 and 5.9.2026: "It records everything I'm doing and repeating.
Control+Option+Command+R records, P plays." · "Option 1 to 0 loads a stored macro, Control 1 to 0
runs it; I assign any macro to any slot with check marks and reorder them in the web interface."
· "A script editor so the user can edit the macros himself. Copy the syntax from AutoHotkey, so the
user also learns AutoHotkey. If statements, loop statements, and all the other features." · "Load
screenshots of the buttons, so the app can click by optical recognition of the patterns on my screen."

## The keys, as they come

    ⌃⌥⌘R    record; press again to stop. A red dot with REC sits bottom right while it records.
    ⌃⌥⌘P    play what is in the player; press again to stop. A green dot with PLAY.
    ⌃⌥⌘.    stop whatever runs. A recording that is stopped this way is saved.
    ⌃⌥⌘N    new macro: a box asks the name, then it records until the record key.
    ⌃⌥⌘M    the settings window, small.
    ⌥1..⌥0  put the macro in that slot into the player.
    ⌃1..⌃0  run the macro in that slot, now.

Every one of these is changed from the settings page. The two slot chords are sets of modifiers
(⌃ ⌥ ⇧ ⌘, tick the ones you want); they must differ and each must hold at least one. A key already
in use is refused, never bound twice. "Back to the default keys" puts all of this back.

The David star in the menu bar turns red while recording and green while playing.

Note that ⌥ with a digit normally types a symbol (¡ ™ £ …). While the recorder runs, those ten
chords are its; untick it, or move loading to another chord, and they type again.

## A macro is a script

Every macro is `~/.mantra_macro/macros/<name>.ahk`, in the syntax of AutoHotkey v2. A recording is
written down as one the moment it stops:

    ; 5.9. 10.42, recorded 2026-09-05 10:42:07
    Click 381, 644
    Sleep 900
    Send "^c"
    Sleep 500
    Send "Hello{Enter}"

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

    http://127.0.0.1:8829/editor?name=<macro>

Opened from a macro's **Edit** on the settings page, from the star menu, or by "Write new" on the
page. CodeMirror with a mode for the language; as you type at the start of a line the commands are
suggested, the likely next one first (after a Click comes a Sleep, after a Sleep a Send or a Click,
after a WaitImage a Click); inside `{` the key names; inside the quotes of an image command the
pictures in the folder; elsewhere the functions, the `A_` variables and the names the script has
assigned. A panel on the right lists every command with its shape and one line of what it does; click
to insert. ⌘S saves, ⌘↩ saves and runs, Check parses without running. An error names its line and
lights it; a script that fails while running reports its line on the page too. Offline, without the
editor library, the plain text box and the panel still work.

## The eye

"Snap button" on the settings page starts the system's own cross-hair: drag over a button, and
`~/.mantra_macro/images/<name>.png` is there. In a script, `ClickImage "name.png"` finds it on the
screen and clicks its centre; `WaitImage "name.png", 10` waits for it to appear; `find` beside a
picture on the page looks for it now, moves the mouse there and says the score.

**A search zone, or every screen.** Each picture either searches all screens, or a rectangle you
draw. On the page, "zone" lets you drag the zone where the button appears; "all" clears it back to
every screen; "Snap & set zone" does the two steps together, snap then zone. A zone is faster (only
that rectangle is shot) and cannot be fooled by something similar elsewhere. Zones live in
`settings.json` beside the picture's name.

**A spinner while it looks.** A small turning spinner sits bottom right with "searching for a
pattern" and goes when the search ends. It can turn because the search does not block: each region is
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

## The settings page

    http://127.0.0.1:8829

One page, two ways in, from the star menu or ⌃⌥⌘M: a small floating window (the page with `?mini`,
drawn tighter, nothing dropped) and a tab in the browser. Top to bottom: the transport with a readout,
the slots, the macros (rename by clicking the name, a digit check mark per slot, Edit, the bin), the
pictures, the keys, playback (speed divides every Sleep; delay between clicks puts them in one
rhythm), the window (open small at start, keep on top, reachable from the phone) and the folder.

The page is on this Mac only unless "reachable from the phone on this wifi" is on: it can press keys,
so it is not left open to the network by default.

## Files

    macro.lua              record, the host the language runs on, keys, slots, the star's submenu
    script.lua             the language: lexer, parser, interpreter, Send strings, recording to script. Pure Lua
    slots.lua              the ten slots. Pure Lua
    settings_page.lua      the page, its server on 8829, the small window, the routes
    editor_page.lua        the script editor and the documentation page
    find.py                the eye: a picture found on a screen shot, with OpenCV
    docs/SCRIPT.md         the language, as served at /docs
    tests/test_schedule.lua the schedule, the keys, the names. lua5.4, no Hammerspoon
    tests/test_slots.lua   assign, move, swap, rename, remove, the hand-edited file
    tests/test_script.lua  the language against a fake host: every statement, Send, pictures, a recording as a script
    ~/.mantra_macro/settings.json   speed, clickDelay, keys, slots, window
    ~/.mantra_macro/macros/         the macros, <name>.ahk
    ~/.mantra_macro/images/         the pictures
    ~/.mantra_macro/last.ahk        the plain last recording
    ~/.mantra_macro/recordings/     the raw events of every recording, kept
    ~/.mantra_macro/trash/          whatever the page's bin removed

The star menu's switch is `apps/macro.lua` in MANTRA_STAR. It loads this file on a tick and stops it
on the next: keys unbound, server down, window closed. Nothing runs until the box is ticked.

Run the three tests before every commit:

    lua5.4 tests/test_schedule.lua && lua5.4 tests/test_slots.lua && lua5.4 tests/test_script.lua
