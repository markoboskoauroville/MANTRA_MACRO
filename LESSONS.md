# LESSONS — the macro recorder

1. **Carry the modifiers on each event, do not record flagsChanged.** A shift-click is a mouse
   event with `shift` in its mods; a ⌘C is a key event with `cmd`. Recording the modifier keys
   themselves would also record the ⌃⌥⌘ he pressed to stop, and play it back.

2. **The hotkey is seen by the eventtap.** The tap sits ahead of the hotkey, so the R that starts
   the recording arrives inside the recording. Any R or P with all three modifiers, or within the
   first second, is dropped, and any trailing R or P is cut off at the end.

3. **Rhythm must not break order.** Putting every click a fixed delay after the last one and leaving
   the events between them where they were would let a key land after the click it preceded. So the
   span between two clicks is scaled as a whole: the inner events keep their proportions and the
   order is exactly the recorded order. `M.schedule` is pure and tested for this.

4. **Skip autorepeat on record.** A held key repeats by itself when the keyDown is posted; recording
   every repeat and posting them all doubles the letters.

5. **The status is a badge, bottom right, not an alert.** His rule from the keyboard: never mid
   screen, never a fright. One canvas, made once, moved to the screen the pointer is on.
