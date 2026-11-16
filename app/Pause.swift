// Pause.swift: PAUSE / RESUME (v29, 16.11.2026). Marko: "Please expand the pause to macro recorder and Queen. All our tools
// need to be paused at the same time and need to have this kind of API calls to be stopped."
//
// While paused: a running macro stops BETWEEN steps (MacHost.check() and every Sleep wait here; a click, a drag or a
// key chord is never cut in half), nothing new starts (the inbox keeps its files, runScript refuses, a new guard holder
// is answered busy/paused and waits), no click or key fires. RESUME continues exactly where it stopped; a Sleep keeps
// the time it still had. The app is never frozen (no SIGSTOP: it owns the input lock, a frozen tap would trap his
// keyboard): a lock held while paused lets Marko's keys and mouse through and gives him his place back
// (InputLock.pauseLock), and takes them again on resume (InputLock.resumeLock). PAUSED shows in the menu bar (orange) and
// on the lock bar. The state survives a restart: ~/.mantra_macro/paused exists while paused.
// API: POST 127.0.0.1:8829/pause {by}, POST /resume, GET /pause -> {"paused": bool, ...}; inbox "pause:", "resume:",
// "pause-status:" (answered at once, even while a macro runs); CLI `macro pause|resume|pause-status`.
import AppKit

let PAUSE_FILE = DIR + "/paused"
let ORANGEC = NSColor(srgbRed: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255, alpha: 1)

final class PauseGate {
    static let shared = PauseGate()
    private let lk = NSLock()
    private var _paused = false
    private var _waiting = false                 // a script thread is standing at the gate now
    private(set) var since: Date?
    private(set) var by = ""
    private(set) var pauses = 0

    /// read from any thread (the script thread asks between every step)
    var paused: Bool { lk.lock(); defer { lk.unlock() }; return _paused }
    var waiting: Bool { lk.lock(); defer { lk.unlock() }; return _waiting }

    /// at launch: paused before a restart stays paused
    func load() {
        guard has(PAUSE_FILE) else { return }
        let who = (try? String(contentsOfFile: PAUSE_FILE, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        set(true, by: who.isEmpty ? "before the restart" : who, persist: false)
    }

    /// main thread
    @discardableResult func pause(by who: String) -> [String: Any] {
        if !paused { set(true, by: who.isEmpty ? "api" : who, persist: true) }
        return status()
    }
    @discardableResult func resume(by who: String) -> [String: Any] {
        if paused { set(false, by: who, persist: true) }
        return status()
    }

    private func set(_ on: Bool, by who: String, persist: Bool) {
        lk.lock(); _paused = on; lk.unlock()
        if on {
            since = Date(); by = who; pauses += 1
            if persist { try? (who + "\n").write(toFile: PAUSE_FILE, atomically: true, encoding: .utf8) }
            InputLock.shared.pauseLock()
            NSLog("[pause] paused by %@", who)
        } else {
            since = nil; by = ""
            try? FileManager.default.removeItem(atPath: PAUSE_FILE)
            InputLock.shared.resumeLock()
            NSLog("[pause] resumed by %@", who)
        }
        Overlay.shared.render()
        Engine.shared.changed()
    }

    func status() -> [String: Any] {
        let queued = ((try? FileManager.default.contentsOfDirectory(atPath: INBOX)) ?? []).filter { $0.hasSuffix(".ahk") }.count
        var o: [String: Any] = ["ok": true, "paused": paused, "state": paused ? "paused" : "running",
                                "playing": Engine.shared.playing, "held_at_step": waiting, "queued": queued]
        if let s = since { o["since"] = s.timeIntervalSince1970; o["seconds"] = Int(Date().timeIntervalSince(s)); o["by"] = by }
        if Engine.shared.playing { o["macro"] = Engine.shared.playName }
        return o
    }

    /// The script thread waits here while paused. Returns the seconds it waited; returns early when `stopped` says so.
    @discardableResult func gate(_ stopped: () -> Bool) -> Double {
        guard paused else { return 0 }
        let t0 = Date()
        lk.lock(); _waiting = true; lk.unlock()
        while paused && !stopped() { Thread.sleep(forTimeInterval: 0.02) }
        lk.lock(); _waiting = false; lk.unlock()
        return Date().timeIntervalSince(t0)
    }
}
