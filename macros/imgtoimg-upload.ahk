; Macro Recorder script (v21, 9.11.2026), ADAPTIVE: no screen coordinates anywhere. Every control is found by its label with Apple Vision OCR
; (FindText / ClickText / WaitText in "window:Google Chrome") so window position, window size and screen can change; every step retries with
; WaitText and ends by reading back what it set. No AI or model calls inside. Rules for imgtoimg.ai (Marko's paid account): never GPT Image,
; lowest resolution (1k), Outputs 1, read the price first; only the Generate press costs credits and needs "spend ask" APPROVE.
; WRITTEN, NOT RUN: test only after Marko says "done" (no mouse use while he works), one macro at a time, then `macro recalibrate`.
; imgtoimg-upload: attaches the images listed in ~/.mantra_macro/imgtoimg/files.txt (one absolute path per line, image 1..N order) through the macOS file dialog (Go to folder). Free.
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
list := FileRead("/Users/markobosko/.mantra_macro/imgtoimg/files.txt")
n := 0
Loop Parse, list, "`n", "`r" {
    if A_LoopField = ""
        continue
    if !Press("Upload Image") and !Press("Image Upload") {
        MsgBox "imgtoimg-upload: no upload control found"
        Exit
    }
    if !WaitText("Open", 6, "screen") {
        MsgBox "imgtoimg-upload: the file dialog did not open"
        Exit
    }
    Send "{Cmd down}{Shift down}g{Shift up}{Cmd up}"
    Sleep 600
    Send A_LoopField
    Sleep 300
    Send "{Return}"
    Sleep 500
    Send "{Return}"
    Sleep 1800
    n := n + 1
}
MsgBox "imgtoimg-upload: " n " file(s) sent through the dialog; check the thumbnails"
