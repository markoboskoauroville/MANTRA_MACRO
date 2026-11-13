// Lock.swift: THE INPUT LOCK (v24, 13.11.2026). A port of the phone's Lock.kt (VOICE_ENGINE_ANDROID, v7 to v15) from Kotlin
// to Swift. Marko: "simply copy the system from the phone to this Mac ... We developed the logic on the phone. The user
// interface on the phone: you just need to convert from Kotlin to Swift." Same states (off, on, overridden, requested),
// same words, same colours, same layout: a thin dark bar (#101114) with orange (#E8A33D) bold words, left
// "CLAUDE · <time> · <what>", right the orange TAKE OVER; after TAKE OVER the small orange blob "GIVE THE MAC BACK TO
// CLAUDE" at the right edge; "CLAUDE ASKS FOR THE MAC" when a session asks. Nothing is dimmed, nothing in the middle.
// On the Mac the lock is part of the macro engine: it goes on when any script runs (Engine.runScript) and off at its end.
// What the phone's overlay did with a touch layer, the Mac does with an active event tap (.defaultTap) that swallows
// Marko's physical mouse, scroll and key events; the macro's own events carry MACRO_MARK and pass.
import AppKit
import Network

/// Every event the macro engine posts carries this in eventSourceUserData ("MAC" + "RO" in ASCII); the tap lets it through.
let MACRO_MARK: Int64 = 0x4D41_4352_4F4B
extension CGEvent {
    func markedPost() { setIntegerValueField(.eventSourceUserData, value: MACRO_MARK); post(tap: .cghidEventTap) }
}

enum LockState: String { case off, on, overridden, requested }
enum Caller { case claude, macro }      // who started the run: the bar says CLAUDE or MACRO

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
}
/// The blob: a click gives back. No dragging: it stays where TAKE OVER was.
private final class BlobView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() } }
}
/// One line of text centred on its cap height (not its line box), left aligned or centred in x, tail-truncated.
private final class CapText: NSView {
    var text = "" { didSet { needsDisplay = true } }
    let font: NSFont, color: NSColor, centred: Bool
    init(frame: NSRect, font: NSFont, color: NSColor, centred: Bool) {
        self.font = font; self.color = color; self.centred = centred
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func draw(_ r: NSRect) {
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail; ps.alignment = centred ? .center : .left
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let baseline = (bounds.height - font.capHeight) / 2
        let y = baseline + font.descender                      // descender is negative: the line box starts below the baseline
        (text as NSString).draw(in: NSRect(x: 0, y: y, width: bounds.width, height: lineH),
                                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
    }
}

final class InputLock {
    static let shared = InputLock()
    static let ORANGE = NSColor(srgbRed: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255, alpha: 1)
    static let BARBG = NSColor(srgbRed: 0x10 / 255, green: 0x11 / 255, blue: 0x14 / 255, alpha: 0xF2 / 255)

    private(set) var state: LockState = .off
    private(set) var problem: String?                // why it could not lock (Accessibility missing)
    private(set) var overrides = 0                   // how many times Marko took over: a run compares it before and after
    private var lastText = "", label = "", who = "CLAUDE"
    private var startAt = Date(), endAt: Date?, deadline = Date.distantFuture
    private var lastSeconds = 0
    private var manualHold = false                   // `macro lock` / BlockInput On: stays until unlock
    private var runDepth = 0                         // scripts running now
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var bars: [(panel: NSPanel, text: CapText)] = []
    private var barRects: [CGRect] = []              // CG coordinates (top left origin), clicks inside pass to the bar
    private var blob: NSPanel?
    private var ticker: Timer?
    private var escSince: Date?
    private var suspendedUntil = Date.distantPast    // /through
    private var macroPos: CGPoint?                   // where the macro's pointer is, while the lock is on

    // MARK: the engine's side: a run starts and ends

    /// A script starts. Returns nil when it may run, else why it is refused.
    func runBegin(name: String, by: Caller, seconds: Int?, hard: Int) -> String? {
        if by == .claude {
            if state == .overridden { return "overridden by Marko: the Mac is his until he gives it back (the orange blob GIVE THE MAC BACK TO CLAUDE)" }
            if state == .requested { return "waiting for Marko: he has not yet clicked CLAUDE ASKS FOR THE MAC" }
        }
        runDepth += 1
        if state == .overridden || state == .requested { return nil }    // Marko's own run while he has the Mac: no lock
        if state == .on && manualHold { return nil }
        let t = seconds ?? 0
        who = by == .claude ? "CLAUDE" : "MACRO"
        engage(name, seconds: t, hard: hard, manual: false)
        return nil
    }
    /// the run's name goes on the bar even when a manual lock already holds it ("macro do" -> the macro's name)
    func setLabel(_ n: String) { if state == .on && !manualHold { label = n; lastText = n } }
    func runEnd() {
        runDepth = max(0, runDepth - 1)
        if runDepth == 0 && !manualHold && state == .on { off() }
    }

    // MARK: the phone's API: on, off, request, through

    /// POST /lock {text, seconds}
    func on(_ text: String, seconds: Int = 0, by: Caller = .claude) {
        who = by == .claude ? "CLAUDE" : "MACRO"
        engage(text, seconds: seconds, hard: seconds > 0 ? min(600, seconds + 30) : 600, manual: true)
    }
    func off() {
        manualHold = false
        closeBars(); closeBlob(); removeTap()
        ticker?.invalidate(); ticker = nil
        state = .off
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    /// BlockInput Off inside a script: the lock is lifted for the rest of the run.
    func release() { if state == .on { off() } }

    /// Claude needs the Mac while Marko uses it: the blob asks; his click hands it over (the lock comes on).
    func request(_ text: String) {
        if state == .on { return }
        lastText = text
        state = .requested
        showBlob("CLAUDE ASKS\nFOR THE MAC") { [weak self] in
            guard let s = self else { return }
            s.engage(s.lastText, seconds: s.lastSeconds, hard: 300, manual: true)
        }
    }

    /// The caller's own action: the lock steps aside for ms and comes back (/through). The macro's events pass anyway.
    func through(_ ms: Int) {
        guard state == .on else { return }
        suspendedUntil = Date().addingTimeInterval(Double(min(15000, max(100, ms))) / 1000)
        bars.forEach { $0.panel.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(min(15000, max(100, ms)))) { [weak self] in
            if self?.state == .on { self?.bars.forEach { $0.panel.orderFrontRegardless() } }
        }
    }

    /// Marko pressed TAKE OVER (or held Escape for a second). The running macro stops at its next step.
    func takeOver() {
        guard state == .on else { return }
        overrides += 1
        if buttonSpot == nil || !fromButton { buttonSpot = mainSpot }
        fromButton = false
        let wasText = lastText
        closeBars(); removeTap(); ticker?.invalidate(); ticker = nil
        manualHold = false
        state = .overridden
        CGAssociateMouseAndMouseCursorPosition(1)
        Engine.shared.stopPlayingByOverride()
        showBlob("GIVE THE MAC\nBACK TO CLAUDE") { [weak self] in
            guard let s = self else { return }
            s.engage(wasText.isEmpty ? "Back to work. It is yours again when this disappears." : wasText, seconds: s.lastSeconds, hard: 300, manual: true)
        }
    }

    func status() -> [String: Any] {
        var o: [String: Any] = ["lock": state.rawValue, "text": lastText, "runs": runDepth]
        if let e = endAt { o["left"] = max(0, Int(e.timeIntervalSinceNow)) }
        if state == .on { o["elapsed"] = Int(Date().timeIntervalSince(startAt)) }
        if let p = problem { o["problem"] = p }
        return o
    }

    // MARK: the bar, the blob

    private func engage(_ text: String, seconds: Int, hard: Int, manual: Bool) {
        lastText = text; label = text; lastSeconds = seconds
        closeBlob()
        if manual { manualHold = true }
        endAt = seconds > 0 ? Date().addingTimeInterval(Double(seconds)) : nil
        deadline = Date().addingTimeInterval(Double(hard))
        if state == .on { bars.forEach { $0.text.text = barText() }; return }
        guard AXIsProcessTrusted() else {
            problem = "Accessibility is missing for Macro Recorder (Mantra): the input lock is off"
            state = .off; manualHold = false
            Engine.shared.say(problem!, GREYC, 5)
            return
        }
        problem = nil
        startAt = Date(); escSince = nil
        macroPos = CGEvent(source: nil)?.location
        guard installTap() else {
            problem = "the input lock could not start its event tap (Accessibility): nothing is blocked"
            state = .off; manualHold = false
            Engine.shared.say(problem!, GREYC, 5)
            return
        }
        showBars()
        state = .on
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    /// v13 of the phone: the countdown. The time first, so a long label is cut, never the time.
    private func barText() -> String {
        if let e = endAt {
            let left = Int(e.timeIntervalSinceNow.rounded(.down))
            let t = left > 0 ? String(format: "%d:%02d left", left / 60, left % 60) : "almost done"
            return "\(who) · \(t) · \(label)"
        }
        let el = Int(Date().timeIntervalSince(startAt))
        return "\(who) · " + String(format: "%d:%02d elapsed", el / 60, el % 60) + " · \(label)"
    }

    private func tick() {
        bars.forEach { $0.text.text = barText() }
        // the watchdog: a hard maximum, and nothing running and nothing held means nothing to lock
        if Date() > deadline { off(); Engine.shared.say("input lock lifted: its time was up", GREYC, 3); return }
        if let t = tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        // holding Escape for one second takes over too
        if CGEventSource.keyState(.hidSystemState, key: 0x35) {
            if escSince == nil { escSince = Date() }
            if Date().timeIntervalSince(escSince!) >= 1 { escSince = nil; takeOver() }
        } else { escSince = nil }
    }

    // v25 (13.11.2026, Marko: "center all the text and all the buttons ... Everything must be in the same place. Eyes are
    // following."): the text and TAKE OVER are ONE group centred on the screen's centre line, the text a fixed width so the
    // countdown never moves the group, both centred on the cap height. The blob takes the button's place exactly.
    static let BTN_W: CGFloat = 236, BTN_H: CGFloat = 22, BAR_H: CGFloat = 30, GAP: CGFloat = 14
    private var buttonSpot: (screen: NSScreen, rect: NSRect)?     // where TAKE OVER is, in screen coordinates (Cocoa)

    private func showBars() {
        closeBars()
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for s in NSScreen.screens {
            let h = InputLock.BAR_H
            let f = NSRect(x: s.frame.minX, y: s.visibleFrame.maxY - h, width: s.frame.width, height: h)   // right under the menu bar
            let p = BarPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "Macro Recorder input lock bar"
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.hidesOnDeactivate = false; p.ignoresMouseEvents = false
            p.sharingType = .readOnly            // visible to screen capture and CGWindowList (layer 25, owner "MacroRecorder")
            let v = NSView(frame: NSRect(origin: .zero, size: f.size)); v.wantsLayer = true
            v.layer?.backgroundColor = InputLock.BARBG.cgColor
            let bw = InputLock.BTN_W
            let tw = min(420, max(120, f.width - bw - InputLock.GAP - 40))
            let x0 = ((f.width - (tw + InputLock.GAP + bw)) / 2).rounded()
            let t = CapText(frame: NSRect(x: x0, y: 0, width: tw, height: h), font: .monospacedDigitSystemFont(ofSize: 13, weight: .bold), color: InputLock.ORANGE, centred: false)
            t.text = barText()
            let b = ClickView(frame: NSRect(x: x0 + tw + InputLock.GAP, y: (h - InputLock.BTN_H) / 2, width: bw, height: InputLock.BTN_H)); b.wantsLayer = true
            b.layer?.backgroundColor = InputLock.ORANGE.cgColor; b.layer?.cornerRadius = 8
            let bt = CapText(frame: NSRect(x: 0, y: 0, width: bw, height: InputLock.BTN_H), font: .boldSystemFont(ofSize: 13), color: .black, centred: true)
            bt.text = "TAKE OVER"
            b.addSubview(bt)
            let rect = NSRect(x: f.minX + b.frame.minX, y: f.minY + b.frame.minY, width: bw, height: InputLock.BTN_H)
            b.onClick = { [weak self] in self?.buttonSpot = (s, rect); self?.fromButton = true; self?.takeOver() }
            if s == (NSScreen.main ?? NSScreen.screens[0]) { mainSpot = (s, rect) }
            b.setAccessibilityLabel("TAKE OVER"); b.setAccessibilityRole(.button); b.setAccessibilityIdentifier("takeover")
            v.addSubview(t); v.addSubview(b)
            p.contentView = v
            p.orderFrontRegardless()
            bars.append((panel: p, text: t))
            barRects.append(CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height))
        }
    }
    private var mainSpot: (screen: NSScreen, rect: NSRect)?
    private var fromButton = false
    private func closeBars() { bars.forEach { $0.panel.orderOut(nil); $0.panel.close() }; bars = []; barRects = [] }

    /// The blob is TAKE OVER's twin: same screen, same centre, same size, same shape; only its words differ.
    private func showBlob(_ words: String, tap: @escaping () -> Void) {
        closeBlob()
        let spot = buttonSpot ?? mainSpot
        let r: NSRect
        if let sp = spot { r = sp.rect } else {
            let s = NSScreen.main ?? NSScreen.screens[0]
            let w = InputLock.BTN_W, h = InputLock.BTN_H
            r = NSRect(x: (s.frame.midX - (min(420, max(120, s.frame.width - w - InputLock.GAP - 40)) + InputLock.GAP + w) / 2 + min(420, max(120, s.frame.width - w - InputLock.GAP - 40)) + InputLock.GAP).rounded(),
                       y: s.visibleFrame.maxY - InputLock.BAR_H + (InputLock.BAR_H - h) / 2, width: w, height: h)
        }
        let p = BarPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Macro Recorder input lock blob"
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.sharingType = .readOnly
        let v = BlobView(frame: NSRect(origin: .zero, size: r.size)); v.wantsLayer = true
        v.layer?.backgroundColor = InputLock.ORANGE.cgColor; v.layer?.cornerRadius = 8
        let t = CapText(frame: NSRect(origin: .zero, size: r.size), font: .boldSystemFont(ofSize: 13), color: .black, centred: true)
        t.text = words.replacingOccurrences(of: "\n", with: " "); v.addSubview(t)
        v.onClick = { [weak self] in self?.closeBlob(); tap() }
        v.setAccessibilityLabel(t.text); v.setAccessibilityRole(.button)
        p.contentView = v
        p.orderFrontRegardless()
        blob = p
    }
    private func closeBlob() { blob?.orderOut(nil); blob?.close(); blob = nil }

    // MARK: the tap: Marko's hands stop here

    private func installTap() -> Bool {
        removeTap()
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                    .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
                                    .keyDown, .keyUp, .flagsChanged]
        for t in types { mask |= 1 << t.rawValue }
        let cb: CGEventTapCallBack = { _, type, e, ref in
            let me = Unmanaged<InputLock>.fromOpaque(ref!).takeUnretainedValue()
            return me.filter(type, e)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }
    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; tapSource = nil
    }

    /// nil swallows the event. Called on the main thread by the tap.
    fileprivate func filter(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }      // macOS switched it off: on again
            return pass
        }
        guard state == .on, Date() >= suspendedUntil else { return pass }
        if e.getIntegerValueField(.eventSourceUserData) == MACRO_MARK { return pass }       // the macro's own hands
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            // the stop key of the macro recorder (⌃⌥⌘. by default) always works
            if let b = Engine.shared.settings.keys["stop"], KeyMap.codes[b.key] == Int(e.getIntegerValueField(.keyboardEventKeycode)) { return pass }
            return nil
        default:
            // clicks and moves inside the bar pass, so TAKE OVER can be pressed; everything else is swallowed
            let p = e.location
            if barRects.contains(where: { $0.contains(p) }) { return pass }
            return nil
        }
    }

    // MARK: the macro's pointer (so a swallowed physical move never leaves the macro's pointer elsewhere)

    var locked: Bool { state == .on }
    func notePointer(_ p: CGPoint) { if state == .on { macroPos = p } }
    func pointer() -> CGPoint? { state == .on ? macroPos : nil }
}

// MARK: the same routes as the phone, on this Mac: 127.0.0.1:8829

/// GET /status, POST /lock {text, seconds}, /unlock, /through {ms}, /request {text}. Loopback only.
final class LockServer {
    static let shared = LockServer()
    static let PORT: UInt16 = 8829
    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: LockServer.PORT)!) else { return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }
    func stop() { listener?.cancel(); listener = nil }

    private func serve(_ c: NWConnection) {
        c.start(queue: .global(qos: .userInitiated))
        var buf = Data()
        func more() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                if let d = data { buf.append(d) }
                if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                    let len = head.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                    if buf.count - r.upperBound >= len {
                        self.answer(c, head, Data(buf[r.upperBound..<(r.upperBound + len)]))
                        return
                    }
                }
                if done || err != nil || buf.count > 1_000_000 { c.cancel() } else { more() }
            }
        }
        more()
    }

    private func answer(_ c: NWConnection, _ head: String, _ body: Data) {
        let first = head.components(separatedBy: "\r\n")[0].split(separator: " ")
        let method = first.first.map(String.init) ?? "", path = first.count > 1 ? String(first[1]) : "/"
        let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var out: [String: Any] = [:]
        var code = 200
        DispatchQueue.main.sync {
            let L = InputLock.shared
            switch (method, path) {
            case ("GET", "/status"), ("GET", "/"): out = L.status(); out["app"] = "macrorecorder"; out["version"] = VERSION
            case ("POST", "/lock"): L.on(j["text"] as? String ?? "Working on the Mac. It will be yours again when this disappears.", seconds: j["seconds"] as? Int ?? 0); out = ["ok": true, "lock": L.state.rawValue]
            case ("POST", "/request"): L.request(j["text"] as? String ?? "Claude needs the Mac for a moment."); out = ["ok": true, "lock": L.state.rawValue]
            case ("POST", "/unlock"): L.off(); out = ["ok": true, "lock": L.state.rawValue]
            case ("POST", "/through"): L.through(j["ms"] as? Int ?? 800); out = ["ok": true, "lock": L.state.rawValue]
            default: code = 404; out = ["error": "no such route"]
            }
        }
        let d = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        let h = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Not Found")\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + d, completion: .contentProcessed { _ in c.cancel() })
    }
}
