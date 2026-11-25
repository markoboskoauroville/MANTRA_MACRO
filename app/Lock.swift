// Lock.swift: THE INPUT LOCK (v24, 13.11.2026). A port of the phone's Lock.kt (VOICE_ENGINE_ANDROID, v7 to v15) from Kotlin
// to Swift. Marko: "simply copy the system from the phone to this Mac ... We developed the logic on the phone. The user
// interface on the phone: you just need to convert from Kotlin to Swift." Same states (off, on, overridden, requested),
// same words, same colours, same layout: a thin dark bar (#101114) with orange (#E8A33D) bold words, left
// "CLAUDE · <time> · <what>", right the orange TAKE OVER; after TAKE OVER the small orange blob "GIVE THE MAC BACK TO
// CLAUDE" at the right edge; "CLAUDE ASKS FOR THE MAC" when a session asks. Nothing is dimmed, nothing in the middle.
// On the Mac the lock is part of the macro engine: it goes on when any script runs (Engine.runScript) and off at its end.
// What the phone's overlay did with a touch layer, the Mac does with an active event tap (.defaultTap) that swallows
// Marko's physical mouse, scroll and key events; the macro's own events carry MACRO_MARK and pass.
//
// v34 (25.11.2026), Marko: "I have a system already in place which just shows that you took over and that I can take over.
// And now it's not appearing anymore. ... I see you have finished the task and I still cannot use my computer for a long
// time." Two causes, two fixes:
// 1. THE BAR WAS THERE BUT HIDDEN: the app had been launched hidden at login (LSLaunchedHidden, AXHidden true), and AppKit
//    keeps every window of a hidden app off screen, so the bar, the blob and the text blobs never appeared (CGWindowList:
//    kCGWindowIsOnscreen missing). Every overlay panel now has canHide = false, sits at the screen-saver level, is checked on
//    screen every second (re-ordered front, the app unhidden if it must be) and rebuilt when the displays change.
// 2. A LOCK HELD ACROSS THINKING: workers took `guard begin --seconds 180` and held it while they thought (257 s held for a
//    Gmail draft whose clicks took seconds). A holder now has a LEASE: every guarded step (POST /lock again, POST /ping,
//    POST /beat, a macro step the engine posts) renews it; 4 s without one and the Mac is his again (his place and keys
//    back); the next guarded step takes it again after his 1.5 s still moment. A lease lasts at most 60 s, renewed once
//    while busy, never beyond 90 s (the watchdog); its process gone (all pids that asked for it dead) lifts it at once.
//    Holders queue first come first served. Failsafes: Escape held 1 s (TAKE OVER), ⌃⌥⌘Esc (everything released at once),
//    POST /release-all (`guard release-all`, answered off the main thread), a stale lock cleared at start.
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
    // v34: TAKE OVER answers an Accessibility press too (VoiceOver, and the tests press it without a synthetic click)
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { DispatchQueue.main.async { self.onClick?() }; return true }
}
/// The blob: a click gives back. No dragging: it stays where TAKE OVER was.
private final class BlobView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { DispatchQueue.main.async { self.onClick?() }; return true }    // v34
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
    // v27 (14.11.2026) the guard API: one holder at a time, nested calls of the same holder, a short linger between steps
    private(set) var owner = ""                      // who holds a manual lock ("" = an old `macro lock` without owner)
    private var ownerDepth = 0
    private var ownerPid: pid_t = 0                  // the holder's process: gone -> the lock lifts at the next tick
    private var restoreAfter = true                  // put Marko back where he was when it lifts
    private var lingerTimer: Timer?
    // v28 (15.11.2026, Talk Mode's SPACE MODE): a holder may own the keyboard itself (keys pass, nothing recorded), show its
    // own full sentence on the bar, end without the GIVE THE MAC BACK blob, hold Escape longer, and keep the lock alive only
    // while it beats (POST /beat): no beat for `beat` seconds = the holder hangs, the lock lifts (the watchdog).
    private var passKeys = false, plainBar = false, noBlob = false
    private var escHold: TimeInterval = 1
    private var beatEvery: TimeInterval = 0
    private var lastBeat = Date()
    private(set) var ended = ""                      // how the last lock ended: unlock, takeover, escape, heartbeat, holder-gone, time
    // v29 (16.11.2026) PAUSE: while paused the lock stays on (its owner, its bar) but lets Marko's hands through
    private var pausedAt: Date?
    private var macroApp: NSRunningApplication?      // the app the macro had in front when it paused: front again on resume
    var isPaused: Bool { pausedAt != nil }
    struct Options { var passKeys = false; var plainBar = false; var noBlob = false; var escHold: TimeInterval = 1; var beat: TimeInterval = 0
                     var idle: TimeInterval = InputLock.LEASE_IDLE; var placeFront = false }
    // v34: the lease
    static let LEASE_IDLE: TimeInterval = 4          // no guarded step for this long: the Mac is his again
    static let LEASE_CAP: TimeInterval = 60          // one lease at most this long ...
    static let HARD_MAX: TimeInterval = 90           // ... renewed once while busy, never beyond this (the watchdog)
    private var leased = false                       // a manual hold without a heartbeat: idle and cap apply
    private var leaseIdle: TimeInterval = InputLock.LEASE_IDLE
    private var leaseStart = Date(), lastActivity = Date()
    private var leaseCap: TimeInterval = InputLock.LEASE_CAP
    private var extended = false
    private var ownerPids: [pid_t] = []              // every process that asked for this lease; all gone = lifted
    private var queue: [(owner: String, pid: pid_t, at: Date)] = []      // holders waiting, first come first served
    private let tapGuard = NSLock()                  // the tap is switched off from the server thread by /release-all
    private var emergency = false                    // set by /release-all and ⌃⌥⌘Esc: the tick never re-enables the tap
    private var visCheckAt = Date.distantPast
    private(set) var barProblem = ""                 // why a bar was not on screen the last time it was checked
    private let markerPath = NSHomeDirectory() + "/.mantra_macro/lock_held"

    // MARK: the engine's side: a run starts and ends

    /// A script starts. Returns nil when it may run, else why it is refused.
    func runBegin(name: String, by: Caller, seconds: Int?, hard: Int) -> String? {
        if by == .claude {
            if state == .overridden { return "overridden by Marko: the Mac is his until he gives it back (the orange blob GIVE THE MAC BACK TO CLAUDE)" }
            if state == .requested { return "waiting for Marko: he has not yet clicked CLAUDE ASKS FOR THE MAC" }
        }
        runDepth += 1
        if state == .overridden || state == .requested { return nil }    // Marko's own run while he has the Mac: no lock
        if state == .on && manualHold { touch(); return nil }      // v34: a step of the holder renews its lease
        let t = seconds ?? 0
        who = by == .claude ? "CLAUDE" : "MACRO"
        if state == .off {
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            restoreAfter = idle < 60
        }
        engage(name, seconds: t, hard: hard, manual: false)
        return nil
    }
    /// the run's name goes on the bar even when a manual lock already holds it ("macro do" -> the macro's name)
    func setLabel(_ n: String) { if state == .on && !manualHold { label = n; lastText = n } }
    func runEnd() {
        runDepth = max(0, runDepth - 1)
        touch()
        if runDepth == 0 && !manualHold && state == .on { off() }
    }

    /// v34: the holder did something guarded: its lease starts again from now.
    func touch() { if state == .on { lastActivity = Date() } }

    // MARK: the phone's API: on, off, request, through

    /// POST /lock {text, seconds}. v34: an anonymous manual lock (`POST /lock` without owner, the inbox's `lock:`) is a
    /// lease too: 4 s without a guarded step and it lifts; never beyond 90 s.
    func on(_ text: String, seconds: Int = 0, by: Caller = .claude) {
        who = by == .claude ? "CLAUDE" : "MACRO"
        if state != .on { startLease(seconds: seconds, idle: InputLock.LEASE_IDLE) }
        touch()
        engage(text, seconds: seconds, hard: Int(InputLock.HARD_MAX), manual: true)
    }
    private func startLease(seconds: Int, idle: TimeInterval) {
        leased = true; extended = false
        leaseStart = Date(); lastActivity = Date()
        leaseIdle = max(1, min(30, idle))
        leaseCap = seconds > 0 ? min(InputLock.LEASE_CAP, Double(seconds)) : InputLock.LEASE_CAP
    }
    func off() {
        let wasOn = state == .on
        manualHold = false
        closeBars(); closeBlob(); removeTap()
        ticker?.invalidate(); ticker = nil
        lingerTimer?.invalidate(); lingerTimer = nil
        state = .off
        pausedAt = nil; macroApp = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        let r = restoreAfter, o = owner
        owner = ""; ownerDepth = 0; ownerPid = 0; ownerPids = []; restoreAfter = true; leased = false
        if wasOn && ended.isEmpty { ended = "unlock" }
        resetOptions()
        try? FileManager.default.removeItem(atPath: markerPath)
        if wasOn { GuardBook.shared.finish(ended, restore: r, holder: o); BlobCenter.shared.lockReleased() }       // v32: "You can use the computer now"
    }

    /// v34, the failsafe: everything released, whatever state it is in (TAKE OVER's blob, a request, a wedged give-back,
    /// the queue). POST /release-all, ⌃⌥⌘Esc, `guard release-all`.
    func releaseAll(_ why: String) {
        emergency = false
        queue.removeAll()
        if state == .on { ended = why; off() }
        else {
            closeBars(); closeBlob(); removeTap()
            ticker?.invalidate(); ticker = nil
            if state != .off { ended = why }
            state = .off; manualHold = false; owner = ""; ownerDepth = 0; ownerPids = []; leased = false
            CGAssociateMouseAndMouseCursorPosition(1)
            try? FileManager.default.removeItem(atPath: markerPath)
        }
        GuardBook.shared.unwedge()
        NSLog("[guard] release-all: %@", why)
    }
    /// Called by the server thread before it asks the main thread for anything: Marko's hands are free at once, even when
    /// the main thread hangs.
    func emergencyTapOff() {
        tapGuard.lock(); defer { tapGuard.unlock() }
        emergency = true
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
    }

    /// v34, at start: a lock cannot survive the app, but a marker left behind means the app ended while it was held:
    /// written down, and the mouse is surely tied to the cursor again.
    func startupCheck() {
        CGAssociateMouseAndMouseCursorPosition(1)
        if FileManager.default.fileExists(atPath: markerPath) {
            let was = (try? String(contentsOfFile: markerPath, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: markerPath)
            GuardBook.shared.logLine(["what": was.trimmingCharacters(in: .whitespacesAndNewlines), "reason": "stale",
                                      "notice": "stale lock cleared at start: Macro Recorder had ended while it was held"])
        }
    }

    // MARK: v27, the guard API (POST /lock with owner, POST /unlock with owner): Marko 14.11.2026, "this guard should be
    // available for any action happening by Claude or any of my star apps"

    /// Take the lock for `owner`. Busy (another holder, or a give-back still replaying) means: the caller waits and asks again.
    func guardLock(_ text: String, seconds: Int, owner o: String, pid: pid_t, restore: Bool, options: Options = Options()) -> [String: Any] {
        if state == .overridden { return ["ok": false, "overridden": true, "error": "overridden by Marko: the Mac is his until he clicks GIVE THE MAC BACK TO CLAUDE"] }
        if state == .requested { return ["ok": false, "busy": true, "error": "waiting for Marko to click CLAUDE ASKS FOR THE MAC"] }
        if state == .on && manualHold && owner == o {        // the same holder: nested, and its lease renewed
            lingerTimer?.invalidate(); lingerTimer = nil
            ownerDepth += 1
            if pid > 0 && !ownerPids.contains(pid) { ownerPids.append(pid) }
            if !restore { restoreAfter = false }
            on(text, seconds: seconds)
            return ["ok": true, "lock": state.rawValue, "depth": ownerDepth, "nested": true, "lease": leaseInfo()]
        }
        // anyone else waits its turn in the queue (first come, first served)
        func busy(_ by: String, _ why: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var r: [String: Any] = ["ok": false, "busy": true, "held_by": by, "text": lastText, "error": why,
                                    "queued": enqueue(o, pid), "queue": queue.count]
            extra.forEach { r[$0.key] = $0.value }
            return r
        }
        if GuardBook.shared.finishing { return busy("(giving back)", "the last lock is still giving Marko his keys back") }
        if state == .on {
            return busy(manualHold ? (owner.isEmpty ? "macro lock" : owner) : "macro run",
                        "held by " + (manualHold ? (owner.isEmpty ? "macro lock" : owner) : "a macro run"))
        }
        if PauseGate.shared.paused {     // v29: a new holder waits for RESUME (guard.py keeps waiting while "paused")
            return busy("(paused)", "Macro Recorder is paused: nothing new starts until RESUME", ["paused": true])
        }
        if let first = pruneQueue().first, first.owner != o {
            return busy(first.owner, "queued behind " + first.owner)
        }
        queue.removeAll { $0.owner == o }
        owner = o; ownerDepth = 1; ownerPid = pid; ownerPids = pid > 0 ? [pid] : []; restoreAfter = restore
        passKeys = options.passKeys; plainBar = options.plainBar; noBlob = options.noBlob
        escHold = max(1, min(5, options.escHold)); beatEvery = max(0, min(60, options.beat)); lastBeat = Date(); ended = ""
        GuardBook.shared.placeFront = options.placeFront
        if beatEvery > 0 {           // beating (Talk Mode's Space Mode, Marko's own mode): the beat is the watchdog, two hours at most
            who = "CLAUDE"; leased = false; engage(text, seconds: 0, hard: 7200, manual: true)
        } else {
            who = "CLAUDE"
            startLease(seconds: seconds, idle: options.idle)
            engage(text, seconds: seconds, hard: Int(InputLock.HARD_MAX), manual: true)
        }
        GuardBook.shared.placeFront = false
        if state != .on { let p = problem ?? "the lock did not come on"; owner = ""; ownerDepth = 0; ownerPid = 0; ownerPids = []; leased = false; return ["ok": false, "error": p] }
        var r: [String: Any] = ["ok": true, "lock": state.rawValue, "depth": 1, "lease": leaseInfo(), "his_app": GuardBook.shared.frontName]
        // the same holder came back after a pause: its own app and field come front again, so its next step lands there
        if let back = GuardBook.shared.refrontHolder(o) { r["refront"] = back }
        return r
    }

    /// v34: POST /ping {owner}: the holder is still working (its lease renewed). Answers like /beat.
    func ping(owner o: String) -> [String: Any] {
        if state == .on && !o.isEmpty && o == owner { touch(); lastBeat = Date(); return ["ok": true, "lock": state.rawValue, "owner": owner, "lease": leaseInfo()] }
        return ["ok": false, "lock": state.rawValue, "owner": owner, "ended": ended]
    }

    private func enqueue(_ o: String, _ pid: pid_t) -> Int {
        _ = pruneQueue()
        if let i = queue.firstIndex(where: { $0.owner == o }) { queue[i].at = Date(); return i + 1 }
        queue.append((owner: o, pid: pid, at: Date()))
        return queue.count
    }
    /// A waiting holder that stopped asking (8 s) or whose process is gone leaves the queue.
    private func pruneQueue() -> [(owner: String, pid: pid_t, at: Date)] {
        queue.removeAll { Date().timeIntervalSince($0.at) > 8 || ($0.pid > 0 && kill($0.pid, 0) != 0 && errno == ESRCH) }
        return queue
    }
    private func leaseInfo() -> [String: Any] {
        guard state == .on, leased else { return [:] }
        let now = Date()
        return ["idle_s": leaseIdle, "idle_left": max(0, (leaseIdle - now.timeIntervalSince(lastActivity)) * 10).rounded() / 10,
                "max_left": max(0, Int(leaseCap - now.timeIntervalSince(leaseStart))), "extended": extended,
                "hard_left": max(0, Int(deadline.timeIntervalSince(now)))]
    }

    /// Give it back. A linger keeps it held a moment so the same holder's next step does not hand Marko a half-done screen.
    func guardUnlock(owner o: String, lingerMs: Int) -> [String: Any] {
        guard state == .on else { return ["ok": true, "lock": state.rawValue] }
        if o.isEmpty && !owner.isEmpty { return ["ok": false, "error": "held by " + owner + ": an unlock without owner does not lift it"] }
        if !o.isEmpty && o != owner { return ["ok": false, "error": "held by " + (owner.isEmpty ? "macro lock" : owner) + ", not by " + o] }
        ownerDepth = max(0, ownerDepth - 1)
        if ownerDepth > 0 { return ["ok": true, "lock": state.rawValue, "depth": ownerDepth] }
        if runDepth > 0 { manualHold = false; return ["ok": true, "lock": state.rawValue, "after_run": true] }   // the run lifts it
        if lingerMs > 0 {
            lingerTimer?.invalidate(); touch()
            // v34: a linger is never longer than the lease's idle time (4 s): the Mac is not held for a step that may not come
            lingerTimer = Timer.scheduledTimer(withTimeInterval: Double(min(lingerMs, Int(leaseIdle * 1000))) / 1000, repeats: false) { [weak self] _ in
                guard let s = self, s.state == .on, s.ownerDepth == 0, s.runDepth == 0 else { return }
                s.ended = "end"; s.off()
            }
            RunLoop.main.add(lingerTimer!, forMode: .common)
            return ["ok": true, "lock": state.rawValue, "linger_ms": lingerMs]
        }
        ended = "end"; off()
        return ["ok": true, "lock": state.rawValue]
    }
    /// v28: the holder is alive (POST /beat {owner}). Answers the lock's state, so a holder learns at once that it ended.
    func beat(owner o: String) -> [String: Any] {
        if state == .on && !o.isEmpty && o == owner { lastBeat = Date(); touch(); return ["ok": true, "lock": state.rawValue, "owner": owner] }
        return ["ok": false, "lock": state.rawValue, "owner": owner, "ended": ended]
    }
    /// v29: Macro Recorder paused. A lock that is on gives Marko his place and his held keys back (GuardBook) and from now
    /// on lets his keys and mouse through; nothing else changes, so the same holder carries on after RESUME.
    func pauseLock() {
        guard state == .on, pausedAt == nil else { return }
        pausedAt = Date()
        let f = NSWorkspace.shared.frontmostApplication
        macroApp = f?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : f
        escSince = nil
        GuardBook.shared.finish("paused", restore: restoreAfter, holder: owner)
        bars.forEach { $0.text.text = barText() }
    }
    /// v29: RESUME. The time the pause took is added to the watchdog and the countdown; his place now is written down
    /// (to give back at the end), the macro's app comes front again, and his hands are held again.
    func resumeLock() {
        guard let t0 = pausedAt else { return }
        pausedAt = nil
        let d = Date().timeIntervalSince(t0)
        deadline = deadline.addingTimeInterval(d)
        if let e = endAt { endAt = e.addingTimeInterval(d) }
        leaseStart = leaseStart.addingTimeInterval(d); lastActivity = Date()      // v34: the pause is not the holder's time
        lastBeat = Date()
        guard state == .on else { macroApp = nil; return }
        GuardBook.shared.begin(lastText)
        if let a = macroApp, !a.isTerminated { a.activate() }
        macroApp = nil
        bars.forEach { $0.text.text = barText() }
    }
    private func resetOptions() { passKeys = false; plainBar = false; noBlob = false; escHold = 1; beatEvery = 0 }

    /// BlockInput Off inside a script: the lock is lifted for the rest of the run.
    func release() { if state == .on { off() } }

    /// Claude needs the Mac while Marko uses it: the blob asks; his click hands it over (the lock comes on).
    func request(_ text: String) {
        if state == .on { return }
        lastText = text
        state = .requested
        showBlob("CLAUDE ASKS\nFOR THE MAC") { [weak self] in
            // v27: his click frees the Mac; the waiting guard caller takes the lock itself (its own owner, its own give-back)
            self?.state = .off
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
        if ended.isEmpty { ended = "takeover" }
        if noBlob {                  // v28: the holder's own mode ends (Space Mode), the Mac is simply his again: no blob
            let r = restoreAfter
            closeBars(); removeTap(); ticker?.invalidate(); ticker = nil
            lingerTimer?.invalidate(); lingerTimer = nil
            manualHold = false; state = .off
            let o = owner
            owner = ""; ownerDepth = 0; ownerPid = 0; ownerPids = []; leased = false; restoreAfter = true
            resetOptions()
            CGAssociateMouseAndMouseCursorPosition(1)
            try? FileManager.default.removeItem(atPath: markerPath)
            GuardBook.shared.finish("TAKE OVER", restore: r, holder: o)
            return
        }
        overrides += 1
        if buttonSpot == nil || !fromButton { buttonSpot = mainSpot }
        fromButton = false
        let wasText = lastText
        closeBars(); removeTap(); ticker?.invalidate(); ticker = nil
        lingerTimer?.invalidate(); lingerTimer = nil
        manualHold = false
        state = .overridden
        queue.removeAll()
        owner = ""; ownerDepth = 0; ownerPid = 0; ownerPids = []; leased = false; restoreAfter = true
        try? FileManager.default.removeItem(atPath: markerPath)
        GuardBook.shared.finish("TAKE OVER", restore: true, holder: "")          // v27: his place and his keys back at once
        CGAssociateMouseAndMouseCursorPosition(1)
        Engine.shared.stopPlayingByOverride()
        _ = wasText
        showBlob("GIVE THE MAC\nBACK TO CLAUDE") { [weak self] in
            // v27: back to off; the next guard caller in the queue takes the lock with its own owner
            self?.state = .off
        }
    }

    func status() -> [String: Any] {
        var o: [String: Any] = ["lock": state.rawValue, "text": lastText, "runs": runDepth, "owner": owner, "depth": ownerDepth,
                                "giving_back": GuardBook.shared.finishing, "ended": ended, "paused": PauseGate.shared.paused]
        if state == .on && (passKeys || plainBar || noBlob || beatEvery > 0) {
            o["options"] = ["keys": passKeys ? "pass" : "swallow", "plain_bar": plainBar, "blob": !noBlob, "esc_hold": escHold, "beat": beatEvery]
        }
        if state == .on { o["buffered_keys"] = GuardBook.shared.keyCount; o["noted_clicks"] = GuardBook.shared.clickCount; o["front_app"] = GuardBook.shared.frontName
                          o["his_app"] = GuardBook.shared.frontName; o["bar"] = barsOnScreen(); o["pids"] = ownerPids.map { Int($0) } }
        if leased && state == .on { o["lease"] = leaseInfo() }
        if !queue.isEmpty { o["queue"] = pruneQueue().map { $0.owner } }
        o["front_now"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
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
        // v34: a held lease keeps its own watchdog: a nested lock never pushes the 90 s further
        if state != .on || (!leased && beatEvery == 0) { deadline = Date().addingTimeInterval(Double(hard)) }
        if state == .on { bars.forEach { $0.text.text = barText() }; return }
        ended = ""
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
        emergency = false
        GuardBook.shared.begin(text)                     // v27: where Marko is now, to give it back
        showBars()
        state = .on
        try? (owner.isEmpty ? text : owner + ": " + text).write(toFile: markerPath, atomically: true, encoding: .utf8)   // v34: startupCheck
        visCheckAt = Date().addingTimeInterval(0.4)
        if who == "CLAUDE" { BlobCenter.shared.lockTaken() }      // (Marko's own MACRO runs give no notice)  // v32: a pending "You can use the computer now" waits again
        ticker?.invalidate()
        // v34: four ticks a second: the lease's idle drop, a gone holder and Escape held 1 s are felt within a quarter second
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    /// v13 of the phone: the countdown. The time first, so a long label is cut, never the time.
    /// v34: a lease shows when the Mac comes back by itself: "CLAUDE · yours in 3 s unless it acts · 0:52 max · what".
    private func barText() -> String {
        if pausedAt != nil { return "PAUSED · your Mac is yours until RESUME · " + label }     // v29
        if plainBar { return label }                 // v28: the holder's own sentence, alone
        if leased && runDepth == 0 {
            let now = Date()
            let idleLeft = max(0, Int(ceil(leaseIdle - now.timeIntervalSince(lastActivity))))
            let maxLeft = max(0, Int(min(leaseCap - now.timeIntervalSince(leaseStart), deadline.timeIntervalSince(now))))
            return "\(who) · yours in \(idleLeft) s unless it acts · " + String(format: "%d:%02d max", maxLeft / 60, maxLeft % 60) + " · \(label)"
        }
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
        if Date() >= visCheckAt { visCheckAt = Date().addingTimeInterval(1); ensureBarsVisible() }
        if pausedAt != nil {        // v29: paused: no watchdog, no countdown, no Escape; only a holder that is gone lifts it
            if holderGone() { ended = "holder-gone"; off() }
            return
        }
        let now = Date()
        if runDepth > 0 { lastActivity = now }       // a macro running is the holder working
        // the watchdog: a hard maximum, and nothing running and nothing held means nothing to lock
        if now > deadline { ended = "time"; off(); Engine.shared.say("input lock lifted: its time was up", GREYC, 3); return }
        if beatEvery > 0 && now.timeIntervalSince(lastBeat) > beatEvery {
            NSLog("[guard] %@ stopped beating: lifting", owner); ended = "heartbeat"; off()
            Engine.shared.say("input lock lifted: its holder stopped answering", GREYC, 3); return
        }
        tapGuard.lock()
        if !emergency, let t = tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        tapGuard.unlock()
        if holderGone() { NSLog("[guard] holder %@ is gone: lifting", owner); ended = "holder-gone"; off(); return }
        // v34: the lease. Idle = his again; the cap is renewed once while the holder is busy, then it ends
        if leased && manualHold && runDepth == 0 && lingerTimer == nil {
            if now.timeIntervalSince(lastActivity) > leaseIdle { ended = "idle"; off(); return }
            if now.timeIntervalSince(leaseStart) > leaseCap {
                if !extended { extended = true; leaseCap = InputLock.HARD_MAX; NSLog("[guard] %@: lease renewed once (busy)", owner) }
                else { ended = "cap"; off(); Engine.shared.say("input lock lifted: 90 s is the most one hold may last", GREYC, 3); return }
            }
        }
        // holding Escape for one second takes over too
        if CGEventSource.keyState(.hidSystemState, key: 0x35) {
            if escSince == nil { escSince = Date() }
            if Date().timeIntervalSince(escSince!) >= escHold { escSince = nil; ended = "escape"; takeOver() }
        } else { escSince = nil }
    }

    /// v34: every process that asked for this hold is gone (a worker that ended or crashed without `guard end`).
    private func holderGone() -> Bool {
        guard runDepth == 0, !ownerPids.isEmpty || ownerPid > 0 else { return false }
        if ownerPids.isEmpty { ownerPids = [ownerPid] }
        ownerPids.removeAll { kill($0, 0) != 0 && errno == ESRCH }
        return ownerPids.isEmpty
    }

    /// v34: the bar must be seen. Each bar is asked of the window server; one that is not on screen is ordered front again,
    /// and if the app itself is hidden (launched hidden at login, Hide Others) it is unhidden without taking the focus.
    private func ensureBarsVisible() {
        guard state == .on, Date() >= suspendedUntil else { return }
        let unseen = bars.filter { !InputLock.onScreen($0.panel) }
        if unseen.isEmpty { if !barProblem.isEmpty { barProblem = "" }; return }
        barProblem = "\(unseen.count) of \(bars.count) bars were not on screen" + (NSApp.isHidden ? " (the app was hidden)" : "")
        NSLog("[guard] %@: ordering them front again", barProblem)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if bars.count != NSScreen.screens.count { showBars(); return }
        unseen.forEach { $0.panel.orderFrontRegardless() }
    }
    static func onScreen(_ w: NSWindow) -> Bool {
        guard w.windowNumber > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]],
              let first = info.first else { return false }
        return (first[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }
    /// v34: the bars on screen now (status, tests)
    func barsOnScreen() -> [String: Any] {
        ["bars": bars.count, "on_screen": bars.filter { InputLock.onScreen($0.panel) }.count, "screens": NSScreen.screens.count,
         "app_hidden": NSApp.isHidden, "problem": barProblem]
    }
    /// v34: the displays changed while it is held (BenQ plugged, layout moved): the bars are rebuilt on every screen.
    func screensChanged() { if state == .on { showBars() } }

    // v25 (13.11.2026, Marko: "center all the text and all the buttons ... Everything must be in the same place. Eyes are
    // following."): the text and TAKE OVER are ONE group centred on the screen's centre line, the text a fixed width so the
    // countdown never moves the group, both centred on the cap height. The blob takes the button's place exactly.
    static let BTN_W: CGFloat = 260, BTN_H: CGFloat = 32, BAR_H: CGFloat = 42, GAP: CGFloat = 16      // v34: bigger, easier to hit
    /// v34: above everything, full-screen apps included; never hidden with the app (canHide false: the v33 bar was kept off
    /// screen because the app had been launched hidden at login)
    static let LEVEL = NSWindow.Level.screenSaver
    static func overlay(_ p: NSPanel) {
        p.level = InputLock.LEVEL; p.canHide = false; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
    }
    private var buttonSpot: (screen: NSScreen, rect: NSRect)?     // where TAKE OVER is, in screen coordinates (Cocoa)

    /// One bar: the panel for frame f (bottom of a screen), its text and its TAKE OVER (button frame inside the bar).
    private func makeBar(_ f: NSRect) -> (panel: NSPanel, text: CapText, button: ClickView) {
        let h = InputLock.BAR_H
        let p = BarPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Macro Recorder input lock bar"
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        InputLock.overlay(p); p.ignoresMouseEvents = false
        p.sharingType = .readOnly            // visible to screen capture and CGWindowList (layer 25, owner "MacroRecorder")
        let v = NSView(frame: NSRect(origin: .zero, size: f.size)); v.wantsLayer = true
        v.layer?.backgroundColor = InputLock.BARBG.cgColor
        let bw = InputLock.BTN_W
        let room = max(120, f.width - bw - InputLock.GAP - 40)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        let want = plainBar ? ceil((barText() as NSString).size(withAttributes: [.font: font]).width) + 8 : 700
        let tw = min(want, room)
        let x0 = ((f.width - (tw + InputLock.GAP + bw)) / 2).rounded()
        let t = CapText(frame: NSRect(x: x0, y: 0, width: tw, height: h), font: font, color: InputLock.ORANGE, centred: false)
        t.text = barText()
        let b = ClickView(frame: NSRect(x: x0 + tw + InputLock.GAP, y: (h - InputLock.BTN_H) / 2, width: bw, height: InputLock.BTN_H)); b.wantsLayer = true
        b.layer?.backgroundColor = InputLock.ORANGE.cgColor; b.layer?.cornerRadius = 8
        let bt = CapText(frame: NSRect(x: 0, y: 0, width: bw, height: InputLock.BTN_H), font: .boldSystemFont(ofSize: 16), color: .black, centred: true)
        bt.text = "TAKE OVER"
        b.addSubview(bt)
        b.setAccessibilityLabel("TAKE OVER"); b.setAccessibilityRole(.button); b.setAccessibilityIdentifier("takeover")
        v.addSubview(t); v.addSubview(b)
        p.contentView = v
        return (p, t, b)
    }

    private func showBars() {
        closeBars()
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for s in NSScreen.screens {
            let f = NSRect(x: s.frame.minX, y: s.visibleFrame.minY, width: s.frame.width, height: InputLock.BAR_H)   // v26: bottom of the screen, just above the Dock
            let (p, t, b) = makeBar(f)
            let rect = NSRect(x: f.minX + b.frame.minX, y: f.minY + b.frame.minY, width: b.frame.width, height: b.frame.height)
            b.onClick = { [weak self] in self?.buttonSpot = (s, rect); self?.fromButton = true; self?.takeOver() }
            if s == (NSScreen.main ?? NSScreen.screens[0]) { mainSpot = (s, rect) }
            p.orderFrontRegardless()
            p.setAccessibilityIdentifier("lockbar")
            bars.append((panel: p, text: t))
            barRects.append(CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height))
        }
    }

    /// v28: --bar-shot: the bar as a holder with plain_bar shows it, drawn off every screen into a PNG, then the app quits.
    func shot(_ text: String, to path: String) {
        plainBar = true; label = text
        let w = NSScreen.main?.frame.width ?? 1512
        let (p, _, _) = makeBar(NSRect(x: -20000, y: -20000, width: w, height: InputLock.BAR_H))
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("shot \(path)"); exit(0)
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
            r = NSRect(x: (s.frame.midX - (min(700, max(120, s.frame.width - w - InputLock.GAP - 40)) + InputLock.GAP + w) / 2 + min(700, max(120, s.frame.width - w - InputLock.GAP - 40)) + InputLock.GAP).rounded(),
                       y: s.visibleFrame.minY + (InputLock.BAR_H - h) / 2, width: w, height: h)
        }
        let p = BarPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Macro Recorder input lock blob"
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        InputLock.overlay(p)
        p.sharingType = .readOnly
        let v = BlobView(frame: NSRect(origin: .zero, size: r.size)); v.wantsLayer = true
        v.layer?.backgroundColor = InputLock.ORANGE.cgColor; v.layer?.cornerRadius = 8
        let t = CapText(frame: NSRect(origin: .zero, size: r.size), font: .boldSystemFont(ofSize: 16), color: .black, centred: true)
        t.text = words.replacingOccurrences(of: "\n", with: " "); v.addSubview(t)
        v.onClick = { [weak self] in self?.closeBlob(); tap() }
        v.setAccessibilityLabel(t.text); v.setAccessibilityRole(.button); v.setAccessibilityIdentifier("giveback")
        p.contentView = v
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
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
        tapGuard.lock(); tap = t; tapGuard.unlock()
        return true
    }
    private func removeTap() {
        tapGuard.lock()
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil
        tapGuard.unlock()
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tapSource = nil
    }

    /// nil swallows the event. Called on the main thread by the tap.
    fileprivate func filter(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !emergency, let t = tap { CGEvent.tapEnable(tap: t, enable: true) }      // macOS switched it off: on again
            return pass
        }
        guard state == .on, !emergency else { return pass }
        // v34: ⌃⌥⌘Esc lets go of everything at once (no TAKE OVER blob, nothing waits): the emergency way out
        if type == .keyDown && e.getIntegerValueField(.keyboardEventKeycode) == 53 &&
            e.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand]) && e.getIntegerValueField(.eventSourceUserData) != MACRO_MARK {
            DispatchQueue.main.async { InputLock.shared.releaseAll("chord") }
            return nil
        }
        guard pausedAt == nil, Date() >= suspendedUntil else { return pass }     // v29: paused = his hands pass
        if e.getIntegerValueField(.eventSourceUserData) == MACRO_MARK { lastActivity = Date(); return pass }       // the macro's own hands (v34: they renew the lease)
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            if passKeys { return pass }                  // v28: the holder owns the keyboard (Talk Mode's Space Mode tap)
            // the stop key of the macro recorder (⌃⌥⌘. by default) always works
            if let b = Engine.shared.settings.keys["stop"], KeyMap.codes[b.key] == Int(e.getIntegerValueField(.keyboardEventKeycode)) { return pass }
            if type == .keyDown { GuardBook.shared.noteKey(e) }         // v27: kept, replayed where he was when it lifts
            return nil
        default:
            // clicks and moves inside the bar pass, so TAKE OVER can be pressed; everything else is swallowed
            let p = e.location
            if barRects.contains(where: { $0.contains(p) }) { return pass }
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown { GuardBook.shared.noteClick(p, type) }
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
/// v28: POST /lock also takes {keys: "pass", plain_bar: true, blob: false, esc_hold: 2, beat: 5}; POST /beat {owner}.
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
        // v34: the failsafe never waits for the main thread: the tap goes off here and now, the rest follows on main
        if method == "POST" && path == "/release-all" {
            InputLock.shared.emergencyTapOff()
            DispatchQueue.main.async { InputLock.shared.releaseAll(j["why"] as? String ?? "release-all") }
            out = ["ok": true, "released": true, "tap": "off"]
            let d = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
            let h = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(h.utf8) + d, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        DispatchQueue.main.sync {
            let L = InputLock.shared
            switch (method, path) {
            case ("GET", "/status"), ("GET", "/"): out = L.status(); out["app"] = "macrorecorder"; out["version"] = VERSION
            case ("POST", "/lock") where j["owner"] != nil:
                var op = InputLock.Options()
                op.passKeys = (j["keys"] as? String) == "pass"
                op.plainBar = j["plain_bar"] as? Bool ?? false
                op.noBlob = (j["blob"] as? Bool) == false
                op.escHold = (j["esc_hold"] as? Double) ?? Double(j["esc_hold"] as? Int ?? 1)
                op.beat = (j["beat"] as? Double) ?? Double(j["beat"] as? Int ?? 0)
                op.idle = (j["idle"] as? Double) ?? Double(j["idle"] as? Int ?? Int(InputLock.LEASE_IDLE))     // v34: the lease
                op.placeFront = (j["place"] as? String) == "front"       // v34: tests: his place = the app in front now
                out = L.guardLock(j["text"] as? String ?? "working", seconds: j["seconds"] as? Int ?? 60, owner: j["owner"] as? String ?? "",
                                  pid: pid_t(j["pid"] as? Int ?? 0), restore: j["restore"] as? Bool ?? true, options: op)
            // v29: PAUSE / RESUME (Pause.swift), for Claude Control and `macro pause|resume|pause-status`
            case ("POST", "/pause"): out = PauseGate.shared.pause(by: j["by"] as? String ?? "api")
            case ("POST", "/resume"): out = PauseGate.shared.resume(by: j["by"] as? String ?? "api")
            case ("GET", "/pause"), ("GET", "/pause-status"): out = PauseGate.shared.status()
            case ("POST", "/beat"): out = L.beat(owner: j["owner"] as? String ?? "")
            case ("POST", "/ping"): out = L.ping(owner: j["owner"] as? String ?? "")      // v34: the lease renewed
            case ("POST", "/unlock") where j["owner"] != nil:
                out = L.guardUnlock(owner: j["owner"] as? String ?? "", lingerMs: j["linger_ms"] as? Int ?? 0)
            case ("GET", "/last"): out = GuardBook.shared.last; out["ok"] = true
            // v32: the text blob (Blob.swift): POST /blob {text, kind, seconds, sticky, id} or {clear: id|"all"}, GET /blobs
            case ("POST", "/blob"): out = BlobCenter.shared.handle(j)
            case ("GET", "/blobs"): out = BlobCenter.shared.status()
            case ("POST", "/lock") where PauseGate.shared.paused:
                out = ["ok": false, "busy": true, "paused": true, "error": "Macro Recorder is paused: nothing new starts until RESUME"]
            case ("POST", "/lock"):
                if L.state == .on && !L.owner.isEmpty { out = ["ok": false, "busy": true, "error": "held by " + L.owner]; break }
                L.on(j["text"] as? String ?? "Working on the Mac. It will be yours again when this disappears.", seconds: j["seconds"] as? Int ?? 0); out = ["ok": true, "lock": L.state.rawValue]
            case ("POST", "/request"): L.request(j["text"] as? String ?? "Claude needs the Mac for a moment."); out = ["ok": true, "lock": L.state.rawValue]
            case ("POST", "/unlock"):
                if L.state == .on && !L.owner.isEmpty { out = ["ok": false, "error": "held by " + L.owner + ": unlock with its owner"]; break }
                L.off(); out = ["ok": true, "lock": L.state.rawValue]
            case ("POST", "/through"): L.through(j["ms"] as? Int ?? 800); out = ["ok": true, "lock": L.state.rawValue]
            default: code = 404; out = ["error": "no such route"]
            }
        }
        let d = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        let h = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Not Found")\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + d, completion: .contentProcessed { _ in c.cancel() })
    }
}
