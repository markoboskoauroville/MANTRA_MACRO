; F1 Claude dictation (Marko, 3.11.2026): F1 brings the Claude desktop app to the front and presses F2,
; Speechify's hotkey, so the dictation lands in Claude's message box. Its key and on/off come from the
; Elevate Media Project Monitor's F1 switch (macro trigger "F1 Claude dictation" f1 on|off).
WinActivate "Claude"
Sleep 150
Send "{F2}"
