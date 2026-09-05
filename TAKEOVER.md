# TAKEOVER: the macro recorder on a fresh Mac

1. Hammerspoon installed with Accessibility (to post keys and clicks), Input Monitoring (to record
   them) and Screen Recording (to look for pictures).
2. `git clone https://github.com/markoboskoauroville/MANTRA_MACRO ~/Developer/MANTRA_MACRO`
3. MANTRA_STAR installed as its own TAKEOVER says; its `apps/macro.lua` points at
   `~/Developer/MANTRA_MACRO/macro.lua`. The Lua files here find each other by their own folder.
4. Python 3 with OpenCV for the eye: `python3 -c "import cv2"` must work. The recorder uses
   `~/.pyenv/versions/3.10.14/bin/python3` when it is there, else `python3` on the path.
   `pip install opencv-python-headless numpy` if it is missing. Without it, ClickImage says so and
   returns 0; everything else works.
5. Open the star menu, tick Macro Recorder. The small settings window opens (switch that off on the
   page if unwanted). ⌃⌥⌘R records, ⌃⌥⌘P plays, ⌥digit loads a slot, ⌃digit runs it, ⌃⌥⌘M the page.
6. `lua5.4 tests/test_schedule.lua && lua5.4 tests/test_slots.lua && lua5.4 tests/test_script.lua`
   proves the schedule, the keys, the slots and the whole language with no Hammerspoon at all.
7. Port 8829 is the page. If something else holds it, the readout says so; change PORT in
   settings_page.lua. The editor loads CodeMirror from cdnjs; offline, the plain box works.

Nothing starts by itself. Untick and the keys, the server and the window are gone.
State is under `~/.mantra_macro/`; copy that folder to carry the macros, the pictures and the slots
to another Mac.
