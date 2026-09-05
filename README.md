# MANTRA_MACRO — the macro recorder

**Records what Marko does, plays it back, ten slots on the digit keys, every key his own.
Started only from the double star menu.**

Marko's request, 4.9.2026: "It's very simple. It records everything I'm doing and repeating.
Control+Option+Command+R records, Control+Option+Command+P plays. When it's checked, it works."

And 5.9.2026: "Open macros folder is the top item. Settings as a web page, small one and big one
like the other apps. Custom keyboard shortcuts for every action. Option 1 to 0 loads a stored macro
into the player, Control 1 to 0 runs it. I assign any macro to any slot with check marks, rename them
here or on disk, and reorder the slots in the web interface."

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

## The slots

Ten slots, in keyboard order 1 2 3 4 5 6 7 8 9 0. A macro sits in one slot at most. A new macro
lands in the first free slot by itself, so it can be played from the keyboard the moment it is
saved. On the page each slot row has ▶ (run now), ▲ ▼ (swap with the neighbour), × (empty it), and
the rows drag to reorder: dropping row A on row B moves A there and shifts the rows between.

The slots are `slots` in `settings.json`, a map from digit to macro name. A slot whose macro was
renamed or removed in the Finder shows "not in the folder" rather than pretending.

## The macros

Every `<name>.json` in `~/.mantra_macro/macros/` is a macro, whatever the name. The page lists the
folder each second: rename or drop a file there and it shows. On the page, click a name to rename it
(the file moves on disk, the slot and the player follow); tick a digit under it to put it in that
slot, tick again to take it out; the bin moves it to `~/.mantra_macro/trash/`, never deletes.

A plain record with no name is the "last recording", in the player until a macro is loaded, and
also written under `recordings/` by date. The name offered for a new macro is Croatian style,
day.month. hour.minute, like `5.9. 10.42`.

## The settings page

    http://127.0.0.1:8829

One page, two ways in, from the star menu or ⌃⌥⌘M: a small floating window (the page with `?mini`,
drawn tighter, nothing dropped) and a tab in the browser. Top to bottom: the transport with a
readout, the slots, the macros, the keys, playback (speed, delay between clicks, ignore mouse
travel), the window (open small at start, keep on top, reachable from the phone) and the folder.

The page is on this Mac only unless "reachable from the phone on this wifi" is on: it can press
keys, so it is not left open to the network by default.

## Files

    macro.lua              record, play, the keys, the slots' verbs, the star's submenu
    slots.lua              the ten slots, pure Lua, no Hammerspoon
    settings_page.lua      the page, its server on 8829, the small window
    tests/test_schedule.lua the schedule under every setting, the keys, the names. lua5.4, no Hammerspoon
    tests/test_slots.lua   assign, move, swap, rename, remove, the hand-edited file
    ~/.mantra_macro/settings.json        speed, ignoreTravel, clickDelay, keys, slots, window
    ~/.mantra_macro/macros/<name>.json   the named macros
    ~/.mantra_macro/last.json            the plain last recording
    ~/.mantra_macro/recordings/          every recording ever made, kept
    ~/.mantra_macro/trash/               what the page's bin removed

The star menu's switch is `apps/macro.lua` in MANTRA_STAR. It loads this file on a tick and stops
it on the next: keys unbound, server down, window closed. Nothing runs until the box is ticked.

Run both tests before every commit:

    lua5.4 tests/test_schedule.lua && lua5.4 tests/test_slots.lua
