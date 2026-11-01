// Engine.swift: record, play, the slots and the keys. macro.lua ported.
// One event tap writes down keys, clicks, drags and scrolls with the time between them; the moment it stops, the
// recording is written down as a script (Script.fromEvents). The player runs a script on its own thread through the
// host below, which posts the clicks and keys; Sleep sleeps that thread, and the stop key makes the next host call
// throw, so a loop with no Sleep is still stopped (the interpreter calls sleep(0) every few hundred statements).
import AppKit
import ApplicationServices
import Combine
import IOKit.hid

let REDC = NSColor(srgbRed: 0.95, green: 0.2, blue: 0.2, alpha: 1)
let GREENC = NSColor(srgbRed: 0x33/255.0, green: 0xD1/255.0, blue: 0x7A/255.0, alpha: 1)
let GREYC = NSColor(white: 0.6, alpha: 1)

final class Engine: ObservableObject {
    static let shared = Engine()
    let settings = Settings()
    @Published var recording = false
    @Published var playing = false
    @Published var current: String?            // the macro in the player; nil = the plain last recording
    @Published var note = ""                   // one line for the window and the status line
    @Published var lastError: (name: String, line: Int?, msg: String)?
    @Published var capturing: String?          // the action whose key is being caught
    @Published var tick = 0                    // anything on disk changed: the window reads again
    var text: String?                          // the script in the player
    var pending: String?                       // the name a New Macro recording is saved under
    var playName = ""

    // MARK: start and stop (ON and OFF)

    func start() {
        mkdirs(DIR, MAC_DIR, IMG_DIR)
        settings.load()
        if let c = settings.current { _ = loadMacro(c, quiet: true) }
        bindKeys()
        Inbox.shared.start()
    }
    func stop() {
        if recording { stopRecording() }
        if playing { stopPlaying() }
        capture.stop()
        Hotkeys.shared.unbindAll()
        Inbox.shared.stop()
        Overlay.shared.off(); Overlay.shared.spinKill()
    }
    func changed() { DispatchQueue.main.async { self.tick += 1 } }

    // MARK: a word for a moment, bottom middle (his request 6.9.2026); while recording or playing the line is theirs

    func say(_ t: String, _ c: NSColor = GREYC, _ secs: Double = 1.4) {
        DispatchQueue.main.async {
            self.note = t
            if self.recording || self.playing { return }
            Overlay.shared.show(t, c, for: secs)
        }
    }
    func sayWhilePlaying(_ t: String, _ secs: Double) {
        DispatchQueue.main.async {
            guard self.playing else { return self.say(t, GREYC, secs) }
            self.note = t
            Overlay.shared.show(t, GREENC, for: secs) { [weak self] in
                guard let s = self, s.playing else { return }
                Overlay.shared.show("PLAY  " + s.playName, GREENC)
            }
        }
    }
    // the star's colour: red while recording, green while playing (the Swift star listens if it can)
    func tint(_ c: String) {
        DistributedNotificationCenter.default().postNotificationName(.init("community.auroville.star.tint"), object: c, userInfo: nil, deliverImmediately: true)
    }

    // MARK: recording

    var tap: CFMachPort?
    var events: [RecEvent] = []
    let view = RecordingView()            // v8: the windows clicked in, for RECALIBRATE
    var t0 = 0.0
    static let KINDS: [CGEventType: String] = [
        .keyDown: "keyDown", .keyUp: "keyUp", .leftMouseDown: "leftMouseDown", .leftMouseUp: "leftMouseUp",
        .rightMouseDown: "rightMouseDown", .rightMouseUp: "rightMouseUp", .otherMouseDown: "otherMouseDown",
        .otherMouseUp: "otherMouseUp", .mouseMoved: "mouseMoved", .leftMouseDragged: "leftMouseDragged",
        .rightMouseDragged: "rightMouseDragged", .otherMouseDragged: "otherMouseDragged", .scrollWheel: "scrollWheel",
    ]

    // the keys that start and stop a recording are not part of it: record, stop, play, and any of their keys in the
    // first second, while the fingers are still coming off the chord (LESSONS 2)
    func isOurHotkey(_ code: Int, _ mods: [String], _ since: Double) -> Bool {
        for id in ["record", "stop", "play"] {
            guard let b = settings.keys[id], KeyMap.codes[b.key] == code else { continue }
            if sameMods(b.mods, mods.filter { $0 != "fn" }) || since < 1 { return true }
        }
        return false
    }

    func onEvent(_ type: CGEventType, _ e: CGEvent) {
        guard recording, let kind = Engine.KINDS[type] else { return }
        let t = Date().timeIntervalSince1970 - t0
        var ev = RecEvent(kind: kind, t: t, mods: KeyMap.mods(e.flags, fn: true))
        switch type {
        case .keyDown, .keyUp:
            let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
            if isOurHotkey(code, ev.mods ?? [], t) { return }
            if type == .keyDown && e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }   // LESSONS 4
            ev.code = code
        case .scrollWheel:
            ev.dy = Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            ev.dx = Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            ev.x = e.location.x; ev.y = e.location.y
        default:
            ev.x = e.location.x; ev.y = e.location.y
            if kind.hasPrefix("other") { ev.button = Int(e.getIntegerValueField(.mouseEventButtonNumber)) }
            // v8: the window under the pointer, pictured before it is clicked (RECALIBRATE's view)
            if kind == "mouseMoved" || kind.hasSuffix("MouseDown") { view.pointer(e.location, click: kind.hasSuffix("MouseDown")) }
        }
        events.append(ev)
    }

    func startRecording() {
        if playing { stopPlaying() }
        guard tap == nil else { return }
        var mask: CGEventMask = 0
        for t in Engine.KINDS.keys { mask |= 1 << t.rawValue }
        let cb: CGEventTapCallBack = { _, type, e, ref in
            let me = Unmanaged<Engine>.fromOpaque(ref!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else { me.onEvent(type, e) }
            return Unmanaged.passUnretained(e)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            say("cannot listen to the keyboard: allow Input Monitoring for Macro Recorder (Mantra)", GREYC, 5)
            pending = nil
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        events = []; t0 = Date().timeIntervalSince1970
        view.reset()
        // the window under the pointer now is pictured at once (the first click may come before any move)
        view.pointer(CGEvent(source: nil)?.location ?? .zero, click: false)
        recording = true
        Overlay.shared.show("REC" + (pending.map { "  " + $0 } ?? ""), REDC)
        tint("red")
    }

    @discardableResult func stopRecording() -> Int {
        recording = false
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil
        Overlay.shared.off(); tint("")
        // the chord pressed to stop is not part of it: our keys at the very end are dropped
        let ours = Set(["record", "stop", "play"].compactMap { settings.keys[$0].flatMap { KeyMap.codes[$0.key] } })
        while let l = events.last, l.kind == "keyDown" || l.kind == "keyUp", ours.contains(l.code ?? -1) { events.removeLast() }
        mkdirs(DIR, REC_DIR)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let recorded = f.string(from: Date())
        // the raw events are kept by date, always; the macro itself is a script
        let enc = JSONEncoder()
        if let evd = try? enc.encode(events), let evj = try? JSONSerialization.jsonObject(with: evd),
           let d = try? JSONSerialization.data(withJSONObject: ["version": 1, "recorded": recorded, "events": evj]) {
            try? d.write(to: URL(fileURLWithPath: LAST_JSON))
            try? d.write(to: URL(fileURLWithPath: REC_DIR + "/" + Macros.croName() + ".json"))
        }
        let title = (pending ?? "last recording") + ", recorded " + recorded
        let t = Script.fromEvents(events, keyNames: KeyMap.names,
                                  header: [title, "Edit freely: Click x, y  ·  Send \"text\"  ·  Sleep ms  ·  ClickImage \"button.png\""])
        _ = writeText(LAST_AHK, t)
        text = t
        if let p = pending {
            Macros.write(p, t)
            current = p; pending = nil
            let slot = Slots.autoPlace(&settings.slots, p)
            say(slot.map { "saved \(p)  in slot \($0)" } ?? "saved " + p, GREENC, 2)
            view.store(p) { [weak self] v in if v != nil { self?.changed() } }
        } else {
            current = nil
            say("\(events.count) events recorded", GREYC, 1.4)
        }
        settings.current = current; settings.save()
        changed()
        return events.count
    }
    func toggleRecording() { recording ? { _ = stopRecording() }() : startRecording() }

    // MARK: macros

    func loadMacro(_ n: String, quiet: Bool = false) -> Bool {
        let r = Macros.read(n)
        guard let t = r.text else { if !quiet { say(r.why, GREYC, 2) }; return false }
        text = t; current = n; settings.current = n; settings.save()
        if !quiet { say("in the player: " + n) }
        changed(); return true
    }
    // a new macro with its name: record until the record key, saved under that name
    func newMacroNamed(_ s: String) {
        if recording { stopRecording() }
        if playing { stopPlaying() }
        var n = Macros.clean(s); if n.isEmpty { n = Macros.croName() }
        if Macros.exists(n) { return say("there is already a macro called " + n, GREYC, 2) }
        pending = n; startRecording()
    }
    // the New Macro key: a box asks the name
    func newMacro() {
        if recording { stopRecording() }
        if playing { stopPlaying() }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "New macro"
        a.informativeText = "Name it, then press \(keyLabel(settings.keys["record"])) when you are done recording."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = Macros.croName()
        a.accessoryView = f; a.addButton(withTitle: "Record"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { newMacroNamed(f.stringValue) }
    }
    // a new, empty script to write in the editor; it takes the first free slot
    func newScript(_ s: String) -> String? {
        var n = Macros.clean(s); if n.isEmpty { n = Macros.croName() }
        if Macros.exists(n) { say("there is already a macro called " + n, GREYC, 2); return nil }
        Macros.write(n, "; \(n)\n; Click x, y  ·  Send \"text\"  ·  Sleep ms  ·  ClickImage \"button.png\"\n\n")
        Slots.autoPlace(&settings.slots, n); settings.save(); changed()
        return n
    }
    // save from the editor: the text is kept whatever it says; a parse error comes back as a warning with its line
    func saveScript(_ n: String, _ t: String) -> (ok: Bool, warn: String?, line: Int?) {
        let n = Macros.clean(n)
        guard !n.isEmpty else { return (false, "no name", nil) }
        if let e = Macros.write(n, t) { return (false, e, nil) }
        if current == n { text = t }
        changed()
        if case .failure(let e) = Script.parse(t) { return (true, "saved, but " + e.text, e.line) }
        return (true, nil, nil)
    }
    func rename(_ old: String, _ s: String) {
        let n = Macros.clean(s)
        guard !n.isEmpty, n != old else { return }
        if Macros.exists(n) { return say("there is already a macro called " + n, GREYC, 2) }
        if let e = Macros.rename(old, n) { return say(e, GREYC, 2) }
        Slots.rename(&settings.slots, old, n)
        Refs.rename(old, n)
        if current == old { current = n; settings.current = n }
        settings.save(); say("renamed to " + n); changed()
    }
    func trash(_ n: String) {
        if let e = Macros.trash(n) { return say(e, GREYC, 2) }
        Refs.trash(n)
        Slots.remove(&settings.slots, n)
        if current == n { current = nil; settings.current = nil; text = nil }
        settings.save(); say(n + " moved to the trash folder", GREYC, 1.6); changed()
    }
    func slotsChanged() { settings.save(); changed() }

    // MARK: the slots from the keyboard

    func loadSlot(_ s: String) {
        guard let n = settings.slots[s] else { return say("slot \(s) is empty") }
        _ = loadMacro(n)
    }
    func runSlot(_ s: String) {
        guard let n = settings.slots[s] else { return say("slot \(s) is empty") }
        if recording { stopRecording() }
        runNamed(n)
    }
    func runNamed(_ n: String) { runMacro(n) }
    // v8: a stored macro is played; when its window stands elsewhere now (or has another size) and AUTO is on, it is
    // recalibrated first, then played from the corrected file
    func runMacro(_ n: String, done: ((Bool, String?, Int?) -> Void)? = nil) {
        let go = { [weak self] (note: String?) in
            guard let s = self else { return }
            guard s.loadMacro(n, quiet: true), let t = s.text else { done?(false, "no macro called " + n, nil); return }
            s.runScript(t, n, done: done)
            if let m = note { s.sayWhilePlaying("recalibrated first: " + m, 3) }
        }
        guard settings.autoRecal, Macros.kind(n) == "script", has(Refs.dir(n) + "/view.json") else { return go(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            var note: String?
            if Recal.differs(n) { note = Recal.recalibrate(n).summary }
            DispatchQueue.main.async { go(note) }
        }
    }
    // v8: RECALIBRATE from the window: the clicks follow the window to where it is now
    func recalibrate(_ n: String) {
        if recording { return say("stop the recording first", GREYC, 2) }
        say("recalibrating " + n + "…", GREYC, 8)
        Overlay.shared.spinStart()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Recal.recalibrate(n)
            DispatchQueue.main.async {
                Overlay.shared.spinEnd()
                if self.current == n { _ = self.loadMacro(n, quiet: true) }
                self.say(r.summary, r.ok ? GREENC : GREYC, 5); self.changed()
            }
        }
    }
    // v8: VIEW from the window: the macro fits the screen as it is now; store that as its view
    func storeView(_ n: String) {
        if recording { return say("stop the recording first", GREYC, 2) }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Recal.reference(n)
            DispatchQueue.main.async { self.say(r.summary, r.ok ? GREENC : GREYC, 4); self.changed() }
        }
    }

    // MARK: playing

    let host = MacHost()
    var runId = 0

    func runScript(_ t: String, _ name: String, done: ((Bool, String?, Int?) -> Void)? = nil) {
        if playing { stopPlaying() }
        switch Script.parse(t) {
        case .failure(let e):
            lastError = (name, e.line, e.text); say(e.text, GREYC, 4); done?(false, e.text, e.line)
        case .success(let prog):
            runId += 1
            let id = runId
            playing = true; lastError = nil; playName = name
            host.stopped = false; host.lastClickAt = 0
            host.speed = settings.speed > 0 ? settings.speed : 1; host.clickDelay = settings.clickDelay
            Overlay.shared.show("PLAY  " + name, GREENC); tint("green")
            let speed = host.speed
            Thread.detachNewThread {
                let r = Script.run(prog, host: self.host, speed: speed)
                DispatchQueue.main.async {
                    guard self.runId == id else { return }
                    let stopped = self.host.stopped
                    self.stopPlaying()
                    done?(r.ok, r.ok ? nil : (stopped ? "stopped" : (r.message ?? "error")), r.line)
                    if r.ok { self.say("done: " + name, GREYC, 1.2) }
                    else if !stopped {
                        self.lastError = (name, r.line, r.message ?? "error")
                        self.say(r.message ?? "error", GREYC, 4)
                    }
                }
            }
        }
    }
    // PLAY: what is in the player, else the last recording
    func play() {
        if recording { stopRecording() }
        var t = text, n = current ?? "last recording"
        if t?.isEmpty ?? true { t = readText(LAST_AHK); n = "last recording" }
        guard let s = t, !s.isEmpty else { return say("nothing in the player yet") }
        if let c = current, n == c, Macros.kind(c) == "script" { return runMacro(c) }
        runScript(s, n)
    }
    func stopPlaying() {
        host.stopped = true
        playing = false
        Overlay.shared.spinKill(); Overlay.shared.off(); tint("")
    }
    func togglePlay() { playing ? stopPlaying() : play() }
    // the stop key: whatever runs stops; a recording stopped this way is saved
    func stopAll() {
        if recording { stopRecording() }
        if playing { stopPlaying() }
    }

    // MARK: pictures and zones

    func regionFor(_ file: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CGRect? {
        if x2 > x1 && y2 > y1 { return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1) }
        if let z = settings.zones[file] { return CGRect(x: z.x, y: z.y, width: z.w, height: z.h) }
        return nil
    }
    // the system's own cross-hair, then the file lands in the images folder
    func snap(_ s: String, then: ((String?) -> Void)? = nil) {
        mkdirs(DIR, IMG_DIR)
        var n = Macros.clean(s); if n.lowercased().hasSuffix(".png") { n = String(n.dropLast(4)) }
        if n.isEmpty { n = "button " + Macros.croName() }
        var path = IMG_DIR + "/" + n + ".png", i = 2
        while has(path) { path = IMG_DIR + "/\(n) \(i).png"; i += 1 }
        let file = (path as NSString).lastPathComponent
        say("drag over the button on the screen. Esc cancels", GREYC, 12)
        crosshair(path) {
            if has(path) { self.say("picture saved: " + file, GREENC, 2.5); self.changed(); then?(file) }
            else { self.say("no picture taken", GREYC, 1.6); then?(nil) }
        }
    }
    func crosshair(_ path: String, _ done: @escaping () -> Void) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-i", "-x", path]
        p.terminationHandler = { _ in DispatchQueue.main.async(execute: done) }
        try? p.run()
    }
    // a zone is drawn with the same cross-hair; its place is recovered by finding the capture back (LESSONS 29, 30)
    func captureZone(_ prompt: String, _ cb: @escaping (CGRect?) -> Void) {
        mkdirs(DIR, TMP_DIR)
        let tmp = TMP_DIR + "/zone.png"; try? fm.removeItem(atPath: tmp)
        say(prompt, GREYC, 12)
        crosshair(tmp) {
            guard has(tmp) else { return cb(nil) }
            self.say("placing the zone…", GREYC, 3)
            Overlay.shared.spinStart()
            DispatchQueue.global().async {
                let r = Eye.search(tmp, region: nil, threshold: 0.7)
                try? fm.removeItem(atPath: tmp)
                DispatchQueue.main.async {
                    Overlay.shared.spinEnd()
                    cb(r.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) })
                }
            }
        }
    }
    func setZone(_ file: String) {
        captureZone("drag the SEARCH ZONE for \(file) (over the button, a little around it). Esc keeps all screens") { r in
            guard let r = r else { return self.say("zone unchanged (could not place it, or cancelled)", GREYC, 2) }
            self.settings.zones[file] = Zone(x: r.minX, y: r.minY, w: r.width, h: r.height); self.settings.save()
            self.say("zone for \(file): \(Int(r.width)) × \(Int(r.height))", GREENC, 2.2); self.changed()
        }
    }
    func clearZone(_ file: String) {
        settings.zones[file] = nil; settings.save(); say(file + " searches all screens", GREYC, 1.6); changed()
    }
    // the two steps he asked for: snap the button, then its search zone; Esc on the second keeps every screen
    func newPattern(_ s: String) {
        snap(s) { file in
            guard let file = file else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.captureZone("now drag the SEARCH ZONE for \(file), or Esc to search all screens") { r in
                    if let r = r {
                        self.settings.zones[file] = Zone(x: r.minX, y: r.minY, w: r.width, h: r.height); self.settings.save()
                        self.say("\(file) ready, zone \(Int(r.width)) × \(Int(r.height))", GREENC, 2.5)
                    } else { self.say(file + " ready, searches all screens", GREENC, 2.2) }
                    self.changed()
                }
            }
        }
    }
    // find it now: look (in its own zone), move the mouse there, say the score
    func findTest(_ file: String) {
        Overlay.shared.spinStart()
        let region = regionFor(file, 0, 0, 0, 0)
        DispatchQueue.global().async {
            let r = Eye.search(Pictures.path(file), region: region)
            DispatchQueue.main.async {
                Overlay.shared.spinEnd()
                guard let r = r else { return self.say("not on the screen now: " + file, GREYC, 2.5) }
                CGWarpMouseCursorPosition(CGPoint(x: r.x + r.w / 2, y: r.y + r.h / 2))
                self.say(String(format: "found %@ at %d, %d (%.0f%%)", file, Int(r.x), Int(r.y), r.score * 100), GREENC, 2.5)
            }
        }
    }
    func trashPicture(_ file: String) {
        mkdirs(TRASH_DIR)
        var dest = TRASH_DIR + "/" + file
        if has(dest) { dest = TRASH_DIR + "/" + Macros.stamp() + " " + file }
        do { try fm.moveItem(atPath: IMG_DIR + "/" + file, toPath: dest) } catch { return say("could not move: \(error.localizedDescription)", GREYC, 2) }
        settings.zones[file] = nil; settings.save()
        say(file + " moved to the trash folder", GREYC, 1.6); changed()
    }

    // MARK: the keys

    var openWindow: () -> Void = {}
    let capture = KeyCapture()

    func bindKeys() {
        let H = Hotkeys.shared
        H.unbindAll()
        let fns: [String: () -> Void] = [
            "record": { [unowned self] in self.toggleRecording() },
            "play": { [unowned self] in self.togglePlay() },
            "stop": { [unowned self] in self.stopAll() },
            "newMacro": { [unowned self] in self.newMacro() },
            "settings": { [unowned self] in self.openWindow() },
        ]
        for a in ACTIONS { if let b = settings.keys[a.id] { H.bind(b, fns[a.id]!) } }
        for d in Slots.ORDER { H.bind(Binding(mods: settings.loadMods, key: d)) { [unowned self] in self.loadSlot(d) } }
        if !sameMods(settings.runMods, settings.loadMods) {
            for d in Slots.ORDER { H.bind(Binding(mods: settings.runMods, key: d)) { [unowned self] in self.runSlot(d) } }
        }
    }
    // the next chord pressed (with a modifier, or a function key) becomes the action's key; Esc keeps the old one
    func captureKey(_ id: String) {
        capturing = id
        say("press the keys now. Esc keeps " + keyLabel(settings.keys[id]), GREYC, 15)
        capture.start(id, { [unowned self] mods, name in
            if name == "escape" { self.captureDone("kept " + keyLabel(self.settings.keys[id])); return true }
            if mods.isEmpty && !(name.hasPrefix("f") && Int(name.dropFirst()) != nil) {
                self.say("hold a modifier, or use a function key", GREYC, 2); return false
            }
            if let e = self.settings.setKey(id, mods, name) { self.say(e, GREYC, 2.5); return false }
            self.captureDone("the key is now " + keyLabel(self.settings.keys[id])); return true
        }, { [unowned self] in self.captureDone("no key pressed, kept " + keyLabel(self.settings.keys[id])) })
    }
    func captureDone(_ t: String) {
        capturing = nil; bindKeys(); say(t, GREYC, 2); changed()
    }
    func setMods(_ which: String, _ m: [String]) {
        if let e = settings.setMods(which, m) { say(e, GREYC, 2.5) } else { bindKeys() }
        changed()
    }
    func resetKeys() { settings.resetKeys(); bindKeys(); say("keys back to the defaults", GREYC, 1.6); changed() }
}

// MARK: the three permissions: what is allowed, and the way to the page that allows the rest

enum Permissions {
    static func state() -> (access: Bool, input: Bool, screen: Bool, all: Bool) {
        let a = AXIsProcessTrusted()
        // a listen-only tap is allowed with Accessibility too (measured 30.10.2026: the recording worked with only that)
        let i = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted || a
        let s = CGPreflightScreenCaptureAccess()
        return (a, i, s, a && i && s)
    }
    // the page of the first permission still missing
    static func openMissing() {
        let p = state()
        ask(!p.access ? "Accessibility" : !p.screen ? "ScreenCapture" : "ListenEvent")
    }
    // asks once through the system (which adds the app to the list), then opens the page itself
    static func ask(_ pane: String) {
        switch pane {
        case "ScreenCapture": _ = CGRequestScreenCaptureAccess()
        case "ListenEvent": _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        default: _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane)!)
    }
}

// MARK: the host the language runs on

final class MacHost: ScriptHost {
    var stopped = false
    var speed = 1.0, clickDelay = 0.0
    var lastClickAt = 0.0
    let src = CGEventSource(stateID: .hidSystemState)
    var e: Engine { Engine.shared }

    func check() throws { if stopped { throw ScriptStopped() } }
    func now() -> Double { Date().timeIntervalSince1970 }
    // Sleep sleeps this thread in small steps, so the stop key is felt within a hundredth of a second
    func wait(_ s: Double) throws {
        try check()
        let end = now() + max(0, s)
        while now() < end { Thread.sleep(forTimeInterval: min(0.01, end - now())); try check() }
    }
    func sleep(_ seconds: Double) throws { try wait(seconds > 0 ? seconds / speed : 0) }

    func pos() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
    static let BUTTONS: [String: (CGEventType, CGEventType, CGEventType, CGMouseButton)] = [
        "left": (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left),
        "right": (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right),
        "middle": (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center),
    ]
    func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton, _ mods: [String], _ clicks: Int? = nil) {
        guard let ev = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b) else { return }
        ev.flags = KeyMap.flags(mods)
        if b == .center { ev.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        if let c = clicks { ev.setIntegerValueField(.mouseEventClickState, value: Int64(c)) }
        ev.post(tap: .cghidEventTap)
    }
    func move(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p); CGAssociateMouseAndMouseCursorPosition(1)
        mouse(.mouseMoved, p, .left, [])
    }
    func mouseMove(_ x: Double, _ y: Double) throws { try check(); move(CGPoint(x: x, y: y)) }
    func click(_ button: String, _ x: Double?, _ y: Double?, _ times: Int, _ mods: [String]) throws {
        try check()
        let b = MacHost.BUTTONS[button] ?? MacHost.BUTTONS["left"]!
        let p = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : pos()
        // the rhythm setting: every click at least this long after the last one
        if clickDelay > 0 { let since = now() - lastClickAt; if since < clickDelay { try wait(clickDelay - since) } }
        move(p); try wait(0.01)
        let n = max(1, times)
        for i in 1...n {
            mouse(b.0, p, b.3, mods, i); mouse(b.1, p, b.3, mods, i)
            if i < n { try wait(0.06) }
        }
        lastClickAt = now()
    }
    func buttonDownUp(_ button: String, _ down: Bool, _ x: Double?, _ y: Double?, _ mods: [String]) throws {
        try check()
        let b = MacHost.BUTTONS[button] ?? MacHost.BUTTONS["left"]!
        let p = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : pos()
        move(p); mouse(down ? b.0 : b.1, p, b.3, mods)
    }
    func drag(_ button: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ mods: [String]) throws {
        try check()
        let b = MacHost.BUTTONS[button] ?? MacHost.BUTTONS["left"]!
        move(CGPoint(x: x1, y: y1)); try wait(0.02)
        mouse(b.0, CGPoint(x: x1, y: y1), b.3, mods)
        for i in 1...12 {
            let t = Double(i) / 12
            mouse(b.2, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t), b.3, mods)
            try wait(0.015)
        }
        mouse(b.1, CGPoint(x: x2, y: y2), b.3, mods)
        lastClickAt = now()
    }
    func mousePos() -> (Int, Int) { let p = pos(); return (Int(p.x.rounded()), Int(p.y.rounded())) }
    func code(_ name: String) throws -> CGKeyCode {
        guard let c = KeyMap.codes[name] else { throw ScriptError(line: nil, msg: "no key called {\(name)}") }
        return CGKeyCode(c)
    }
    func keyEvent(_ c: CGKeyCode, _ down: Bool, _ mods: [String]) {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: down) else { return }
        ev.flags = KeyMap.flags(mods); ev.post(tap: .cghidEventTap)
    }
    func key(_ mods: [String], _ name: String) throws {
        try check()
        let c = try code(name)
        keyEvent(c, true, mods); keyEvent(c, false, mods)
        try wait(0.012)
    }
    func keyDownUp(_ name: String, _ down: Bool, _ mods: [String]) throws { try check(); keyEvent(try code(name), down, mods) }
    // any character, including ones with no key: typed as text, like hs.eventtap.keyStrokes
    func type(_ text: String) throws {
        for ch in text {
            try check()
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                ev.flags = []
                ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                ev.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    func wheel(_ dir: String, _ times: Int, _ mods: [String]) throws {
        try check()
        var dx: Int32 = 0, dy: Int32 = 0
        switch dir { case "down": dy = -Int32(times); case "up": dy = Int32(times)
        case "left": dx = Int32(times); case "right": dx = -Int32(times); default: break }
        if let ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
            ev.flags = KeyMap.flags(mods); ev.post(tap: .cghidEventTap)
        }
        try wait(0.05)
    }
    // the search runs on this thread (the player's own), so the main thread is free and the spinner turns
    func imageSearch(_ file: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) throws -> ImageHit? {
        try check()
        let path = Pictures.path(file)
        guard has(path) else { e.say("no picture called " + file, GREYC, 2); return nil }
        let region = e.regionFor(file, x1, y1, x2, y2)
        DispatchQueue.main.async { Overlay.shared.spinStart() }
        defer { DispatchQueue.main.async { Overlay.shared.spinEnd() } }
        let r = Eye.search(path, region: region)
        try check()
        return r
    }
    func searchHold(_ on: Bool) { DispatchQueue.main.async { on ? Overlay.shared.spinStart() : Overlay.shared.spinEnd() } }
    func pixel(_ x: Double, _ y: Double) -> String { Eye.pixel(x, y) }
    func say(_ text: String, _ long: Bool) { e.sayWhilePlaying(text, long ? 3 : 1.6) }
    func run(_ what: String) {
        let w = what.hasPrefix("~") ? HOME + what.dropFirst() : what
        DispatchQueue.main.async {
            if w.hasPrefix("http://") || w.hasPrefix("https://") || w.hasPrefix("file:") { NSWorkspace.shared.open(URL(string: w)!); return }
            // v9 (1.11.2026, for Elevate Media Project Monitor's ▶ FINISH): an executable file (a script, a .command) is RUN,
            // as AutoHotkey's Run does, with any words after it as its arguments; a document or an app is opened as before
            let parts = w.split(separator: " ", maxSplits: 1).map(String.init)
            let exe = FileManager.default.isExecutableFile(atPath: w) ? w : parts[0]
            var dir: ObjCBool = false
            if exe.hasPrefix("/"), !exe.hasSuffix(".app"), FileManager.default.fileExists(atPath: exe, isDirectory: &dir), !dir.boolValue,
               FileManager.default.isExecutableFile(atPath: exe) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe)
                if exe != w, parts.count > 1 { p.arguments = parts[1].split(separator: " ").map(String.init) }
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); return
            }
            if w.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: w)); return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", w]
            try? p.run()
        }
    }
    func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }
    func findApp(_ title: String) -> NSRunningApplication? {
        let t = title.lowercased()
        return NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").lowercased() == t }
            ?? NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "").lowercased().contains(t) && $0.activationPolicy == .regular }
    }
    func windowOwner(_ title: String) -> pid_t? {
        let t = title.lowercased()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { (($0[kCGWindowName as String] as? String) ?? "").lowercased().contains(t) }
            .flatMap { ($0[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } }
    }
    func activate(_ title: String) -> Bool {
        onMain {
            if let a = findApp(title) { return a.activate() }
            if let pid = windowOwner(title), let a = NSRunningApplication(processIdentifier: pid) { return a.activate() }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", title]
            try? p.run(); p.waitUntilExit()
            return p.terminationStatus == 0
        }
    }
    func winExists(_ title: String) -> Bool { onMain { findApp(title) != nil || windowOwner(title) != nil } }
    // MenuSelect (v6, 31.10.2026): the app's menu bar through Accessibility, each name matched without case, "…" = "..."
    func menuSelect(_ title: String, _ path: [String]) -> Bool {
        guard let app = onMain({ findApp(title) ?? windowOwner(title).flatMap { NSRunningApplication(processIdentifier: $0) } }) else { return false }
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "…", with: "...").lowercased().trimmingCharacters(in: .whitespaces) }
        func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
        func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = attr(ax, kAXMenuBarAttribute) else { return false }
        var level = [bar as! AXUIElement]
        for (n, name) in path.enumerated() {
            // the items of this level: the bar's items, or the items of the open menu under the last item
            let items = level.flatMap { kids($0) }.flatMap { (attr($0, kAXRoleAttribute) as? String) == "AXMenu" ? kids($0) : [$0] }
            guard let hit = items.first(where: { clean((attr($0, kAXTitleAttribute) as? String) ?? "") == clean(name) })
                ?? items.first(where: { clean((attr($0, kAXTitleAttribute) as? String) ?? "").hasPrefix(clean(name)) }) else { return false }
            if n == path.count - 1 { return AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success }
            level = [hit]
        }
        return false
    }
    // WinGetPos (v6): a window whose title contains the text, else the app's biggest window (CGWindowList, screen points)
    func winGetPos(_ title: String) -> (Double, Double, Double, Double)? {
        let t = title.lowercased()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        func rect(_ w: [String: Any]) -> CGRect? { (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        if let w = list.first(where: { (($0[kCGWindowName as String] as? String) ?? "").lowercased().contains(t) }), let r = rect(w) {
            return (Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
        }
        guard let app = onMain({ findApp(title) }) else { return nil }
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let r = mine.compactMap(rect).max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return (Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
    }
    // Recalibrate "name" (v8): runs on the player's thread, so the pictures it takes do not stop the window
    func recalibrate(_ name: String) -> (Bool, String) {
        let r = Recal.recalibrate(name.isEmpty ? e.playName : name)
        return (r.ok, r.summary)
    }
    func clipboard() -> String { onMain { NSPasteboard.general.string(forType: .string) ?? "" } }
    func setClipboard(_ v: String) { onMain { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(v, forType: .string) } }
    func screen() -> (Double, Double) { onMain { let f = NSScreen.main?.frame ?? .zero; return (Double(f.width), Double(f.height)) } }
    func expand(_ p: String) -> String { p.hasPrefix("~/") ? HOME + p.dropFirst(1) : p }
    func fileExist(_ p: String) -> Bool { has(expand(p)) }
    func fileRead(_ p: String) -> String { readText(expand(p)) ?? "" }
    func fileAppend(_ text: String, _ p: String) {
        let path = expand(p)
        if !has(path) { fm.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile() }
    }
}

// MARK: the status line and the spinner, bottom middle of the screen with the pointer (his request 6.9.2026)

final class Overlay {
    static let shared = Overlay()
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    let label = NSTextField(labelWithString: "")
    let dot = NSView()
    let spin = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    let spinView = SpinnerView()
    var hide: DispatchWorkItem?
    var depth = 0

    init() {
        for p in [panel, spin] {
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]; p.hasShadow = false
        }
        let v = NSView(); v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 0.92).cgColor
        v.layer?.cornerRadius = 5
        dot.wantsLayer = true; dot.layer?.cornerRadius = 4; dot.frame = NSRect(x: 8, y: 9, width: 8, height: 8)
        label.font = .systemFont(ofSize: 11); label.textColor = .white
        v.addSubview(dot); v.addSubview(label); panel.contentView = v
        spin.contentView = spinView
    }
    func place(_ p: NSPanel, w: CGFloat, h: CGFloat) {
        let m = NSEvent.mouseLocation
        let f = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main!).frame
        // centred along the bottom edge, a little above it to clear the Dock
        p.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 46, width: w, height: h), display: true)
    }
    func show(_ t: String, _ c: NSColor, for secs: Double? = nil, after: (() -> Void)? = nil) {
        label.stringValue = t; label.sizeToFit()
        let w = max(70, min(440, label.frame.width + 34)), h: CGFloat = 26
        place(panel, w: w, h: h)
        label.frame.origin = NSPoint(x: 22, y: 5)
        dot.layer?.backgroundColor = c.cgColor
        panel.orderFrontRegardless()
        hide?.cancel(); hide = nil
        if let s = secs {
            let job = DispatchWorkItem { [weak self] in
                if let a = after { a() } else { self?.panel.orderOut(nil) }
            }
            hide = job; DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: job)
        }
    }
    func off() { hide?.cancel(); hide = nil; panel.orderOut(nil) }
    // reference counted, so a ClickImage that looks again and again keeps one steady spinner
    func spinStart() {
        depth += 1
        guard depth == 1 else { return }
        place(spin, w: 210, h: 30)
        // above the status line when both show
        var f = spin.frame; f.origin.y += 32; spin.setFrame(f, display: true)
        spinView.start(); spin.orderFrontRegardless()
    }
    func spinEnd() { depth = max(0, depth - 1); if depth == 0 { spinView.stop(); spin.orderOut(nil) } }
    func spinKill() { depth = 0; spinView.stop(); spin.orderOut(nil) }
}

final class SpinnerView: NSView {
    var angle: CGFloat = 0
    var timer: Timer?
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in self?.angle -= 0.5; self?.needsDisplay = true }
    }
    func stop() { timer?.invalidate(); timer = nil }
    override func draw(_ r: NSRect) {
        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let cx: CGFloat = 15, cy: CGFloat = bounds.midY, rad: CGFloat = 8
        // a turning arc of short segments, brightest at the head
        for i in 0..<12 {
            let a = angle - CGFloat(i) * (2 * .pi / 12)
            GREENC.withAlphaComponent(0.15 + 0.85 * (1 - CGFloat(i) / 12)).setStroke()
            let p = NSBezierPath(); p.lineWidth = 2.4; p.lineCapStyle = .round
            p.move(to: NSPoint(x: cx + cos(a) * (rad - 3), y: cy + sin(a) * (rad - 3)))
            p.line(to: NSPoint(x: cx + cos(a) * rad, y: cy + sin(a) * rad)); p.stroke()
        }
        ("searching for a pattern" as NSString).draw(at: NSPoint(x: 30, y: cy - 8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.95)])
    }
}
