// Guard.swift (v27, 14.11.2026): what the input lock gives BACK when it lifts.
// Marko, 14.11.2026: "When you finish, I want to have it back. Same prompt where I was. And even if I touch something
// during the block, you should catch it and write it down when the block is lifted."
// The lock (Lock.swift) swallows his hands; this book remembers where he was (front app, its focused window, the focused
// element and its caret) when the lock went on, records every key and click it swallowed, and when the lock lifts puts
// him back exactly there and replays his keys into that same place, in order. Clicks are written down, never replayed.
// If his app cannot be brought back to the front, nothing is typed anywhere: his text goes to the clipboard instead.
import AppKit
import ApplicationServices

final class GuardBook {
    static let shared = GuardBook()
    struct Key { let code: CGKeyCode; let flags: CGEventFlags; let chars: String; let replay: Bool; let label: String }

    private var keys: [Key] = []
    private var clicks: [[String: Any]] = []
    private var app: NSRunningApplication?
    private var win: AXUIElement?
    private var el: AXUIElement?
    private var range: CFTypeRef?
    private var startAt = Date()
    private var what = ""
    private var active = false
    private(set) var finishing = false          // restoring + replaying now: no new lock may start (the queue waits)
    private(set) var last: [String: Any] = [:]  // the report of the last lifted lock (GET /last)
    var keyCount: Int { keys.count }
    var clickCount: Int { clicks.count }
    var frontName: String { app?.localizedName ?? "" }

    // MARK: the lock goes on

    func begin(_ what: String) {
        keys = []; clicks = []; startAt = Date(); self.what = what; active = true
        app = NSWorkspace.shared.frontmostApplication
        win = nil; el = nil; range = nil
        guard let a = app, a.processIdentifier != ProcessInfo.processInfo.processIdentifier else { app = nil; return }
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.4)
        win = GuardBook.element(ax, kAXFocusedWindowAttribute)
        el = GuardBook.element(ax, kAXFocusedUIElementAttribute)
        if let e = el {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &v) == .success { range = v }
        }
    }

    static func element(_ ax: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr as CFString, &v) == .success, let got = v,
              CFGetTypeID(got) == AXUIElementGetTypeID() else { return nil }
        return (got as! AXUIElement)
    }

    // MARK: while it is on: what his hands did

    func noteKey(_ e: CGEvent) {
        guard active else { return }
        let code = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
        let f = e.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskAlphaShift])
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        let s = String(utf16CodeUnits: buf, count: len)
        var replay = true
        if code == 53 { replay = false }                                            // Escape: the way out, never replayed
        if f.contains(.maskCommand) { replay = [0, 6, 7, 8, 9, 51, 117, 123, 124, 125, 126].contains(Int(code)) }   // ⌘A Z X C V ⌫ ⌦ arrows
        if f.contains(.maskControl) && (code == 8 || code == 2) { replay = false }  // ⌃C ⌃D would interrupt or close his terminal
        keys.append(Key(code: code, flags: f, chars: s, replay: replay, label: GuardBook.label(code, f, s)))
    }

    func noteClick(_ p: CGPoint, _ type: CGEventType) {
        guard active else { return }
        let b = type == .leftMouseDown ? "left" : type == .rightMouseDown ? "right" : "other"
        clicks.append(["x": Int(p.x), "y": Int(p.y), "button": b, "at": Date().timeIntervalSince(startAt)])
    }

    static func label(_ code: CGKeyCode, _ f: CGEventFlags, _ s: String) -> String {
        var m = ""
        if f.contains(.maskControl) { m += "⌃" }
        if f.contains(.maskAlternate) { m += "⌥" }
        if f.contains(.maskCommand) { m += "⌘" }
        let names: [Int: String] = [36: "⏎", 76: "⏎", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑", 49: "␣"]
        if let n = names[Int(code)] { return m + n }
        return m + (s.isEmpty ? "#\(code)" : (m.isEmpty ? s : s.uppercased()))
    }

    // MARK: the lock lifts: give everything back

    /// Called on the main thread, after the tap is gone. restore false (a macro run while Marko was away) still restores
    /// when he typed something, because his keys must go back where he was.
    func finish(_ reason: String, restore: Bool) {
        guard active else { return }
        active = false
        let held = Date().timeIntervalSince(startAt)
        let ks = keys, cs = clicks, what = self.what
        keys = []; clicks = []
        guard (restore || !ks.isEmpty), let a = app, !a.isTerminated else {
            report(held, what, reason, ks, cs, into: app?.localizedName ?? "", replayed: false, why: app == nil ? "nothing was in front" : "")
            return
        }
        finishing = true
        let w = win, e = el, r = range
        GuardBook.bringBack(a, w, e, r)
        waitFront(a, tries: 0) { [weak self] ok in
            guard let s = self else { return }
            if !ok {
                // never type his keys into the wrong place: the clipboard keeps them
                let text = ks.filter { $0.replay }.map { $0.chars }.joined()
                if !text.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                s.finishing = false
                s.report(held, what, reason, ks, cs, into: a.localizedName ?? "", replayed: false,
                         why: "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app") stayed in front; your text is on the clipboard")
                return
            }
            GuardBook.focus(a, e, r)
            let todo = ks.filter { $0.replay }
            guard !todo.isEmpty else {
                s.finishing = false
                s.report(held, what, reason, ks, cs, into: a.localizedName ?? "", replayed: true, why: "")
                return
            }
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.12) {
                GuardBook.replay(todo)
                DispatchQueue.main.async {
                    s.finishing = false
                    s.report(held, what, reason, ks, cs, into: a.localizedName ?? "", replayed: true, why: "")
                }
            }
        }
    }

    static func bringBack(_ a: NSRunningApplication, _ w: AXUIElement?, _ e: AXUIElement?, _ r: CFTypeRef?) {
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.4)
        a.unhide()
        a.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let w {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    static func focus(_ a: NSRunningApplication, _ e: AXUIElement?, _ r: CFTypeRef?) {
        guard let e else { return }
        let ax = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.4)
        AXUIElementSetAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, e)
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let r { AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, r) }
    }

    /// Polls (without blocking the main thread) until his app is in front: up to ~1.6 s, activating again half way.
    private func waitFront(_ a: NSRunningApplication, tries: Int, _ done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == a.processIdentifier {
            // a short settle so the window's key view is really the one we focus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { done(true) }
            return
        }
        if tries >= 16 { done(false); return }
        if tries == 6 || tries == 11 { GuardBook.bringBack(a, win, el, range) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitFront(a, tries: tries + 1, done) }
    }

    /// His keys, in order, as real key presses (keycode, his modifiers and the exact characters), marked so no lock eats them.
    static func replay(_ ks: [Key]) {
        let src = CGEventSource(stateID: .privateState)
        for k in ks {
            guard let d = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: true),
                  let u = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: false) else { continue }
            d.flags = k.flags; u.flags = k.flags
            if !k.chars.isEmpty && !k.flags.contains(.maskCommand) && !k.flags.contains(.maskControl) {
                var units = Array(k.chars.utf16)
                d.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                u.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            }
            d.markedPost(); usleep(2500); u.markedPost(); usleep(5000)
        }
    }

    // MARK: write it down

    private func report(_ held: Double, _ what: String, _ reason: String, _ ks: [Key], _ cs: [[String: Any]], into: String, replayed: Bool, why: String) {
        let rep = ks.filter { $0.replay }, skipped = ks.filter { !$0.replay }
        let text = rep.map { [36, 76].contains(Int($0.code)) ? "\n" : $0.chars }.joined()
        var line = "\(Int(held.rounded())) s held"
        if !ks.isEmpty { line += replayed ? " · \(rep.count) key\(rep.count == 1 ? "" : "s") replayed into \(into)" : " · \(rep.count) key\(rep.count == 1 ? "" : "s") NOT replayed" }
        if !skipped.isEmpty { line += " · not replayed: " + skipped.map { $0.label }.prefix(6).joined(separator: " ") }
        if !cs.isEmpty { line += " · \(cs.count) click\(cs.count == 1 ? "" : "s") noted, not replayed" }
        if !why.isEmpty { line += " · " + why }
        last = ["at": Date().timeIntervalSince1970, "what": what, "reason": reason, "held_s": (held * 10).rounded() / 10,
                "front_app": into, "keys": ks.count, "replayed": replayed ? rep.count : 0, "text": text,
                "not_replayed": skipped.map { $0.label }, "clicks": cs, "notice": line]
        // the notice only when his hands did something; the log always
        if !ks.isEmpty || !cs.isEmpty { Engine.shared.say(line, GREYC, 5) }
        let path = NSHomeDirectory() + "/.mantra_macro/guard_log.jsonl"
        if let d = try? JSONSerialization.data(withJSONObject: last), var s = String(data: d, encoding: .utf8) {
            s += "\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(s.utf8)); h.closeFile() }
            else { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        NSLog("[guard] %@", line)
    }
}
