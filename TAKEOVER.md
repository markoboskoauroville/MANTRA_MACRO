# TAKEOVER: the macro recorder on a fresh Mac

1. Hammerspoon installed with Accessibility (to post keys and clicks) and Input Monitoring (to record them).
2. `git clone https://github.com/markoboskoauroville/MANTRA_MACRO ~/Developer/MANTRA_MACRO`
3. MANTRA_STAR installed as its own TAKEOVER says; its `apps/macro.lua` points at
   `~/Developer/MANTRA_MACRO/macro.lua`.
4. Open the star menu, tick Macro Recorder. ⌃⌥⌘R records, ⌃⌥⌘P plays.
5. `lua5.4 tests/test_schedule.lua` proves the schedule with no Hammerspoon at all.

Nothing starts by itself. Untick and the keys are gone.
