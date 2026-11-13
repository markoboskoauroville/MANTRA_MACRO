
v22 (9.11.2026): the LAYOUTS section is a drop-down (RECALL A LAYOUT, newest first): picking a name runs it, its Delete submenu removes one; NEW stores the windows as they are now under today's date (d.m.yyyy, a second one " 2"); `macro layout new`; a layout file whose name starts with _ is hidden from the list.

## The input lock (v24, 13.11.2026)

Every script that runs takes the input lock for its length, whoever started it (Claude, Queen, Marko): a bar under the menu
bar says `CLAUDE · 0:42 left · <macro name>` (`MACRO` when Marko started it), his mouse, scroll and keys are swallowed, and
TAKE OVER (or Escape held for one second) gives the Mac back; the macro stops at its next step ("overridden by Marko").
`BlockInput "On"` makes sure the lock is on, `BlockInput "Off"` lifts it for the rest of the run. A line `; lock-seconds: 90`
(or `MACRO_SECONDS=90 macro do ...`) sets the countdown; else it is estimated from the Sleeps and steps. Held across
several calls: `macro lock "text" [seconds]`, `macro unlock`, `macro lock-status`, `macro request "what for"`, or POST
127.0.0.1:8829 /lock /unlock /through /request, GET /status (the phone's routes).
