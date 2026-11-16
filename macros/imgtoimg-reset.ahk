; Macro Recorder script (v21, 9.11.2026), ADAPTIVE: no screen coordinates anywhere. Every control is found by its label with Apple Vision OCR
; (FindText / ClickText / WaitText in "window:Google Chrome") so window position, window size and screen can change; every step retries with
; WaitText and ends by reading back what it set. No AI or model calls inside. Rules for imgtoimg.ai (Marko's paid account): never GPT Image,
; lowest resolution (1k), Outputs 1, read the price first; only the Generate press costs credits and needs "spend ask" APPROVE.
; WRITTEN, NOT RUN: test only after Marko says "done" (no mouse use while he works), one macro at a time, then `macro recalibrate`.

; ---- the ladder (Marko, 9.11.2026): 1 Accessibility, 2 OCR, 3 picture search relative to the window; logs which level worked ----
Log(level, label) {
    FileAppend FormatTime() "  " level "  " label "`n", "/Users/markobosko/.mantra_macro/imgtoimg/steps.log"
}
Press(label) {
    if AXClick("Google Chrome", label) {
        Log("AX", label)
        return 1
    }
    if ClickText(label, 4, "window:Google Chrome") {
        Log("OCR", label)
        return 1
    }
    pic := "/Users/markobosko/.mantra_macro/imgtoimg/pics/" label ".png"
    if FileExist(pic) and ClickImage(pic, "window:Google Chrome") {
        Log("PICTURE", label)
        return 1
    }
    Log("FAILED", label)
    return 0
}
Press("Open menu")
Sleep 900
t := OcrText("window:Google Chrome")
FileAppend FormatTime() "  " t "`n---`n", "/Users/markobosko/.mantra_macro/imgtoimg/balance.log"
f := FindText("Credits", "window:Google Chrome")
; imgtoimg-reset: Marko's "stuck render" procedure (9.11.2026): a render is STUCK after 5 minutes at the same percent. Everything we generate is stored in our own storage
; (Drive), so nothing is kept on imgtoimg.ai: delete every image in My Creations (Images and Videos), then a HARD reload (Cmd+Shift+R), and start again. Free.
; Deleting is two steps on the site: the first click on a trash button turns it into "Click again to delete", the second click deletes.
; BEFORE running: check that today's results are on Drive (older ones are deleted without asking). Not for Marko's screen while he works.
OpenList(media) {
    Run "open -a 'Google Chrome' 'https://imgtoimg.ai/my/assets?media=" media "'"
    Sleep 2500
    return WaitText("My Creations", 10, "window:Google Chrome")
}
total := 0
for media in ["images", "videos"] {
    if !OpenList(media) {
        MsgBox "imgtoimg-reset: My Creations did not open (" media ")"
        Exit
    }
    Loop 200 {
        if WaitText("haven't created any", 1, "window:Google Chrome")
            break
        if !Press("Delete") {
            Sleep 800
            continue
        }
        Sleep 250
        if Press("Click again to delete")
            total := total + 1
        Sleep 600
    }
}
Send "{Cmd down}{Shift down}r{Shift up}{Cmd up}"
Sleep 3500
ok := WaitText("haven't created any", 8, "window:Google Chrome")
Log("RESET", "deleted " total " ; empty list read back: " ok)
MsgBox "imgtoimg-reset: deleted " total ", hard reloaded, empty list " (ok ? "confirmed by reading it back" : "NOT confirmed, look at the page")
