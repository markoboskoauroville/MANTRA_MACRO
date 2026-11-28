// InputCapture.swift: v43 (28.11.2026). THE ONE CAPTURE MODULE of the action dialogs (insert and edit are the same dialog).
// Marko, 28.11.2026: "any command, mouse, and text key should have a capture button ... I can capture any key, enter, escape,
// whatever, and I don't need to type ... If I say click and the dialog for finding the click is opening up, you can also click
// capture, and then next click is registered. In that way, we are recording step by step."
//
// What it captures (each one armed by a CaptureButton, one at a time; arming another ends the first):
//   key      the next key with its modifiers (Enter, Esc, Tab, arrows, F keys, ⌘ ⌥ ⌃ ⇧ chords). It is the recorder's own KeyCapture
//            (Keys.swift: the local monitor that already catches the hotkeys), so the key never reaches the dialog: Enter does not
//            confirm, Esc does not close. Written in the script's own Send syntax (ScriptKeys).
//   click    the next click anywhere on the screen: where, which button, how many clicks (a second click inside the system's
//            double-click time makes it 2, a third 3).
//   drag     press, move, release: the start and the end.
//   scroll   the next scroll: the direction and the amount in the same notches the recorder writes (a notch = 30 points).
//   window   a click on a window: its app name, its title and its frame.
//   picture  the system's cross-hair (Engine.snap, the picture picker the app already has).
// A mouse capture uses an event tap like the recorder's (Engine.startRecording, same mask style, same run loop) but a DEFAULT tap, so
// the click is swallowed: it does not reach the app under it (the recorder's own tap only listens, so a recorded click does reach it).
// Without the Accessibility permission the default tap cannot be made; then a listen-only tap is used and the click also reaches the
// app under it (`passive`). The window the capture started from steps out of the way and comes back to the front with the fields
// filled. While a mouse capture waits, a small panel on top says so and has CANCEL (its clicks pass through); Esc cancels too, and
// 60 seconds end it. The tap and the panel are removed whatever ends the capture.
import SwiftUI
import AppKit
import CoreGraphics

struct PickedWindow {
    var app: String
    var title: String
    var frame: CGRect
}

final class InputCapture: NSObject, ObservableObject {
    static let shared = InputCapture()

    /// the slot (id) of the CAPTURE button that is waiting; nil = nothing is armed
    @Published private(set) var owner: String?
    @Published private(set) var prompt = ""

    private enum Mode { case none, click, clickCount, drag, scroll }
    private let keys = KeyCapture()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var passive = false                       // the tap could only listen: the click also reaches the app under it
    private var panel: NSPanel?
    private var panelRect = CGRect.zero               // the panel in the tap's coordinates (global, top left origin)
    private var hidden: NSWindow?
    private var timeout: Timer?
    private var settle: Timer?
    private var token = 0
    private var mode = Mode.none
    private var finishing = false
    private var down: CGPoint?
    private var up: CGPoint?
    private var downButton = "Left"
    private var count = 1
    private var wheelX = 0.0
    private var wheelY = 0.0
    private var onClick: ((CGPoint, String, Int) -> Void)?
    private var onDrag: ((CGPoint, CGPoint, String) -> Void)?
    private var onScroll: ((String, Int) -> Void)?
    private var colourWanted = false

    var armed: Bool { owner != nil }

    // MARK: the public captures

    /// the next key: its modifiers (cmd, alt, ctrl, shift) and its name as KeyMap knows it ("return", "escape", "f5", "a" ...)
    func key(_ slot: String, _ done: @escaping (_ mods: [String], _ name: String) -> Void) {
        begin(slot, "Press a key…")
        let t = token
        keys.start("capture", { [weak self] mods, name in
            guard let s = self, s.token == t else { return true }
            s.finish()
            done(mods, name)
            return true
        }, { [weak self] in
            guard let s = self, s.token == t else { return }
            s.finish()
            Engine.shared.say("capture: no key pressed", GREYC, 1.6)
        }, timeout: 30)
    }

    /// the next click anywhere: point, button ("Left", "Right", "Middle") and, with `count`, how many clicks in a row.
    /// `colour` also reads the colour under the point before the dialog comes back (0xRRGGBB).
    func click(_ slot: String, count counted: Bool = false, colour: Bool = false,
               _ done: @escaping (_ point: CGPoint, _ button: String, _ count: Int, _ colour: String?) -> Void) {
        armMouse(slot, counted ? .clickCount : .click, "Click where you want it · Esc or CANCEL stops")
        guard owner == slot else { return }
        colourWanted = colour
        onClick = { [weak self] p, b, c in
            let col = (self?.colourWanted ?? false) ? Eye.pixel(Double(p.x), Double(p.y)) : nil
            DispatchQueue.main.async { done(p, b, c, col) }
        }
    }

    /// press, move, release: where it was pressed, where it was released, and the button
    func drag(_ slot: String, _ done: @escaping (_ from: CGPoint, _ to: CGPoint, _ button: String) -> Void) {
        armMouse(slot, .drag, "Press, drag, release · Esc or CANCEL stops")
        guard owner == slot else { return }
        onDrag = { a, b, button in DispatchQueue.main.async { done(a, b, button) } }
    }

    /// the next scroll: direction "Up" "Down" "Left" "Right" and the notches
    func scroll(_ slot: String, _ done: @escaping (_ direction: String, _ amount: Int) -> Void) {
        armMouse(slot, .scroll, "Scroll now… · Esc stops")
        guard owner == slot else { return }
        onScroll = { d, n in DispatchQueue.main.async { done(d, n) } }
    }

    /// click a window: the window under the click (nil when the click was on the desktop, the Dock or the menu bar)
    func window(_ slot: String, _ done: @escaping (PickedWindow?) -> Void) {
        armMouse(slot, .click, "Click the window you want · Esc or CANCEL stops")
        guard owner == slot else { return }
        onClick = { p, _, _ in
            let w = InputCapture.windowAt(p)
            DispatchQueue.main.async { done(w) }
        }
    }

    /// the system's cross-hair over a button or a part of the screen: the picture is saved in the images folder (Engine.snap)
    func picture(_ slot: String, _ done: @escaping (String?) -> Void) {
        begin(slot, "Drag over the picture… Esc stops")
        hideWindow()
        let t = token
        Engine.shared.snap("") { [weak self] file in
            guard let s = self, s.token == t else { return }
            s.finish()
            done(file)
        }
    }

    /// ends whatever is armed (the dialog closed, the window closed, the app quits, the CAPTURE button pressed again)
    func cancel() {
        guard owner != nil || tap != nil || panel != nil else { return }
        finish()
    }

    @objc private func cancelClicked() { cancel() }

    // MARK: the windows

    static func windowAt(_ p: CGPoint) -> PickedWindow? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        for w in list {                                  // front to back
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int) != me,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  b.contains(p) else { continue }
            return PickedWindow(app: (w[kCGWindowOwnerName as String] as? String) ?? "", title: (w[kCGWindowName as String] as? String) ?? "", frame: b)
        }
        return nil
    }

    private func hideWindow() {
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, w.isVisible, !(w is NSPanel) { hidden = w; w.orderOut(nil) }
    }

    private func showPanel(_ words: String) {
        closePanel()
        let w: CGFloat = 560, h: CGFloat = 46
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.canHide = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.title = "Macro Recorder capture"
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = CARD.cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = AMBER.cgColor
        let label = NSTextField(labelWithString: words)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        label.textColor = AMBER
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 14, y: 14, width: w - 140, height: 18)
        let cancel = NSButton(title: "CANCEL", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: w - 110, y: 9, width: 98, height: 28)
        box.addSubview(label)
        box.addSubview(cancel)
        p.contentView = box
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
        p.setFrameOrigin(NSPoint(x: screen.frame.midX - w / 2, y: screen.visibleFrame.maxY - h - 24))
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        p.orderFrontRegardless()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = p.frame
        panelRect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        panel = p
    }

    private func closePanel() {
        if let p = panel { p.orderOut(nil); p.close() }
        panel = nil
        panelRect = .zero
    }

    // MARK: arming and ending

    private func begin(_ slot: String, _ words: String) {
        cancel()
        token += 1
        finishing = false
        owner = slot
        prompt = words
    }

    private func armMouse(_ slot: String, _ m: Mode, _ words: String) {
        let short = m == .scroll ? "Scroll now…" : (words.components(separatedBy: " ·").first ?? words)
        begin(slot, short)
        mode = m
        down = nil; up = nil; count = 1; wheelX = 0; wheelY = 0
        onClick = nil; onDrag = nil; onScroll = nil; colourWanted = false
        if m != .scroll {                                 // a scroll is made over the window: it stays; clicks need the screen free
            hideWindow()
            showPanel(words)
        }
        guard installTap() else {
            Engine.shared.say("cannot capture: allow Accessibility or Input Monitoring for Macro Recorder (Mantra)", ORANGEC, 5)
            finish()
            return
        }
        let t = token
        timeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            guard let s = self, s.token == t else { return }
            s.finish()
            Engine.shared.say("capture: nothing happened in 60 seconds, stopped", GREYC, 2.5)
        }
        if passive { Engine.shared.say("no Accessibility: the captured click also reaches the app under it", GREYC, 3) }
    }

    private func finish() {
        finishing = true
        timeout?.invalidate(); timeout = nil
        settle?.invalidate(); settle = nil
        keys.stop()
        removeTap()
        closePanel()
        mode = .none
        onClick = nil; onDrag = nil; onScroll = nil
        owner = nil
        prompt = ""
        token += 1
        Engine.shared.bindKeys()                          // KeyCapture let go of the recorder's own hot keys while it listened
        if let w = hidden {
            hidden = nil
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: the tap (same style as Engine.startRecording, but a default tap so the click can be swallowed)

    private func installTap() -> Bool {
        removeTap()
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                    .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
                                    .keyDown, .keyUp]
        for t in types { mask |= 1 << t.rawValue }
        let cb: CGEventTapCallBack = { _, type, e, ref in
            let me = Unmanaged<InputCapture>.fromOpaque(ref!).takeUnretainedValue()
            return me.filter(type, e)
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        passive = false
        var made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: cb, userInfo: me)
        if made == nil {
            passive = true
            made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: cb, userInfo: me)
        }
        guard let t = made else { return false }
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }

    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// nil swallows the event. Called on the main thread by the tap.
    fileprivate func filter(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        guard !finishing, mode != .none else { return pass }
        let swallow: Unmanaged<CGEvent>? = passive ? pass : nil
        if type == .keyDown || type == .keyUp {
            guard e.getIntegerValueField(.keyboardEventKeycode) == 53 else { return pass }          // Esc cancels
            if type == .keyDown { DispatchQueue.main.async { InputCapture.shared.cancel() } }
            return swallow
        }
        let p = e.location
        if panelRect.contains(p) { return pass }                                                      // CANCEL's own click
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if mode == .scroll { return pass }
            settle?.invalidate(); settle = nil
            if down == nil {
                down = p
                downButton = type == .leftMouseDown ? "Left" : (type == .rightMouseDown ? "Right" : "Middle")
            }
            count = max(count, Int(e.getIntegerValueField(.mouseEventClickState)))
            return swallow
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return mode == .scroll ? pass : swallow
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if mode == .scroll { return pass }
            up = p
            DispatchQueue.main.async { InputCapture.shared.mouseUp() }
            return swallow
        case .scrollWheel:
            guard mode == .scroll else { return pass }
            if e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return swallow }       // the coasting after the fingers left
            wheelY += Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            wheelX += Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            settle?.invalidate()
            let t = token
            settle = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                guard let s = self, s.token == t, !s.finishing else { return }
                s.scrolled()
            }
            return swallow
        default:
            return pass
        }
    }

    private func mouseUp() {
        guard !finishing, let a = down else { return }
        switch mode {
        case .click:
            let cb = onClick, b = downButton
            cb?(a, b, 1)                       // first: the colour and the window under the point are read while this window is still out of the way
            finish()
        case .clickCount:
            settle?.invalidate()
            let t = token
            settle = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval + 0.12, repeats: false) { [weak self] _ in
                guard let s = self, s.token == t, !s.finishing else { return }
                let cb = s.onClick, b = s.downButton, c = s.count
                cb?(a, b, c)
                s.finish()
            }
        case .drag:
            let cb = onDrag, b = downButton, to = up ?? a
            cb?(a, to, b)
            finish()
        default:
            break
        }
    }

    private func scrolled() {
        let x = wheelX, y = wheelY, cb = onScroll
        let vertical = abs(y) >= abs(x)
        let amount = max(1, Int((abs(vertical ? y : x) / 30 + 0.5).rounded(.down)))
        if vertical { cb?(y > 0 ? "Up" : "Down", amount) } else { cb?(x > 0 ? "Left" : "Right", amount) }
        finish()
    }
}

// MARK: the CAPTURE button: one look in every dialog, waiting is shown on the button itself

struct CaptureButton: View {
    @ObservedObject var cap = InputCapture.shared
    let slot: String
    var title = "CAPTURE"
    var help = ""
    let start: () -> Void

    var body: some View {
        let waiting = cap.owner == slot
        Button(action: { if waiting { cap.cancel() } else { start() } }) {
            HStack(spacing: 6) {
                Image(systemName: waiting ? "xmark.circle.fill" : "scope")
                Text(waiting ? cap.prompt + "  (click to cancel)" : title)
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(waiting ? Color.rec : Color.amber)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.slate))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(waiting ? Color.rec : Color.amber.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain).focusable(false).help(help)
        .accessibilityIdentifier("capture-" + slot)
    }
}

// MARK: a key as the script writes it

enum ScriptKeys {
    static let NAMES: [String: String] = [
        "return": "Enter", "padenter": "NumpadEnter", "escape": "Esc", "tab": "Tab", "space": "Space", "delete": "BS",
        "forwarddelete": "Del", "help": "Ins", "home": "Home", "end": "End", "pageup": "PgUp", "pagedown": "PgDn",
        "left": "Left", "right": "Right", "up": "Up", "down": "Down", "capslock": "CapsLock",
    ]

    /// the word the script uses for a key KeyMap names: return -> Enter, escape -> Esc, f5 -> F5
    static func word(_ hs: String) -> String {
        if let n = NAMES[hs] { return n }
        if hs.count >= 2, hs.hasPrefix("f"), Int(hs.dropFirst()) != nil { return hs.uppercased() }
        return hs
    }

    /// what goes into the Key field: Enter · a · ^c · ^{Enter} · +{Tab}  (modifiers: ^ Ctrl, ! Option, + Shift, # Command)
    static func field(_ mods: [String], _ hs: String) -> String {
        var pre = ""
        if mods.contains("ctrl") { pre += "^" }
        if mods.contains("alt") { pre += "!" }
        if mods.contains("shift") { pre += "+" }
        if mods.contains("cmd") { pre += "#" }
        if pre.isEmpty { return word(hs) }
        if hs.count == 1 && !"^!+#{}".contains(hs) { return pre + hs }
        return pre + "{" + word(hs) + "}"
    }
}

// MARK: the arguments of a command line, split at the commas that are not inside a string or brackets

enum ArgList {
    struct Split {
        var args: [String]
        var paren: Bool
    }

    static func split(_ value: String) -> Split {
        var v = value.trimmingCharacters(in: .whitespaces)
        var paren = false
        if v.hasPrefix("(") && v.hasSuffix(")") && v.count >= 2 { paren = true; v = String(v.dropFirst().dropLast()) }
        var args: [String] = [], cur = ""
        var quote: Character? = nil, depth = 0, skip = false
        for ch in v {
            if skip { cur.append(ch); skip = false; continue }
            if let q = quote {
                cur.append(ch)
                if ch == "`" { skip = true } else if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; cur.append(ch)
            case "(", "[", "{": depth += 1; cur.append(ch)
            case ")", "]", "}": depth -= 1; cur.append(ch)
            case "," where depth <= 0: args.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            default: cur.append(ch)
            }
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !args.isEmpty { args.append(last) }
        return Split(args: args, paren: paren)
    }

    static func join(_ s: Split) -> String {
        let body = s.args.joined(separator: ", ")
        return s.paren ? "(" + body + ")" : body
    }

    /// a string literal of the script language: ` escapes ` and " and the line breaks (`n `t `r)
    static func quote(_ text: String) -> String {
        var out = "\""
        for ch in text {
            switch ch {
            case "`": out += "``"
            case "\"": out += "`\""
            case "\n": out += "`n"
            case "\t": out += "`t"
            case "\r": out += "`r"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    /// true when the whole argument is one string literal: it opens at the start and closes at the very end
    static func isString(_ arg: String) -> Bool {
        let c = Array(arg.trimmingCharacters(in: .whitespaces))
        guard c.count >= 2, c[0] == "\"" else { return false }
        var i = 1
        while i < c.count {
            if c[i] == "`" { i += 2; continue }
            if c[i] == "\"" { return i == c.count - 1 }
            i += 1
        }
        return false
    }

    /// the text of a string literal without its quotes, the escapes undone; anything else comes back as it is
    static func unquote(_ arg: String) -> String {
        let t = arg.trimmingCharacters(in: .whitespaces)
        guard isString(t) else { return t }
        var out = "", skip = false
        for ch in t.dropFirst().dropLast() {
            if skip {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                skip = false
            } else if ch == "`" {
                skip = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
