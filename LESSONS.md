# LESSONS — the macro recorder

1. **Carry the modifiers on each event, do not record flagsChanged.** A shift-click is a mouse
   event with `shift` in its mods; a ⌘C is a key event with `cmd`. Recording the modifier keys
   themselves would also record the ⌃⌥⌘ he pressed to stop, and play it back.

2. **The hotkey is seen by the eventtap.** The tap sits ahead of the hotkey, so the R that starts
   the recording arrives inside the recording. Any record, play or stop chord, or its key within
   the first second, is dropped, and any trailing one is cut off at the end. Now that the keys are
   his to change, this check reads the settings, never a constant.

3. **Rhythm must not break order.** Putting every click a fixed delay after the last one and leaving
   the events between them where they were would let a key land after the click it preceded. So the
   span between two clicks is scaled as a whole: the inner events keep their proportions and the
   order is exactly the recorded order. `M.schedule` is pure and tested for this.

4. **Skip autorepeat on record.** A held key repeats by itself when the keyDown is posted; recording
   every repeat and posting them all doubles the letters.

5. **The status is a badge, bottom right, not an alert.** His rule from the keyboard: never mid
   screen, never a fright. One canvas, made once, moved to the screen the pointer is on. A badge
   that cannot be drawn (no screen, a test stub) is caught, so a word can never break the action
   that spoke it.

6. **The slots are a pure file.** `slots.lua` knows nothing of Hammerspoon: assign, clear, move,
   swap, rename, remove, auto-place, normalise. Every rule about the ten slots (one macro in one
   slot, a move shifts the rows between, a hand-edited file with a name twice keeps the first) is
   a line in `tests/test_slots.lua` and runs in plain lua5.4 in a blink.

7. **One chord, one thing.** A key is refused rather than bound twice, and the two slot chords must
   differ: `hs.hotkey.bind` will happily bind ⌃3 twice and only one of them fires. `usedBy` is asked
   before any key is set, including the ten digits under a new modifier set.

8. **Rebind by letting go first.** `bindKeys` always deletes every handle it made before binding
   from the settings. A changed key otherwise leaves its old chord alive.

9. **The page keeps no state.** The macros come from the folder each poll (event counts cached by
   mtime), the slots from the settings, the keys from the settings. A file renamed in the Finder
   shows on the next poll; a slot that still names the old file says "not in the folder". A rename
   in progress is the one thing not redrawn under the cursor.

10. **Localhost by default.** This page can press keys and click. It listens on 127.0.0.1 unless
    "reachable from the phone" is on, and the server is rebuilt on that switch because the
    interface cannot be changed under a running one.

11. **`hs -c` and a posted keystroke do not mix.** Testing the key capture by posting a chord
    through `hs -c 'hs.eventtap.keyStroke(...)'` hung the IPC client, and every later `hs -c` with
    it, until that client process was killed. The capture itself worked. Test captures with a real
    key, or call `MACRO.setKey` directly.

12. **The stop key is ⌃⌥⌘. (full stop).** Every letter near R and P was a word he might want; the
    full stop is the one key on the row that says stop and types nothing worth keeping.

13. **The language is a pure file with a host.** `script.lua` never mentions `hs`. Every click,
    key, wait and picture goes through a host table; Hammerspoon gives the real one, the test a
    fake that writes a log. Sixty checks run in plain lua5.4 in a blink, and the same code runs
    the Mac.

14. **Sleep yields, it never blocks.** The interpreter runs in a coroutine; `host.sleep` yields
    the seconds and a timer resumes it. The stop key drops the coroutine. Every four hundred
    statements the interpreter yields on its own, so a loop with no Sleep can be stopped and never
    freezes Hammerspoon. Lua 5.4 lets a coroutine yield across `pcall`, which the interpreter
    leans on for Break, Continue and Return.

15. **Command arguments end at the line.** Inside brackets a newline is nothing; in command style
    (`Click 100, 200`) the line is the statement. Skipping newlines after every argument, as one
    does inside brackets, ate the next line and reported "unexpected 'Click'" at the wrong place.

16. **`a.b` is a member, `a . b` is a join.** AutoHotkey's own rule, and the lexer keeps it by
    noting whether the dot had space on both sides. Two values side by side (`"x" y`) also join.

17. **`hs.image:size()` answers in points.** The PNG a Retina screen shot writes is twice as wide.
    Trusting `size()` for the scale put every found picture at twice its coordinates; find.py now
    reports the screen image's pixel width and the scale is pixels over points.

18. **A capital on its own is text.** `Send "A"` is typed, not pressed as shift+a, because
    `hs.eventtap.keyStrokes` handles any character including ones with no key. With a modifier
    (`Send "^A"`) or a held one (`{Shift down}`), it is a key with shift.

19. **The recorder writes what can be read.** Mouse travel is dropped (a click carries its own
    place), a drag is one line, a double click is `Click x, y, 2`, keys typed within a second and
    a half join into one `Send "…"`, Enter and Tab ride inside it, a shift-click is wrapped in
    `{Shift down}` and `{Shift up}`, scrolls within a third of a second join into one wheel.

20. **`timeout` does not exist on macOS.** `timeout 10 hs -c ...` silently ran nothing and the
    "reload" it wrapped never happened; the old server answered `/health` and the new routes were
    "missing". Check the command exists before trusting its silence.

21. **Never serve binary through hs.httpserver.** The response body is turned into a UTF-8
    NSString; a PNG's bytes are not valid UTF-8, the conversion returns nil, and the server
    crashes Hammerspoon with a bad access in objc_retain — the whole app went down and the star
    menu with it (5.9.2026). Pictures now go out as base64 inside a JSON string (always valid
    UTF-8) and the page shows them with a `data:` URI, cached so each is fetched once. Every
    httpserver response in this project is text: HTML, JSON, plain.

22. **Catch every throw before it reaches the server.** The httpserver callback is now wrapped in
    pcall: a Lua error out of the handler answers 500 rather than propagating into the C server,
    which can also crash the app. One bad request must never kill the machine.
