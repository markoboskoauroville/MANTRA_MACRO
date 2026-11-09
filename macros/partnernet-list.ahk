; partnernet-list (Macro Recorder v19, 9.11.2026): reads the PartnerNet website list by OCR.
; The list is a box with its own scrollbar INSIDE the page: the mouse goes over it and the wheel scrolls the box, one notch
; at a time, OCR after each step, until two steps in a row show nothing new. Every read is appended to the file under
; "--- read N"; merge and check with: python3 ~/Developer/MANTRA_MACRO/tools/ocr_dedupe.py <file> (lines that are not http
; addresses, the hover tooltip and the wrapped halves are handled there). Run it on the MacBook screen (Chrome window moved
; with rectangle://execute-action?name=next-display), tab "Edit Your Website And Mobile App List" in front.
out := "/Users/markobosko/.mantra_macro/partnernet-list.txt"
Loop 2 {
    FileAppend "--- read " A_Index "`n", out
    f := FindText("Enter Your Website", "screen:2")
    if !f {
        MsgBox "partnernet-list: the website list is not on the screen"
        Exit
    }
    ax := f[1] - 92
    ay := f[2] + 45
    mx := f[1] + 50
    my := f[2] + 150
    area := "rect:" ax "," ay ",520,215"
    MouseMove mx, my
    Send "{WheelUp 30}"
    Sleep 800
    last := ""
    stale := 0
    n := 0
    while stale < 2 and n < 30 {
        t := OcrText(area)
        FileAppend t "`n--- step`n", out
        if t = last
            stale := stale + 1
        else
            stale := 0
        last := t
        Send "{WheelDown 1}"
        Sleep 800
        n := n + 1
    }
}
