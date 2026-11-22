// Blob.swift: THE TEXT BLOB (v32, 22.11.2026). Marko: "the text blob which needs to pop up and if something needs to be said to
// me while I'm working on computer and you are working in the background ... You can use the computer now."
// `macro blob "<text>" [--seconds N] [--sticky] [--kind info|done|ask] [--id ID]`, `macro blob --clear <id|all>`, and
// POST 127.0.0.1:8829/blob {text, kind, seconds, sticky, id} / {clear: id}, GET /blobs. A rounded dark panel, top centre under
// the menu bar of the screen where he is working (insertion point, focused element, focused window, mouse: the rule of
// FocusScreen.swift in MANTRA_VOICE_TO_TEXT, copied here with its pure parts in BlobRules), at most three stacked, newest on
// top, never key, never main, no sound. Also automatic: the input lock is released and no other lock follows within two
// seconds: "You can use the computer now" (green, 8 s). Every blob is logged in ~/.mantra_macro/blob_log.jsonl.
import AppKit
import ApplicationServices

private let BLOB_BG = NSColor(srgbRed: 0x10 / 255, green: 0x11 / 255, blue: 0x14 / 255, alpha: 0xF2 / 255)
private let BLOB_FONT = NSFont.systemFont(ofSize: 15, weight: .medium)
private let LINE_H: CGFloat = 19, PAD_X: CGFloat = 20, PAD_R: CGFloat = 40, PAD_Y: CGFloat = 14

private func accent(_ k: BlobKind) -> NSColor {
    switch k {
    case .info: return NSColor(srgbRed: 0x9A / 255, green: 0xA0 / 255, blue: 0xA6 / 255, alpha: 1)      // neutral grey
    case .done: return NSColor(srgbRed: 0x5B / 255, green: 0xD1 / 255, blue: 0x7A / 255, alpha: 1)      // green: you can work
    case .ask: return InputLock.ORANGE                                                                    // amber: I need you
    }
}

private final class BlobView: NSView {
    var lines: [String] = []
    var kind: BlobKind = .info
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() } }
    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        BLOB_BG.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        accent(kind).setFill(); NSRect(x: 0, y: 0, width: 5, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let attrs: [NSAttributedString.Key: Any] = [.font: BLOB_FONT, .foregroundColor: NSColor.white]
        for (i, l) in lines.enumerated() { (l as NSString).draw(at: NSPoint(x: PAD_X, y: PAD_Y + CGFloat(i) * LINE_H), withAttributes: attrs) }
        ("✕" as NSString).draw(at: NSPoint(x: bounds.width - 28, y: 10),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor(white: 0.62, alpha: 1)])
    }
}

/// the blob's own small ✕: transparent, the only part of a non-sticky blob that takes the mouse
private final class CloseArea: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() } }
}

enum BlobLayout {
    /// size and lines of a blob on a screen whose visible width is `screenW`
    static func measure(_ text: String, screenW: CGFloat) -> (size: CGSize, lines: [String], truncated: Bool) {
        let maxW = min(560, max(200, screenW - 24))
        let m: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: [.font: BLOB_FONT]).width }
        let w = BlobRules.wrap(text, width: maxW - PAD_X - PAD_R, measure: m)
        let longest = w.lines.map(m).max() ?? 0
        let width = min(maxW, max(220, ceil(longest) + PAD_X + PAD_R))
        let height = PAD_Y * 2 + CGFloat(max(1, w.lines.count)) * LINE_H
        return (CGSize(width: width, height: height), w.lines, w.truncated)
    }
}

final class BlobCenter {
    static let shared = BlobCenter()
    private var stack = BlobStack()
    private var panels: [String: (body: BlobPanel, close: BlobPanel?)] = [:]
    private var gate = DoneGate()
    private var timer: Timer?
    private var screen: NSScreen?
    private var recent: [[String: Any]] = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: the API

    func handle(_ j: [String: Any]) -> [String: Any] {
        if let c = j["clear"] as? String { return clear(c.isEmpty ? "all" : c, how: "api") }
        let kind = BlobKind(rawValue: (j["kind"] as? String ?? "info").lowercased())
        if kind == nil { return ["ok": false, "error": "kind is info, done or ask"] }
        let secs = (j["seconds"] as? Double) ?? (j["seconds"] as? Int).map(Double.init)
        return show(text: j["text"] as? String ?? "", kind: kind!, seconds: secs, sticky: j["sticky"] as? Bool ?? false, id: j["id"] as? String)
    }

    func show(text raw: String, kind: BlobKind, seconds: Double?, sticky: Bool, id: String?) -> [String: Any] {
        let text = BlobRules.clean(raw)
        if text.isEmpty { return ["ok": false, "error": "no text"] }
        let bid = (id?.isEmpty == false) ? id! : UUID().uuidString.prefix(8).lowercased()
        let dur = BlobRules.duration(text: text, seconds: seconds, sticky: sticky)
        screen = BlobScreen.resolve().screen
        let it = BlobItem(id: bid, text: text, kind: kind, sticky: sticky, seconds: dur, shownAt: Date())
        let events = stack.show(it)
        var truncated = false
        for e in events {
            switch e {
            case .added: truncated = build(it); log("shown", it, "new")
            case .replaced: close(bid, animated: false); truncated = build(it); log("replaced", it, "same id")
            case .evicted(let old): close(old, animated: true); logID("closed", old, "evicted: more than \(BlobRules.maxStack) blobs")
            }
        }
        layout()
        return ["ok": true, "id": bid, "seconds": dur ?? 0, "sticky": sticky, "truncated": truncated, "shown": stack.items.count]
    }

    func clear(_ id: String, how: String) -> [String: Any] {
        if id == "all" {
            let ids = stack.clearAll()
            for i in ids { close(i, animated: true); logID("closed", i, how + ": clear all") }
            return ["ok": true, "cleared": ids.count]
        }
        let ok = stack.clear(id)
        if ok { close(id, animated: true); logID("closed", id, how + ": clear") }
        return ["ok": ok, "error": ok ? "" : "no blob with that id", "cleared": ok ? 1 : 0]
    }

    func status() -> [String: Any] {
        ["ok": true, "shown": stack.items.map { ["id": $0.id, "kind": $0.kind.rawValue, "text": $0.text, "sticky": $0.sticky] }, "recent": recent,
         "done_pending": gate.pending]
    }

    // MARK: the input lock's side: "You can use the computer now"

    func lockTaken() {
        gate.taken(at: Date())
        if stack.clear(BlobRules.doneID) { close(BlobRules.doneID, animated: true); logID("closed", BlobRules.doneID, "the lock was taken again"); layout() }
    }
    func lockReleased() { gate.released(at: Date()) }

    private func tick() {
        let now = Date()
        for id in stack.expire(now: now) { close(id, animated: true); logID("closed", id, "time over") }
        if !stack.items.isEmpty { layout() }
        if gate.poll(now: now) {
            _ = show(text: BlobRules.doneText, kind: .done, seconds: 8, sticky: false, id: BlobRules.doneID)
        }
    }

    // MARK: windows

    private func build(_ it: BlobItem) -> Bool {
        let s = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let m = BlobLayout.measure(it.text, screenW: s.visibleFrame.width)
        let frame = NSRect(origin: NSPoint(x: s.frame.minX - 5000, y: s.frame.minY), size: m.size)
        let body = BlobPanel.make(frame: frame, interactive: it.sticky, title: "Macro Recorder text blob")
        let v = BlobView(frame: NSRect(origin: .zero, size: m.size))
        v.lines = m.lines; v.kind = it.kind
        v.setAccessibilityLabel(it.text); v.setAccessibilityRole(.staticText)
        let id = it.id
        if it.sticky { v.onClick = { [weak self] in self?.userClosed(id) } }
        body.contentView = v
        var closeP: BlobPanel?
        if !it.sticky {
            let c = BlobPanel.make(frame: NSRect(x: 0, y: 0, width: 30, height: 30), interactive: true, title: "Macro Recorder text blob close")
            let a = CloseArea(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            a.onClick = { [weak self] in self?.userClosed(id) }
            a.setAccessibilityLabel("Close blob"); a.setAccessibilityRole(.button); a.setAccessibilityIdentifier("blobclose")
            c.contentView = a
            closeP = c
        }
        body.alphaValue = 0
        panels[it.id] = (body, closeP)
        body.orderFrontRegardless(); closeP?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; body.animator().alphaValue = 1 }
        return m.truncated
    }

    /// every blob to its place: top centre of the chosen screen, newest on top
    private func layout() {
        let s = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let items = stack.items.filter { panels[$0.id] != nil }
        let sizes = items.map { panels[$0.id]!.body.frame.size }
        let fr = BlobRules.frames(visible: s.visibleFrame, sizes: sizes)
        for (i, it) in items.enumerated() {
            guard let p = panels[it.id] else { continue }
            p.body.setFrame(fr[i], display: true)
            p.close?.setFrame(NSRect(x: fr[i].maxX - 32, y: fr[i].maxY - 30, width: 30, height: 30), display: false)
        }
    }

    private func close(_ id: String, animated: Bool) {
        guard let p = panels.removeValue(forKey: id) else { return }
        p.close?.orderOut(nil); p.close?.close()
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.body.animator().alphaValue = 0 }, completionHandler: { p.body.orderOut(nil); p.body.close() })
        } else { p.body.orderOut(nil); p.body.close() }
    }

    private func userClosed(_ id: String) {
        if stack.clear(id) { close(id, animated: true); logID("closed", id, "clicked by Marko"); layout() }
    }

    // MARK: the log: "did you tell me?" is answered from ~/.mantra_macro/blob_log.jsonl

    private func log(_ event: String, _ it: BlobItem, _ how: String) {
        write(["event": event, "id": it.id, "kind": it.kind.rawValue, "text": it.text, "sticky": it.sticky, "seconds": it.seconds ?? 0, "how": how])
    }
    private func logID(_ event: String, _ id: String, _ how: String) { write(["event": event, "id": id, "how": how]) }
    private func write(_ o: [String: Any]) {
        var e = o
        let t = Date()
        e["at"] = t.timeIntervalSince1970
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; e["time"] = f.string(from: t)
        recent.append(e); if recent.count > 20 { recent.removeFirst() }
        let path = NSHomeDirectory() + "/.mantra_macro/blob_log.jsonl"
        if let d = try? JSONSerialization.data(withJSONObject: e), var s = String(data: d, encoding: .utf8) {
            s += "\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(s.utf8)); h.closeFile() }
            else { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        NSLog("[blob] %@ %@ %@", (e["event"] as? String) ?? "", (e["id"] as? String) ?? "", (e["text"] as? String) ?? (e["how"] as? String) ?? "")
    }

    // MARK: --blob-shot <png> "<text>" [kind]: one blob drawn off every screen into a picture, then the app quits (no server, no lock)

    func shot(_ text: String, kind: BlobKind, to path: String) {
        let m = BlobLayout.measure(BlobRules.clean(text), screenW: NSScreen.main?.visibleFrame.width ?? 1512)
        let p = BlobPanel.make(frame: NSRect(x: -20000, y: -20000, width: m.size.width, height: m.size.height), interactive: false, title: "blob shot")
        let v = BlobView(frame: NSRect(origin: .zero, size: m.size)); v.lines = m.lines; v.kind = kind
        p.contentView = v
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("shot \(path) \(Int(m.size.width))x\(Int(m.size.height)) lines=\(m.lines.count) truncated=\(m.truncated)"); exit(0)
        }
    }
}

// MARK: which screen he is working on (FocusScreen.swift of MANTRA_VOICE_TO_TEXT v65, same order of rules)

enum BlobScreen {
    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    private static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private static func rect(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute as String), let s = attr(el, kAXSizeAttribute as String),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var o = CGPoint.zero, z = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &o), AXValueGetValue(s as! AXValue, .cgSize, &z), z.width > 0 || z.height > 0 else { return nil }
        return CGRect(origin: o, size: z)
    }
    private static func caret(_ el: AXUIElement) -> CGRect? {
        guard let v = attr(el, kAXSelectedTextRangeAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rng = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &rng) else { return nil }
        for probe in [CFRange(location: rng.location, length: 1), CFRange(location: max(0, rng.location - 1), length: 1), rng] {
            var pr = probe
            guard let pv = AXValueCreate(.cfRange, &pr) else { continue }
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, pv, &out) == .success,
               let o = out, CFGetTypeID(o) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue(o as! AXValue, .cgRect, &r), r.width >= 0, r.height > 0, r.origin.x.isFinite { return r }
            }
        }
        return nil
    }

    static func resolve() -> (screen: NSScreen, rule: String) {
        let screens = NSScreen.screens
        let frames = screens.map { $0.frame }
        let ph = frames.first?.height ?? 0
        func found(_ ax: CGRect?, _ rule: String) -> (NSScreen, String)? {
            guard let ax = ax, let i = BlobRules.screenIndex(of: BlobRules.appKitRect(fromAX: ax, primaryHeight: ph), frames: frames) else { return nil }
            return (screens[i], rule)
        }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        if let f = element(attr(sys, kAXFocusedUIElementAttribute as String)) {
            var pid: pid_t = 0
            AXUIElementGetPid(f, &pid)
            if pid != getpid() {
                AXUIElementSetMessagingTimeout(f, 0.25)
                if let r = found(caret(f), "a: insertion point") { return r }
                if let r = found(rect(f), "b: focused element") { return r }
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            if let w = element(attr(ax, kAXFocusedWindowAttribute as String)), let r = found(rect(w), "c: focused window") { return r }
        }
        let m = NSEvent.mouseLocation
        let s = screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? screens[0]
        return (s, "d: mouse (last fallback)")
    }
}
