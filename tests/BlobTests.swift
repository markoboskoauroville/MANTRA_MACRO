// BlobTests.swift: the pure rules of the text blob (v32): duration, wrapping and truncation, the stack, replace/clear by id,
// the "lock released, blob only if no lock follows" rule, the placement on the portrait BenQ + MacBook layout, and the pin that
// the blob window can never become key or main. Built and run by the GitHub workflow (tests/run_blob_tests.sh).
import AppKit

var failures = 0
var passes = 0
func check(_ c: Bool, _ label: String) { if c { passes += 1; print("ok   " + label) } else { failures += 1; print("FAIL " + label) } }

func item(_ id: String, _ text: String = "t", sticky: Bool = false, seconds: Double? = 8, at: Date = Date(timeIntervalSince1970: 1000)) -> BlobItem {
    BlobItem(id: id, text: text, kind: .info, sticky: sticky, seconds: sticky ? nil : seconds, shownAt: at)
}

@main struct Main {
    static func main() {
        // duration
        check(BlobRules.duration(text: "Hi", seconds: nil, sticky: false) == 6, "short text stays 6 s at least")
        check(BlobRules.duration(text: String(repeating: "x", count: 100), seconds: nil, sticky: false) == 11, "100 characters: 11 s")
        check(BlobRules.duration(text: String(repeating: "x", count: 2000), seconds: nil, sticky: false) == 30, "long text at most 30 s")
        check(BlobRules.duration(text: "Hi", seconds: 8, sticky: false) == 8, "explicit seconds as given")
        check(BlobRules.duration(text: "Hi", seconds: 0, sticky: false) == 1 && BlobRules.duration(text: "Hi", seconds: 9999, sticky: false) == 120, "explicit seconds 1 to 120")
        check(BlobRules.duration(text: "Hi", seconds: 8, sticky: true) == nil, "sticky has no end")

        // clean: plain text
        check(BlobRules.clean("  a\n\nb\t c  ") == "a b c", "line breaks and tabs become single spaces")
        check(BlobRules.clean("**bold** <b>x</b>") == "**bold** <b>x</b>", "no markup is interpreted (kept as plain text)")
        check(BlobRules.clean("\n \t") == "", "only blanks is empty")

        // wrap: 1 char = 10 pt, 100 pt per line = 10 characters
        let m: (String) -> CGFloat = { CGFloat($0.count) * 10 }
        let w1 = BlobRules.wrap("one two three", width: 100, measure: m)
        check(w1.lines == ["one two", "three"] && !w1.truncated, "wraps at word boundaries")
        let w2 = BlobRules.wrap("aaaaaaaaaaaaaaaaaaaaaaaaa", width: 100, measure: m)
        check(w2.lines == ["aaaaaaaaaa", "aaaaaaaaaa", "aaaaa"] && !w2.truncated, "a word wider than the line is broken by characters")
        let w3 = BlobRules.wrap("aaaa bbbb cccc dddd eeee ffff gggg hhhh", width: 100, measure: m)
        check(w3.lines.count == 3 && w3.truncated && w3.lines[2].hasSuffix("…"), "more than three lines: cut with an ellipsis")
        check(w3.lines.allSatisfy { m($0) <= 100 }, "every line fits the width, ellipsis included")
        check(BlobRules.wrap("You can use the computer now", width: 400, measure: m).lines == ["You can use the computer now"], "one line when it fits")

        // stack
        var st = BlobStack()
        _ = st.show(item("a")); _ = st.show(item("b")); _ = st.show(item("c"))
        check(st.items.map { $0.id } == ["c", "b", "a"], "newest on top")
        let ev = st.show(item("d"))
        check(st.items.map { $0.id } == ["d", "c", "b"] && ev == [.added("d"), .evicted("a")], "a fourth pushes the oldest out")
        let ev2 = st.show(item("c", "new text"))
        check(ev2 == [.replaced("c")] && st.items.map { $0.id } == ["d", "c", "b"] && st.items[1].text == "new text", "same id replaces in place")
        check(st.clear("c") && st.items.map { $0.id } == ["d", "b"], "clear by id removes it")
        check(!st.clear("zzz"), "clearing an unknown id says so")
        var st2 = BlobStack()
        _ = st2.show(item("s", sticky: true)); _ = st2.show(item("t", seconds: 8, at: Date(timeIntervalSince1970: 1000)))
        let gone = st2.expire(now: Date(timeIntervalSince1970: 1009))
        check(gone == ["t"] && st2.items.map { $0.id } == ["s"], "time-over blobs leave, a sticky one stays")
        check(st2.expire(now: Date(timeIntervalSince1970: 1007.5)).isEmpty, "nothing leaves before its time")
        check(st2.clearAll() == ["s"] && st2.items.isEmpty, "clear all")

        // the done gate: lock released, blob only if no lock follows within 2 s
        let t0 = Date(timeIntervalSince1970: 5000)
        var g = DoneGate()
        g.taken(at: t0); g.released(at: t0.addingTimeInterval(3))
        check(!g.poll(now: t0.addingTimeInterval(4)), "1 s after the release: not yet")
        check(g.poll(now: t0.addingTimeInterval(5.1)), "2 s after the release with no new lock: the blob is due")
        check(!g.poll(now: t0.addingTimeInterval(6)), "due only once")
        var g2 = DoneGate()
        g2.taken(at: t0); g2.released(at: t0.addingTimeInterval(3)); g2.taken(at: t0.addingTimeInterval(4))
        check(!g2.poll(now: t0.addingTimeInterval(6)), "a new lock within 2 s: no blob between locks")
        g2.released(at: t0.addingTimeInterval(8))
        check(g2.poll(now: t0.addingTimeInterval(10.5)), "after the last lock of the chain: one blob for the whole stretch")
        var g3 = DoneGate()
        g3.taken(at: t0); g3.released(at: t0.addingTimeInterval(0.5))
        check(!g3.poll(now: t0.addingTimeInterval(3)), "a half-second lock gives no blob")
        var g4 = DoneGate()
        g4.released(at: t0)
        check(!g4.poll(now: t0.addingTimeInterval(5)) && !g4.pending, "a release without a lock gives nothing")

        // placement: the portrait BenQ 1440x2560 as primary, the MacBook screen to its right
        let benq = CGRect(x: 0, y: 0, width: 1440, height: 2560), benqVis = CGRect(x: 0, y: 0, width: 1440, height: 2535)
        let mac = CGRect(x: 1440, y: 1578, width: 1512, height: 982), macVis = CGRect(x: 1440, y: 1578, width: 1512, height: 957 - 0)
        let frames = [benq, mac]
        // an AX rectangle (top-left origin of the primary) of a text field on the MacBook screen
        let ax = CGRect(x: 2000, y: 100, width: 400, height: 30)
        let k = BlobRules.appKitRect(fromAX: ax, primaryHeight: benq.height)
        check(BlobRules.screenIndex(of: k, frames: frames) == 1, "a field on the MacBook screen picks the MacBook screen")
        let ax2 = CGRect(x: 300, y: 1200, width: 400, height: 30)
        check(BlobRules.screenIndex(of: BlobRules.appKitRect(fromAX: ax2, primaryHeight: benq.height), frames: frames) == 0, "a field on the BenQ picks the BenQ")
        check(BlobRules.screenIndex(of: CGRect(x: 9000, y: 9000, width: 5, height: 5), frames: frames) == nil, "a rectangle on no screen picks none")
        let sizes = [CGSize(width: 300, height: 52), CGSize(width: 300, height: 71), CGSize(width: 300, height: 52)]
        for (vis, name) in [(macVis, "MacBook"), (benqVis, "BenQ")] {
            let f = BlobRules.frames(visible: vis, sizes: sizes)
            check(f.allSatisfy { vis.contains($0) }, name + ": every blob inside the visible frame")
            check(abs(f[0].midX - vis.midX) <= 0.5, name + ": centred")
            check(f[0].maxY == vis.maxY - 12, name + ": first blob 12 pt under the top of the visible frame (under the menu bar)")
            check(f[1].maxY <= f[0].minY && f[2].maxY <= f[1].minY, name + ": stacked downward, no overlap")
            check(f.allSatisfy { $0.minY > vis.minY + 30 + 100 }, name + ": clear of the lock bar and the Vox to Txt ellipse at the bottom")
        }
        let wide = BlobRules.frames(visible: CGRect(x: 0, y: 0, width: 300, height: 500), sizes: [CGSize(width: 900, height: 50)])[0]
        check(wide.width <= 276 && wide.minX >= 12, "never wider than the screen less its margins")

        // the pin: the blob window can never become key or main, never activates the app
        _ = NSApplication.shared
        let p = BlobPanel.make(frame: NSRect(x: -20000, y: -20000, width: 200, height: 50), interactive: true, title: "pin")
        check(!p.canBecomeKey && !p.canBecomeMain, "the blob window cannot become key or main")
        check(p.styleMask.contains(.nonactivatingPanel) && p.styleMask.contains(.borderless), "non-activating, borderless")
        check(p.collectionBehavior.contains(.fullScreenAuxiliary) && p.collectionBehavior.contains(.canJoinAllSpaces), "on every Space and over full-screen apps")
        check(p.level == .statusBar && !p.hidesOnDeactivate, "status-bar level, stays when the app is not active")
        let q = BlobPanel.make(frame: NSRect(x: 0, y: 0, width: 10, height: 10), interactive: false, title: "pin2")
        check(q.ignoresMouseEvents && !p.ignoresMouseEvents, "a non-sticky body lets the mouse through; only an interactive one takes it")

        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
