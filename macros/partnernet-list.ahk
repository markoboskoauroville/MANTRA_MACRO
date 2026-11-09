; partnernet-list (Macro Recorder v19, 9.11.2026): reads the website list of PartnerNet by OCR, twice, and reports duplicates.
; Open Chrome (Profile 26) on partnernet.amazon.de/home/account > Edit Your Website And Mobile App List first.
; Result: ~/.mantra_macro/partnernet-list.txt; then: python3 ~/Developer/MANTRA_MACRO/tools/ocr_dedupe.py <that file>
out := "/Users/markobosko/.mantra_macro/partnernet-list.txt"
WinActivate "Google Chrome"
Sleep 400
ClickText "Edit Your Website", 1, "window:Google Chrome"
Loop 2 {
    FileAppend "--- read`n", out
    MouseMove 1500, 600
    Send "{WheelUp 30}"
    Sleep 500
    FileAppend OcrText("window:Google Chrome") "`n", out
    Send "{WheelDown 8}"
    Sleep 600
    FileAppend OcrText("window:Google Chrome") "`n", out
}
