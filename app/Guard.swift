// Guard.swift (v27, 14.11.2026): what the input lock gives BACK when it lifts.
// Marko, 14.11.2026: "When you finish, I want to have it back. Same prompt where I was. And even if I touch something
// during the block, you should catch it and write it down when the block is lifted."
// The lock (Lock.swift) swallows his hands; this book remembers where he was (front app, its focused window, the focused
// element and its caret) when the lock went on, records every key and click it swallowed, and when the lock lifts puts
// him back exactly there and replays his keys into that same place, in order. Clicks are written down, never replayed.
// If his app cannot be brought back to the front, nothing is typed anywhere: his text goes to the clipboard instead.
//
// v34 (25.11.2026): his place is where HIS HANDS last were, not whatever app is in front when the lock comes on. The log showed
// "8 keys replayed into Google Chrome" while Marko was in iTerm2: a worker had brought Chrome front before it took the guard,
// so Chrome was written down as his. Now HandTracker notes the app of his last real key or click (hardware events, or a
// remote-control app's), and that app is given back. Keys he typed after an app-switch shortcut (⌘⇥, ⌘`, ⌘Space, ⌃←/→,
// ⌘H, ⌘Q, ⌘W, ⌘M) were meant for another app: they are not replayed, they go to the clipboard. The give-back is verified
// (his app in front after the replay) and written down. With the lease, a holder that comes back after a pause gets ITS app
// and field front again (refrontHolder), so its next step never lands in Marko's app.
import AppKit
import ApplicationServices

/// v34: the app Marko's own hands were last in. A global monitor sees his keys and clicks while the lock is off (while it is
/// on the tap swallows them, so nothing changes); an app activated within 1.5 s after his input counts as his choice (⌘⇥,
/// the Dock, Spotlight). Posted events of command-line tools (agents) are not his; a regular app's (remote control) are.
final class HandTracker {
    static let shared = HandTracker()
    private(set) var app: NSRunningApplication?
    private(set) var at = Date.distantPast
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] ev in
            guard let s = self, let ce = ev.cgEvent, HandTracker.isHis(ce) else { return }
            s.at = Date()
            if ev.type == .keyDown { s.note(NSWorkspace.shared.frontmostApplication) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { s.note(NSWorkspace.shared.frontmostApplication) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let s = self, Date().timeIntervalSince(s.at) < 1.5,
                  let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            s.note(a)
        }
    }
    private func note(_ a: NSRunningApplication?) {
        guard let a, a.processIdentifier != ProcessInfo.processInfo.processIdentifier, a.activationPolicy == .regular else { return }
        app = a
    }
    static func isHis(_ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == MACRO_MARK { return false }
        if e.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue) { return true }
        let pid = pid_t(e.getIntegerValueField(.eventSourceUnixProcessID))
        if pid <= 0 { return true }
        return NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }
    /// his app, when his hands were there within the last 30 minutes and it still runs
    var recent: NSRunningApplication? {
        guard let a = app, !a.isTerminated, Date().timeIntervalSince(at) < 1800 else { return nil }
        return a
    }
}

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
    var placeFront = false                       // v34: tests: his place is the app in front now (not his last touch)
    private var source = "front"                 // v34: how his app was chosen: front | last-touch
    private var switched = false                 // v34: he pressed an app-switch shortcut: what follows was not for his app
    private struct Ctx { let app: NSRunningApplication; let win: AXUIElement?; let el: AXUIElement?; let range: CFTypeRef?; let at: Date }
    private var holders: [String: Ctx] = [:]     // v34: where each holder was working when its lease dropped
    private(set) var finishing = false          // restoring + replaying now: no new lock may start (the queue waits)
    private(set) var last: [String: Any] = [:]  // the report of the last lifted lock (GET /last)
    var keyCount: Int { keys.count }
    var clickCount: Int { clicks.count }
    var frontName: String { app?.localizedName ?? "" }

    // MARK: the lock goes on

    func begin(_ what: String) {
        keys = []; clicks = []; startAt = Date(); self.what = what; active = true; switched = false
        let front = NSWorkspace.shared.frontmostApplication
        app = front; source = "front"
        if !placeFront, let h = HandTracker.shared.recent, h.processIdentifier != front?.processIdentifier {
            app = h; source = "last-touch"            // an automation brought another app front since he last touched his
        }
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
        var label = GuardBook.label(code, f, s)
        if switched { replay = false; label = "(after switch) " + label }
        keys.append(Key(code: code, flags: f, chars: s, replay: replay, label: label))
        if GuardBook.isSwitch(code, f) { switched = true }
    }

    func noteClick(_ p: CGPoint, _ type: CGEventType) {
        guard active else { return }
        let b = type == .leftMouseDown ? "left" : type == .rightMouseDown ? "right" : "other"
        clicks.append(["x": Int(p.x), "y": Int(p.y), "button": b, "at": Date().timeIntervalSince(startAt)])
    }

    /// v34: shortcuts that leave his app (switch, hide, quit, close, minimise, Spotlight, Spaces, Mission Control)
    static func isSwitch(_ code: CGKeyCode, _ f: CGEventFlags) -> Bool {
        let c = Int(code)
        if f.contains(.maskCommand) && [48, 50, 49, 4, 12, 13, 46].contains(c) { return true }     // ⌘⇥ ⌘` ⌘Space ⌘H ⌘Q ⌘W ⌘M
        if f.contains(.maskControl) && [123, 124, 125, 126].contains(c) { return true }          // ⌃← ⌃→ ⌃↓ ⌃↑ (Spaces)
        return c == 160 || c == 131                                                              // Mission Control, Launchpad
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
    /// v34: `holder` = who held it: where that holder was working is written down first (refrontHolder gives it back when
    /// the same holder takes the lock again within two minutes).
    func finish(_ reason: String, restore: Bool, holder: String = "") {
        guard active else { return }
        active = false
        let held = Date().timeIntervalSince(startAt)
        let ks = keys, cs = clicks, what = self.what, src = source
        keys = []; clicks = []
        noteHolder(holder)
        // keys typed after an app-switch shortcut were meant for another app: the clipboard keeps them
        let afterSwitch = ks.filter { $0.label.hasPrefix("(after switch)") && !$0.chars.isEmpty && !$0.flags.contains(.maskCommand) && !$0.flags.contains(.maskControl) }
        var clip = ""
        if !afterSwitch.isEmpty {
            clip = afterSwitch.map { [36, 76].contains(Int($0.code)) ? "\n" : $0.chars }.joined()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(clip, forType: .string)
        }
        let clipNote = clip.isEmpty ? "" : "\(afterSwitch.count) keys typed after an app switch are on the clipboard"
        guard (restore || !ks.isEmpty), let a = app, !a.isTerminated else {
            report(held, what, reason, ks, cs, into: app?.localizedName ?? "", replayed: false,
                   why: [app == nil ? "nothing was in front" : "", clipNote].filter { !$0.isEmpty }.joined(separator: " · "), source: src, back: nil)
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
                         why: "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app") stayed in front; your text is on the clipboard", source: src, back: false)
                return
            }
            GuardBook.focus(a, e, r)
            let todo = ks.filter { $0.replay }
            guard !todo.isEmpty else {
                s.finishing = false
                s.report(held, what, reason, ks, cs, into: a.localizedName ?? "", replayed: true, why: clipNote, source: src, back: true)
                return
            }
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.12) {
                // the last look before a key is typed: his app must still be in front, else the clipboard
                var front: pid_t = 0
                DispatchQueue.main.sync { front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
                if front == a.processIdentifier { GuardBook.replay(todo) }
                DispatchQueue.main.async {
                    s.finishing = false
                    if front != a.processIdentifier {
                        let text = todo.map { $0.chars }.joined()
                        if !text.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                        s.report(held, what, reason, ks, cs, into: a.localizedName ?? "", replayed: false,
                                 why: "another app came in front just before the replay; your text is on the clipboard", source: src, back: false)
                        return
                    }
                    let still = NSWorkspace.shared.frontmostApplication?.processIdentifier == a.processIdentifier
                    s.report(held, what, reason, ks, cs, into: a.localizedName ?? "", replayed: true, why: clipNote, source: src, back: still)
                }
            }
        }
    }

    /// v34: where the holder is working now (the app in front, if it is not Marko's), for refrontHolder.
    private func noteHolder(_ holder: String) {
        holders = holders.filter { Date().timeIntervalSince($0.value.at) < 120 && !$0.value.app.isTerminated }
        guard !holder.isEmpty, let f = NSWorkspace.shared.frontmostApplication,
              f.processIdentifier != ProcessInfo.processInfo.processIdentifier, f.processIdentifier != app?.processIdentifier else { return }
        let ax = AXUIElementCreateApplication(f.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        let w = GuardBook.element(ax, kAXFocusedWindowAttribute), e = GuardBook.element(ax, kAXFocusedUIElementAttribute)
        var r: CFTypeRef?
        if let e, AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &r) != .success { r = nil }
        holders[holder] = Ctx(app: f, win: w, el: e, range: r, at: Date())
    }
    /// v34: the same holder took the lock again: its app, window and field come front again. Returns the app's name.
    func refrontHolder(_ holder: String) -> String? {
        guard let c = holders.removeValue(forKey: holder), Date().timeIntervalSince(c.at) < 120, !c.app.isTerminated,
              c.app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        GuardBook.bringBack(c.app, c.win, c.el, c.range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { GuardBook.focus(c.app, c.el, c.range) }
        return c.app.localizedName
    }
    /// v34: release-all: a give-back that hangs never blocks the next lock.
    func unwedge() { finishing = false }

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

    private func report(_ held: Double, _ what: String, _ reason: String, _ ks: [Key], _ cs: [[String: Any]], into: String, replayed: Bool, why: String,
                        source: String = "front", back: Bool? = nil) {
        let rep = ks.filter { $0.replay }, skipped = ks.filter { !$0.replay }
        let text = rep.map { [36, 76].contains(Int($0.code)) ? "\n" : $0.chars }.joined()
        var line = "\(Int(held.rounded())) s held" + (reason.isEmpty ? "" : " (\(reason))")
        if !ks.isEmpty { line += replayed ? " · \(rep.count) key\(rep.count == 1 ? "" : "s") replayed into \(into)" : " · \(rep.count) key\(rep.count == 1 ? "" : "s") NOT replayed" }
        if !skipped.isEmpty { line += " · not replayed: " + skipped.map { $0.label }.prefix(6).joined(separator: " ") }
        if !cs.isEmpty { line += " · \(cs.count) click\(cs.count == 1 ? "" : "s") noted, not replayed" }
        if !why.isEmpty { line += " · " + why }
        last = ["at": Date().timeIntervalSince1970, "what": what, "reason": reason, "held_s": (held * 10).rounded() / 10,
                "front_app": into, "keys": ks.count, "replayed": replayed ? rep.count : 0, "text": text,
                "not_replayed": skipped.map { $0.label }, "clicks": cs, "notice": line, "his_app_from": source,
                "his_app_back": back.map { $0 as Any } ?? NSNull()]
        // the notice only when his hands did something; the log always
        if !ks.isEmpty || !cs.isEmpty { Engine.shared.say(line, GREYC, 5) }
        logLine(last)
        NSLog("[guard] %@", line)
    }
    /// one line of ~/.mantra_macro/guard_log.jsonl
    func logLine(_ j: [String: Any]) {
        var j = j
        if j["at"] == nil { j["at"] = Date().timeIntervalSince1970 }
        let path = NSHomeDirectory() + "/.mantra_macro/guard_log.jsonl"
        if let d = try? JSONSerialization.data(withJSONObject: j), var s = String(data: d, encoding: .utf8) {
            s += "\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(s.utf8)); h.closeFile() }
            else { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
        }
    }
}
