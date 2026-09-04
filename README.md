# MANTRA_MACRO — the macro recorder

**Records what Marko does, plays it back. Started only from the double star menu.**

Marko's request, 4.9.2026: "It's very simple. It records everything I'm doing and repeating.
Control+Option+Command+R records, Control+Option+Command+P plays. When it's checked, it works."

## Keys

    ⌃⌥⌘R    start recording; press again to stop. A red dot with REC sits bottom right while it records.
    ⌃⌥⌘P    play the last recording; press again to stop. A green dot with PLAY sits bottom right.

## Settings, under the star menu as "Macro Recorder settings"

- **Speed** 0.5x, 1x, 2x, 4x, 8x. Every gap divided by the speed.
- **Ignore mouse travel** drops the mouse movement between clicks; the pointer jumps straight to
  where each click happened. Drags are kept, they are the selection, not the travel.
- **Delay between clicks** as recorded, 0.25 s, 0.5 s, 1 s, 2 s. Above zero, every click lands
  exactly that long after the one before, so all the clicks are in one rhythm. What happened between
  two clicks is fitted into the gap in proportion, in the same order.

Settings are kept in `~/.mantra_macro/settings.json`.

## Files

    macro.lua                  the recorder: one eventtap in, one timer out, the schedule in between
    tests/test_schedule.lua    plain lua5.4, no Hammerspoon: the schedule under every setting
    ~/.mantra_macro/last.json                 what P plays
    ~/.mantra_macro/recordings/<date>.json    every recording ever made, kept

The star menu's switch is `apps/macro.lua` in MANTRA_STAR. It loads this file on a tick and unbinds
the keys on the next tick. Nothing runs until the box is ticked.

Run the test before every commit: `lua5.4 tests/test_schedule.lua`
