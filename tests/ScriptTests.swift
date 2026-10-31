// tests/ScriptTests.swift
//
// The script language alone, the port of tests/test_script.lua. A fake host writes down every click, key, sleep
// and image search it is asked for, and the test reads the log. Run: sh tests/run_script_tests.sh

import Foundation

var fails = 0, passed = 0
func ok(_ cond: Bool, _ what: String) {
    if cond { passed += 1; print("ok   " + what) } else { fails += 1; print("FAIL " + what) }
}
let f = Script.fmtNum

// THE FAKE HOST: a log of everything, a clock that Sleep advances, a screen with one picture on it.
class FakeHost: ScriptHost {
    var log: [String] = [], t = 0.0, clip = "", said: [String] = []
    var images: [String: ImageHit] = ["button.png": ImageHit(x: 100, y: 200, w: 40, h: 20, score: 1)]
    var sleeps0 = 0
    func put(_ s: String) { log.append(s) }
    func now() -> Double { t }
    func sleep(_ sec: Double) throws { t += sec; if sec > 0 { put("sleep " + f(sec)) } else { sleeps0 += 1 } }
    func mouseMove(_ x: Double, _ y: Double) throws { put("move \(f(x)),\(f(y))") }
    func click(_ button: String, _ x: Double?, _ y: Double?, _ times: Int, _ mods: [String]) throws {
        put("click " + button + (x != nil ? " \(f(x!)),\(f(y!))" : "") + (times > 1 ? " x\(times)" : "") + (mods.isEmpty ? "" : " " + mods.joined(separator: "+")))
    }
    func buttonDownUp(_ button: String, _ down: Bool, _ x: Double?, _ y: Double?, _ mods: [String]) throws { put(button + (down ? " down" : " up")) }
    func drag(_ button: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ mods: [String]) throws {
        put("drag \(f(x1)),\(f(y1))>\(f(x2)),\(f(y2))")
    }
    func mousePos() -> (Int, Int) { (7, 9) }
    func key(_ mods: [String], _ name: String) throws { put("key " + (mods.isEmpty ? "" : mods.joined(separator: "+") + "+") + name) }
    func keyDownUp(_ name: String, _ down: Bool, _ mods: [String]) throws { put("key " + name + (down ? " down" : " up")) }
    func type(_ text: String) throws { put("type " + text) }
    func wheel(_ dir: String, _ times: Int, _ mods: [String]) throws { put("wheel \(dir) \(times)") }
    func imageSearch(_ file: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) throws -> ImageHit? {
        let r = images[file]; put((r != nil ? "found " : "missed ") + file); return r
    }
    func searchHold(_ on: Bool) {}
    func pixel(_ x: Double, _ y: Double) -> String { "0x112233" }
    func say(_ text: String, _ long: Bool) { said.append(text) }
    func run(_ what: String) { put("run " + what) }
    func activate(_ title: String) -> Bool { put("activate " + title); return title == "Chrome" }
    func winExists(_ title: String) -> Bool { title == "Chrome" }
    func clipboard() -> String { clip }
    func setClipboard(_ v: String) { clip = v }
    func screen() -> (Double, Double) { (1440, 900) }
    func fileExist(_ p: String) -> Bool { false }
    func fileRead(_ p: String) -> String { "" }
    func fileAppend(_ text: String, _ p: String) {}
    func menuSelect(_ title: String, _ path: [String]) -> Bool { log.append("menu " + path.joined(separator: ">")); return true }
    func winGetPos(_ title: String) -> (Double, Double, Double, Double)? { (0, 25, 2560, 1415) }
}

func run(_ src: String, _ host: FakeHost = FakeHost()) -> (Bool, String, FakeHost) {
    switch Script.parse(src) {
    case .failure(let e): return (false, "parse: " + e.text, host)
    case .success(let prog):
        let r = Script.run(prog, host: host, speed: 1)
        return (r.ok, r.message ?? "nil", host)
    }
}
func logs(_ h: FakeHost) -> String { h.log.joined(separator: " | ") }
func said(_ h: FakeHost, _ i: Int) -> String { i < h.said.count ? h.said[i] : "nil" }

@main struct Tests {
    static func main() {
        // expressions and variables
        var (r, m, h) = run("""
        x := 2 + 3 * 4
        y := (2 + 3) * 4
        s := "a" . "b"
        t := "c" "d"
        u := x = 14 ? "yes" : "no"
        v := 10 // 3
        w := 2 ** 3
        n := -x + 1
        z := "5" + "6"
        MsgBox x " " y " " s " " t " " u " " v " " w " " n " " z

        """)
        ok(r, "expressions run: " + m)
        ok(said(h, 0) == "14 20 ab cd yes 3 8 -13 11", "arithmetic, concat, ternary, floor division: " + said(h, 0))

        // if, else if, else; comparisons; and/or/not
        (r, m, h) = run("""
        a := 5
        if a > 10 {
            MsgBox "big"
        } else if a > 3 {
            MsgBox "middle"
        } else {
            MsgBox "small"
        }
        if (a = 5 and not a = 6)
            MsgBox "one-liner"
        if "abc" = "ABC"
            MsgBox "case-insensitive ="
        if "abc" == "ABC"
            MsgBox "wrong"
        else
            MsgBox "case-sensitive =="

        """)
        ok(r && h.said == ["middle", "one-liner", "case-insensitive =", "case-sensitive =="],
           "if / else if / else, one-liners, string comparison: " + h.said.joined(separator: ","))

        // loops: Loop n with A_Index, While, Break, Continue, Loop until, infinite Loop with Break
        (r, m, h) = run("""
        total := 0
        Loop 5 {
            if A_Index = 3
                Continue
            total += A_Index
        }
        i := 0
        While i < 10 {
            i++
            if i = 4
                Break
        }
        k := 0
        Loop {
            k += 1
            if k >= 7
                Break
        }
        j := 0
        Loop
            j++
        Until j = 3
        MsgBox total " " i " " k " " j

        """)
        ok(r && said(h, 0) == "12 4 7 3", "Loop, While, Break, Continue, Until: \(m) " + said(h, 0))

        // functions, return, by-reference, globals, recursion
        (r, m, h) = run("""
        counter := 0
        Add(a, b := 10) {
            return a + b
        }
        Bump(&v) {
            v += 1
        }
        Count() {
            global counter
            counter += 1
        }
        Fact(n) {
            if n <= 1
                return 1
            return n * Fact(n - 1)
        }
        x := 1
        Bump(&x)
        Bump(&x)
        Count()
        Count()
        MsgBox Add(2, 3) " " Add(5) " " x " " counter " " Fact(5)

        """)
        ok(r && said(h, 0) == "5 15 3 2 120", "functions, defaults, &ref, global, recursion: \(m) " + said(h, 0))

        // arrays and maps, For
        (r, m, h) = run("""
        arr := [10, 20, 30]
        arr.Push(40)
        sum := 0
        For i, v in arr
            sum += v
        m := Map("a", 1, "b", 2)
        m["c"] := 3
        keys := ""
        For k, v in m
            keys .= k
        last := arr.Pop()
        o := {name: "Marko", age: 3}
        MsgBox arr.Length " " sum " " keys " " m.Count " " last " " arr[1] " " o["name"] " " m.Has("b") " " m.Has("z")

        """)
        ok(r && said(h, 0) == "3 100 abc 3 40 10 Marko 1 0", "arrays, maps, For, Push/Pop, object literal: \(m) " + said(h, 0))

        // string functions
        (r, m, h) = run("""
        s := "Hello, World"
        MsgBox StrLen(s) " " SubStr(s, 1, 5) " " SubStr(s, -5) " " InStr(s, "World") " " StrReplace(s, "l", "L") " " StrUpper("ab") " " Trim("  x  ") " " Format("{1}-{2}", 7, "q") " " Round(3.14159, 2) " " Mod(10, 3) " " Max(1, 9, 4)
        parts := StrSplit("a,b,c", ",")
        MsgBox parts.Length " " parts[2]

        """)
        ok(r && said(h, 0) == "12 Hello World 8 HeLLo, WorLd AB x 7-q 3.14 1 9", "string and number functions: \(m) " + said(h, 0))
        ok(said(h, 1) == "3 b", "StrSplit: " + said(h, 1))

        // mouse and keys through the host
        (r, m, h) = run("""
        MouseMove 10, 20
        Click 30, 40
        Click 30, 40, 2
        Click 50, 60, "Right"
        MouseClick "Left", 70, 80
        MouseClickDrag "Left", 1, 2, 3, 4
        Sleep 500
        Send "hi"
        Send "^c"
        Send "!{Tab}"
        Send "+{Enter}"
        Send "#v"
        Send "{Enter 2}"
        Send "{Ctrl down}a{Ctrl up}"
        Send "{WheelDown 3}"
        Send "A"
        Send "{!}{^}"
        SendText "^c"
        MouseGetPos &mx, &my
        MsgBox mx "," my

        """)
        ok(r, "mouse and key commands run: " + m)
        var L = logs(h)
        ok(L.contains("move 10,20") && L.contains("click left 30,40 |") && L.contains("click left 30,40 x2") && L.contains("click right 50,60"), "Click forms: " + L)
        ok(L.contains("click left 70,80") && L.contains("drag 1,2>3,4"), "MouseClick and MouseClickDrag")
        ok(L.contains("sleep 0.5"), "Sleep 500 is half a second")
        ok(L.contains("type hi") && L.contains("key ctrl+c") && L.contains("key alt+tab") && L.contains("key shift+return") && L.contains("key cmd+v"), "Send modifiers: ^ ! + #")
        ok(L.contains("key return | key return"), "{Enter 2} presses twice")
        ok(L.contains("key ctrl+a"), "{Ctrl down}a{Ctrl up} holds ctrl")
        ok(L.contains("wheel down 3"), "{WheelDown 3}")
        ok(L.contains("type A"), "a capital on its own is typed as text")
        ok(L.contains("type !^"), "{!}{^} are literal")
        ok(L.contains("type ^c"), "SendText types raw")
        ok(said(h, 0) == "7,9", "MouseGetPos fills &x, &y: " + said(h, 0))

        // image search: found, not found, ClickImage, WaitImage with time out
        (r, m, h) = run("""
        if ImageSearch(&fx, &fy, 0, 0, 0, 0, "button.png") {
            Click fx + 20, fy + 10
        }
        if !ImageSearch(&gx, &gy, 0, 0, 0, 0, "gone.png")
            MsgBox "gone is not there"
        hit := ClickImage("button.png")
        miss := ClickImage("gone.png", 1)
        w := WaitImage("gone.png", 1)
        c := FindImage("button.png")
        MsgBox hit " " miss " " w " " c[1] "," c[2] " " ImageExist("button.png")

        """)
        ok(r, "image commands run: " + m)
        L = logs(h)
        ok(L.contains("found button.png | click left 120,210"), "ImageSearch top-left, then Click at an offset: " + String(L.prefix(80)))
        ok(said(h, 0) == "gone is not there", "a missing picture returns 0")
        ok(L.contains("click left 120,210 | missed gone.png"), "ClickImage clicks the centre")
        ok(said(h, 1) == "1 0 0 120,210 1", "ClickImage/WaitImage/FindImage/ImageExist results: " + said(h, 1))
        ok(h.t >= 2, "the waits took their time: \(h.t) s")

        // built-in variables, clipboard, windows, run
        (r, m, h) = run("""
        A_Clipboard := "copied"
        Run "https://example.com"
        WinActivate "Chrome"
        MsgBox A_ScreenWidth "x" A_ScreenHeight " " A_Clipboard " " WinExist("Chrome") WinExist("Nope") " " A_MouseX

        """)
        ok(r && said(h, 0) == "1440x900 copied 10 7", "A_ variables, clipboard, WinExist: \(m) " + said(h, 0))
        ok(logs(h).contains("run https://example.com | activate Chrome"), "Run and WinActivate reach the host")

        // directives and comments are harmless; hotkeys are refused; errors carry the line
        (r, m, _) = run("""
        #Requires AutoHotkey v2.0
        #SingleInstance Force
        ; a comment
        SendMode "Input"
        /* block
           comment */
        x := 1 ; trailing comment

        """)
        ok(r, "directives and comments pass: " + m)
        (r, m, _) = run("x := 1\n^r::\n")
        ok(!r && m.contains("hotkeys belong to the slots"), "a hotkey label is refused with a reason: " + m)
        (r, m, _) = run("x := 1\ny := x +\n")
        ok(!r && m.contains("line 2"), "a parse error names the line: " + m)
        (r, m, _) = run("Sleep 100\nNoSuchThing 1, 2\n")
        ok(!r && m.contains("line 2") && m.contains("NoSuchThing"), "an unknown command names the line: " + m)
        (r, m, _) = run("x := \"a\" + 1\n")
        ok(!r && m.contains("needs a number"), "text in arithmetic is refused: " + m)
        (r, m, _) = run("Loop Parse, x\n{\n}\n")
        ok(!r && m.contains("Loop Parse"), "Loop Parse says it is not here")

        // a tight loop with no Sleep still yields to the host now and then
        (r, m, h) = run("Loop 2000 {\n  x := A_Index\n}\n")
        ok(r, "2000 turns run")
        ok(h.sleeps0 > 5, "and the host was given sleep(0) \(h.sleeps0) times")

        // the stop key: a host that throws ScriptStopped ends the run, whatever it was doing
        final class StopHost: FakeHost { override func sleep(_ sec: Double) throws { if t > 1 { throw ScriptStopped() }; try super.sleep(sec) } }
        (r, m, _) = run("Loop {\n  Sleep 400\n}\n", StopHost())
        ok(!r && m == "stopped", "ScriptStopped ends a Loop with no end: " + m)
        (r, m, _) = run("Loop {\n  x := 1\n}\n", { let s = StopHost(); s.t = 2; return s }())
        ok(!r && m == "stopped", "and a loop with no Sleep at all: " + m)

        // ExitApp stops the script
        (r, m, h) = run("MsgBox \"one\"\nExitApp\nMsgBox \"two\"\n")
        ok(r && h.said.count == 1, "ExitApp stops: \(h.said.count) said")

        // FROM EVENTS: a recording becomes a script
        let NAMES: [Int: String] = [0: "a", 1: "s", 8: "c", 36: "return", 48: "tab", 9: "v", 49: "space"]
        func E(_ t: Double, _ k: String, x: Double? = nil, y: Double? = nil, code: Int? = nil, mods: [String] = [], dy: Double? = nil, dx: Double? = nil) -> RecEvent {
            RecEvent(kind: k, t: t, x: x, y: y, code: code, mods: mods, dx: dx, dy: dy)
        }
        let rec: [RecEvent] = [
            E(0.00, "mouseMoved", x: 1, y: 1),
            E(0.50, "leftMouseDown", x: 100, y: 200),
            E(0.58, "leftMouseUp", x: 100, y: 200),
            E(1.00, "keyDown", code: 8, mods: ["cmd"]),
            E(1.05, "keyUp", code: 8, mods: ["cmd"]),
            E(1.50, "keyDown", code: 0),
            E(1.55, "keyUp", code: 0),
            E(1.60, "keyDown", code: 1, mods: ["shift"]),
            E(1.65, "keyUp", code: 1, mods: ["shift"]),
            E(1.70, "keyDown", code: 49),
            E(1.75, "keyUp", code: 49),
            E(1.80, "keyDown", code: 36),
            E(1.85, "keyUp", code: 36),
            E(2.50, "leftMouseDown", x: 300, y: 300),
            E(2.60, "leftMouseDragged", x: 350, y: 320),
            E(2.70, "leftMouseUp", x: 400, y: 340),
            E(3.00, "rightMouseDown", x: 50, y: 60),
            E(3.05, "rightMouseUp", x: 50, y: 60),
            E(3.50, "leftMouseDown", x: 10, y: 10),
            E(3.55, "leftMouseUp", x: 10, y: 10),
            E(3.65, "leftMouseDown", x: 10, y: 10),
            E(3.70, "leftMouseUp", x: 10, y: 10),
            E(4.00, "scrollWheel", x: 500, y: 500, dy: -95, dx: 0),
            E(4.10, "scrollWheel", x: 500, y: 500, dy: -30, dx: 0),
            E(4.50, "leftMouseDown", x: 20, y: 20, mods: ["shift"]),
            E(4.55, "leftMouseUp", x: 20, y: 20, mods: ["shift"]),
        ]
        let text = Script.fromEvents(rec, keyNames: NAMES, header: ["test macro"])
        print(text)
        ok(text.contains("; test macro\nSleep 500\nClick 100, 200\n"), "a click with its wait before it")
        ok(text.contains("Send \"#c\""), "cmd+c becomes Send \"#c\"")
        ok(text.contains("Send \"aS {Enter}\""), "typed text joins, shift makes a capital, Enter is a key")
        ok(text.contains("MouseClickDrag \"Left\", 300, 300, 400, 340"), "a drag")
        ok(text.contains("Click 50, 60, \"Right\""), "a right click")
        ok(text.contains("Click 10, 10, 2"), "a double click")
        ok(text.contains("MouseMove 500, 500\nSend \"{WheelDown 4}\""), "two scrolls join into one wheel")
        ok(text.contains("Send \"{Shift down}\"\nClick 20, 20\nSend \"{Shift up}\""), "a shift-click holds shift around the click")
        // and the script it made runs
        (r, m, h) = run(text)
        ok(r, "the generated script runs: " + m)
        ok(logs(h).contains("click left 100,200 | sleep 0.42 | key cmd+c"), "and does the same things: " + String(logs(h).prefix(60)))
        ok(logs(h).contains("click left 20,20 shift"), "shift-click plays with shift held")

        // the recordings on disk decode as they are (the Lua recorder's JSON)
        let json = #"{"version":1,"events":[{"y":334.0,"kind":"mouseMoved","x":498.9,"mods":[],"t":0.72},{"kind":"keyDown","code":8.0,"mods":{},"t":1}]}"#
        struct File: Codable { var events: [RecEvent] }
        let decoded = try? JSONDecoder().decode(File.self, from: Data(json.utf8))
        ok(decoded?.events.count == 2 && decoded?.events[1].code == 8 && decoded?.events[1].mods == [], "a recording's JSON decodes, {} mods and 8.0 codes too")

        // the Send parser alone, and the escapes the recorder writes
        let acts = (try? Script.parseSend("{Click 100 200}")) ?? []
        ok(acts.count == 1 && acts[0].x == 100 && acts[0].y == 200 && acts[0].times == 1, "{Click 100 200} clicks once at 100, 200")
        ok(Script.strEscape("a\"b`c\nd") == "a`\"b``c`nd", "strEscape: " + Script.strEscape("a\"b`c\nd"))
        (r, m, h) = run("Send \"" + Script.sendEscape("50% ^ off!") + "\"\n")
        ok(r && logs(h) == "type 50% ^ off!", "sendEscape round-trips through Send: " + logs(h))
        do {   // v6: MenuSelect and WinGetPos
            let (r, _, h) = run("MenuSelect \"DaVinci Resolve\", , \"Fairlight\", \"Presets Library\"\nWinGetPos &x, &y, &w, &h, \"DaVinci Resolve\"\nif (y != 25 || w != 2560)\n    throw")
            ok(r && h.log.contains("menu Fairlight>Presets Library"), "MenuSelect walks the path, WinGetPos fills x y w h")
        }
        ok(Script.commands.count == 58 && Script.commands[0].name == "Click", "the command list for the editor: \(Script.commands.count)")

        print(fails == 0 ? "\n\(passed) checks passed" : "\n\(fails) FAILED, \(passed) passed")
        exit(fails == 0 ? 0 : 1)
    }
}
