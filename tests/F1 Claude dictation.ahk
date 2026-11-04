; F1 Claude dictation (Marko, 3.11.2026): F1 brings the Claude desktop app to the front, clicks into its prompt box,
; and presses F2, Speechify's hotkey, so the dictation lands there. Its key and on/off come from the Elevate Media
; Project Monitor's F1 switch (macro trigger "F1 Claude dictation" f1 on|off).
; 4.11.2026 (Marko: "it needs to detect if I'm in ... iTerm"): iTerm in front = he works there, the dictation goes
; into iTerm where the cursor is; anything else (iTerm only in the background too) = the Claude app, as before.
; The line at the bottom of the screen says where it goes.
if WinActive("iTerm") {
    ToolTip "F1 → iTerm"
    Send "{F2}"
    ExitApp
}
ToolTip "F1 → Claude"
WinActivate "Claude"
Sleep 150
AXClick "Claude", "Prompt"
Sleep 80
; 4.11.2026 (Marko: "the next text should go at the end of the previous text. Now it just jumps to the beginning"):
; the click puts the caret where it lands; Command+Down sends it to the end of the text already in the box
Send "#{Down}"
Sleep 60
Send "{F2}"
