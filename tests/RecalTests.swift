// RecalTests.swift (v8, 1.11.2026): app/Coords.swift alone, no app, no screen. The coordinates RECALIBRATE reads and
// writes back, and the places a point may go when its window moves or changes size.
import Foundation

var fails = 0, passed = 0
func ok(_ c: Bool, _ what: String) { if c { passed += 1; print("ok   " + what) } else { fails += 1; print("FAIL " + what) } }

@main struct Main {
    static func main() {
        let src = """
        ; test, recorded 2026-11-01 10:00:00
        Click 381, 644
        Sleep 300
        click(10, 20, "Right")
        MouseMove 5, 6
        MouseClick "Left", 70, 80, 2
        MouseClickDrag "Left", 1, 2, 3, 4
        ; Click 999, 999
        ClickImage "b.png"
        Click x, y
        """
        let p = Coords.points(src)
        ok(p.count == 6, "six literal points found (comments, ClickImage and variables left out): \(p.count)")
        ok(p.first == CoordRef(line: 2, pair: 0, x: 381, y: 644, command: "Click"), "Click 381, 644 on line 2")
        ok(p.contains { $0.line == 4 && $0.x == 10 && $0.y == 20 }, "function style click(10, 20, \"Right\")")
        ok(p.contains { $0.line == 6 && $0.x == 70 && $0.y == 80 && $0.command == "MouseClick" }, "MouseClick \"Left\", 70, 80")
        ok(p.filter { $0.line == 7 }.count == 2, "MouseClickDrag has two points")

        let out = Coords.rewrite(src, ["2:0": (501, 684), "7:1": (33.4, 44.6), "4:0": (110, 120)])
        let lines = out.components(separatedBy: "\n")
        ok(lines[1] == "Click 501, 684", "Click rewritten: \(lines[1])")
        ok(lines[3] == "click(110, 120, \"Right\")", "the rest of the line kept: \(lines[3])")
        ok(lines[6] == "MouseClickDrag \"Left\", 1, 2, 33, 45", "only the drag's end moved: \(lines[6])")
        ok(lines[7] == "; Click 999, 999" && lines[2] == "Sleep 300", "other lines untouched")

        let o = Rect(x: 100, y: 100, w: 400, h: 300)
        let moved = Coords.candidates(150, 130, old: o, new: Rect(x: 300, y: 250, w: 400, h: 300))
        ok(moved.count == 1 && moved[0].x == 350 && moved[0].y == 280, "a window that only moved: one place, by the offset")
        ok(moved[0].label.hasPrefix("moved by offset (+200, +150)"), moved[0].label)
        let resized = Coords.candidates(480, 130, old: o, new: Rect(x: 100, y: 100, w: 600, h: 300))
        ok(resized.contains { $0.x == 680 && $0.y == 130 }, "a button near the right edge stays at its distance from the right edge")
        ok(resized.contains { $0.x == 670 && $0.y == 130 }, "the scaled place is offered too")
        ok(resized.first!.x == 480, "the place kept to the left edge is tried first")

        let st = Coords.stamp(Coords.stamp(src, "a"), "b")
        let sl = st.components(separatedBy: "\n")
        ok(sl[1] == "; recalibrated b" && sl.filter { $0.hasPrefix("; recalibrated") }.count == 1 && sl[0].contains("recorded"),
           "one recalibrated line, after the recorded line")

        print(fails == 0 ? "\n\(passed) checks passed" : "\n\(fails) FAILED, \(passed) passed")
        exit(fails == 0 ? 0 : 1)
    }
}
