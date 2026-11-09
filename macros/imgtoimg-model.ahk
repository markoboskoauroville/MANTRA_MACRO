; Macro Recorder script (v21, 9.11.2026), ADAPTIVE: no screen coordinates anywhere. Every control is found by its label with Apple Vision OCR
; (FindText / ClickText / WaitText in "window:Google Chrome") so window position, window size and screen can change; every step retries with
; WaitText and ends by reading back what it set. No AI or model calls inside. Rules for imgtoimg.ai (Marko's paid account): never GPT Image,
; lowest resolution (1k), Outputs 1, read the price first; only the Generate press costs credits and needs "spend ask" APPROVE.
; WRITTEN, NOT RUN: test only after Marko says "done" (no mouse use while he works), one macro at a time, then `macro recalibrate`.
; imgtoimg-model: the model named in ~/.mantra_macro/imgtoimg/model.txt (Nano Banana | Nano Banana 2 | Nano Banana Pro). GPT Image and Max are refused. Free.
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
name := Trim(FileRead("/Users/markobosko/.mantra_macro/imgtoimg/model.txt"))
if name = "" or InStr(name, "GPT") or InStr(name, "Max") {
    MsgBox "imgtoimg-model: refused ('" name "'); use Nano Banana, Nano Banana 2 or Nano Banana Pro"
    Exit
}
done := 0
Loop 3 {
    Press("Model")
    Sleep 600
    Press(name)
    Sleep 800
    t := OcrText("window:Google Chrome")
    if InStr(t, name) and !InStr(t, "GPT Image 2 6+") {
        done := 1
        break
    }
}
if !done {
    MsgBox "imgtoimg-model: could not set or read back '" name "'"
    Exit
}
MsgBox "imgtoimg-model: set and read back: " name
