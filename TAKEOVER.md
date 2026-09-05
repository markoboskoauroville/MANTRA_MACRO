# TAKEOVER: the macro recorder on a fresh Mac

1. Hammerspoon installed with Accessibility (to post keys and clicks) and Input Monitoring (to record them).
2. `git clone https://github.com/markoboskoauroville/MANTRA_MACRO ~/Developer/MANTRA_MACRO`
3. MANTRA_STAR installed as its own TAKEOVER says; its `apps/macro.lua` points at
   `~/Developer/MANTRA_MACRO/macro.lua`. The Lua files here find each other by their own folder.
4. Open the star menu, tick Macro Recorder. The small settings window opens (switch that off on the
   page if unwanted). ⌃⌥⌘R records, ⌃⌥⌘P plays, ⌥digit loads a slot, ⌃digit runs it, ⌃⌥⌘M the page.
5. `lua5.4 tests/test_schedule.lua && lua5.4 tests/test_slots.lua` proves the schedule, the keys,
   the names and the slots with no Hammerspoon at all.
6. Port 8829 is the page. If something else holds it, the readout says so; change PORT in
   settings_page.lua.

Nothing starts by itself. Untick and the keys, the server and the window are gone.
State is under `~/.mantra_macro/`; copy that folder to carry the macros and the slots to another Mac.
