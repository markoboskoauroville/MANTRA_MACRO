; Macro Recorder script (v21, 9.11.2026), ADAPTIVE: no screen coordinates anywhere. Every control is found by its label with Apple Vision OCR
; (FindText / ClickText / WaitText in "window:Google Chrome") so window position, window size and screen can change; every step retries with
; WaitText and ends by reading back what it set. No AI or model calls inside. Rules for imgtoimg.ai (Marko's paid account): never GPT Image,
; lowest resolution (1k), Outputs 1, read the price first; only the Generate press costs credits and needs "spend ask" APPROVE.
; WRITTEN, NOT RUN: test only after Marko says "done" (no mouse use while he works), one macro at a time, then `macro recalibrate`.
; imgtoimg-open: open https://imgtoimg.ai/ in Chrome (profile marko.bosko@gmail.com) and wait until the form shows its labels. Free.
Run "open -a 'Google Chrome' https://imgtoimg.ai/"
ok := 0
Loop 6 {
    if WaitText("Prompt", 4, "window:Google Chrome") and WaitText("Resolution", 2, "window:Google Chrome") {
        ok := 1
        break
    }
}
if !ok {
    MsgBox "imgtoimg-open: the form (Prompt, Resolution) did not appear"
    Exit
}
MsgBox "imgtoimg-open: page is open, Prompt and Resolution found"
