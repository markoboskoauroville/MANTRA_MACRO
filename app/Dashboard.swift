// Dashboard.swift: v41 (28.11.2026). The macro dashboard and the run log.
// Marko, 28.11.2026: "This should not happen again. I need to see when I open the macro ... make a dashboard just in the main
// menu ... I need to have a macro dashboard so I can run multiple macros or stop multiple macros." What happened: a visual trigger
// ("Auto Keep Button"), armed at every login, fired 57 times in two days (26.-28.11.2026) and nobody could see it. Nothing in this
// app may start a macro by itself without a row here, and every start is written to the run log.
//
// What can start a macro by itself, found in the code (v41): a VISUAL TRIGGER (VisualTrigger.swift: a picture appears on the screen),
// a macro's own HOTKEY (settings.json "triggers", Engine.bindKeys), the INBOX folder (Inbox.swift: files dropped by `macro do`/`run:`),
// the local API on :8829 (POST /run). There is no schedule and no autorun. The first two are rows with PLAY / PAUSE / STOP; the last two
// are listed as channels (they only act when something calls them). Slot keys and the window's own PLAY are Marko's hand.
//
// STOP on a trigger switches it OFF and SAVES that ("on": false in settings.json): it stays off after a restart and at login. PLAY switches
// it on again and saves. PAUSE holds it until PLAY, for this run of the app only. On a running job: STOP is the engine's own stop path
// (releases the input lock); PAUSE stops it at the safe point between script lines and gives Marko his keyboard back while it is paused.
//
// The run log: ~/.mantra_macro/run_log.jsonl, one JSON line per event: trigger_fired (visual trigger: score, match box; hotkey),
// run_start (name, id, by), click_image (image, score, match, point, clicked), run_end (result, clicks_posted, last_click), dashboard
// (every PLAY / PAUSE / STOP pressed, by whom). The Dashboard's "fired" and "last" columns are counted from it.
// API (port 8829, loopback): GET /dashboard, GET /dashboard/log?limit=N, POST /dashboard/play|pause|stop {id | ids}, POST /dashboard/stop-all
// {except: [names], kinds: [..]}, POST /dashboard/start {macros: [..]}, POST /dashboard/open {focus}, POST /dashboard/close.
import AppKit

let RUN_LOG_FILE = DIR + "/run_log.jsonl"

final class RunLog {
    static let shared = RunLog()
    private let lk = NSLock()
    private var loaded = false
    private var counts: [String: Int] = [:]
    private var lasts: [String: Date] = [:]

    private func key(_ ev: String, _ kind: String, _ name: String) -> String { ev + "|" + kind + "|" + name }
    private func index(_ j: [String: Any]) {
        guard let ev = j["event"] as? String, ev == "trigger_fired" || ev == "run_start" else { return }
        let at = (j["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        var keys = [key(ev, j["kind"] as? String ?? "", j["name"] as? String ?? "")]
        if ev == "run_start", let by = j["by"] as? String { keys.append("by||" + by) }
        for k in keys {
            counts[k, default: 0] += 1
            if let at { lasts[k] = at }
        }
    }
    private func loadIfNeeded() {          // under the lock
        guard !loaded else { return }
        loaded = true
        guard let t = readText(RUN_LOG_FILE) else { return }
        for l in t.split(separator: "\n") {
            if let d = l.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { index(j) }
        }
    }
    /// any thread
    func add(_ event: [String: Any]) {
        var j = event
        let now = Date()
        j["at"] = (now.timeIntervalSince1970 * 1000).rounded() / 1000
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone.current
        j["time"] = f.string(from: now)
        j["app_version"] = VERSION
        lk.lock(); defer { lk.unlock() }
        loadIfNeeded()
        index(j)
        guard var line = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]) else { return }
        line.append(10)
        mkdirs(DIR)
        if let h = FileHandle(forWritingAtPath: RUN_LOG_FILE) {
            h.seekToEndOfFile(); h.write(line); h.closeFile()
        } else {
            try? line.write(to: URL(fileURLWithPath: RUN_LOG_FILE))
        }
    }
    func count(_ ev: String, _ kind: String, _ name: String) -> Int {
        lk.lock(); defer { lk.unlock() }; loadIfNeeded(); return counts[key(ev, kind, name)] ?? 0
    }
    func last(_ ev: String, _ kind: String, _ name: String) -> Date? {
        lk.lock(); defer { lk.unlock() }; loadIfNeeded(); return lasts[key(ev, kind, name)]
    }
    func countBy(_ by: String) -> Int { lk.lock(); defer { lk.unlock() }; loadIfNeeded(); return counts["by||" + by] ?? 0 }
    func lastBy(_ by: String) -> Date? { lk.lock(); defer { lk.unlock() }; loadIfNeeded(); return lasts["by||" + by] }
    /// the newest `n` events, oldest first
    func tail(_ n: Int) -> [[String: Any]] {
        guard let t = readText(RUN_LOG_FILE) else { return [] }
        return t.split(separator: "\n").suffix(max(1, n)).compactMap {
            $0.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }
}

struct DashRow {
    let id: String
    let name: String
    let kind: String
    var state: String
    var since: Date?
    var count: Int
    var countLabel: String
    var last: Date?
    var detail: String
    var canPlay: Bool, canPause: Bool, canStop: Bool

    var json: [String: Any] {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone.current
        var o: [String: Any] = ["id": id, "name": name, "kind": kind, "state": state, "count": count, "count_label": countLabel,
                                "detail": detail, "can_play": canPlay, "can_pause": canPause, "can_stop": canStop]
        o["since"] = since.map { f.string(from: $0) } ?? NSNull()
        o["last"] = last.map { f.string(from: $0) } ?? NSNull()
        return o
    }
}

final class Dashboard {
    static let shared = Dashboard()
    let launched = Date()                      // the moment the app started: what "armed at login" is measured from
    var sessionPaused = Set<String>()          // "hk:<macro>" paused from the Dashboard (visual triggers: VisualTriggerWatch.paused)
    var changedAt: [String: Date] = [:]
    private var e: Engine { Engine.shared }

    static func sourceLabel(_ source: String, _ by: Caller) -> String {
        source.isEmpty ? (by == .claude ? "api or inbox" : "window or key") : source
    }

    // MARK: the rows

    func rows() -> [DashRow] {
        var out: [DashRow] = []
        let s = e.settings, log = RunLog.shared
        let watch = VisualTriggerWatch.shared
        // visual triggers: the ones that are on first, then the stopped ones
        for (n, t) in s.visualTriggers.sorted(by: { a, b in
            a.value.on != b.value.on ? a.value.on : a.key.lowercased() < b.key.lowercased() }) {
            let id = "vt:" + n
            let state = !t.on ? "STOPPED" : (watch.paused.contains(n) ? "PAUSED" : "WATCHING")
            var d = "picture " + t.image
            if let z = s.zones[t.image] { d += " · looks in x \(Int(z.x)) y \(Int(z.y)), \(Int(z.w)) × \(Int(z.h))" }
            else { d += " · looks on every display" }
            d += " · match 85 % · every 0.3 s"
            if !Macros.exists(n) { d += " · THE MACRO FILE IS MISSING" }
            out.append(DashRow(id: id, name: n, kind: "visual trigger", state: state,
                               since: changedAt[id] ?? (t.on ? launched : nil),
                               count: log.count("trigger_fired", "visual trigger", n), countLabel: "fired",
                               last: log.last("trigger_fired", "visual trigger", n), detail: d,
                               canPlay: state != "WATCHING", canPause: state == "WATCHING", canStop: t.on))
        }
        // hotkeys that belong to one macro (a key press is Marko's, but it is armed all the time)
        for (n, t) in s.triggers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) where !t.key.isEmpty {
            let id = "hk:" + n
            let state = !t.on ? "STOPPED" : (sessionPaused.contains(id) ? "PAUSED" : "ARMED")
            out.append(DashRow(id: id, name: n, kind: "hotkey", state: state,
                               since: changedAt[id] ?? (t.on ? launched : nil),
                               count: log.count("trigger_fired", "hotkey trigger", n), countLabel: "fired",
                               last: log.last("trigger_fired", "hotkey trigger", n),
                               detail: "plays when " + keyLabel(Binding(mods: t.mods, key: t.key)) + " is pressed",
                               canPlay: state != "ARMED", canPause: state == "ARMED", canStop: t.on))
        }
        // jobs
        for r in e.activeRuns {
            let st = r.state.uppercased()
            out.append(DashRow(id: "run:\(r.id)", name: r.name, kind: "run", state: st, since: r.started,
                               count: log.count("run_start", "run", r.name), countLabel: "ran",
                               last: log.last("run_start", "run", r.name),
                               detail: "started by " + Dashboard.sourceLabel(r.source, r.caller) + (r.usesInput ? " · uses the mouse and keyboard" : " · in the background"),
                               canPlay: st == "PAUSED", canPause: st == "RUNNING", canStop: true))
        }
        // channels: they act only when something calls them
        out.append(DashRow(id: "ch:inbox", name: "Inbox folder", kind: "channel", state: "LISTENING", since: launched,
                           count: log.countBy("inbox"), countLabel: "ran", last: log.lastBy("inbox"),
                           detail: "runs the .ahk files that sessions drop in ~/.mantra_macro/inbox (macro do, run:)",
                           canPlay: false, canPause: false, canStop: false))
        out.append(DashRow(id: "ch:api", name: "Local API :8829", kind: "channel", state: "LISTENING", since: launched,
                           count: log.countBy("api"), countLabel: "ran", last: log.lastBy("api"),
                           detail: "POST /run starts a macro for whoever calls it on this Mac",
                           canPlay: false, canPause: false, canStop: false))
        return out
    }

    /// what the menu shows: "Dashboard (1 watching)"
    func counts() -> (watching: Int, running: Int, paused: Int) {
        var w = 0, r = 0, p = 0
        for row in rows() {
            switch row.state {
            case "WATCHING", "ARMED": w += 1
            case "RUNNING", "QUEUED": r += 1
            case "PAUSED": p += 1
            default: break
            }
        }
        return (w, r, p)
    }
    /// "1 watching, 2 running", or "" when nothing is armed or running
    func summary() -> String {
        let c = counts()
        var parts: [String] = []
        if c.watching > 0 { parts.append("\(c.watching) watching") }
        if c.running > 0 { parts.append("\(c.running) running") }
        if c.paused > 0 { parts.append("\(c.paused) paused") }
        if PauseGate.shared.paused { parts.append("ALL MACROS PAUSED") }       // the app-wide PAUSE (menu): nothing fires or starts
        return parts.joined(separator: ", ")
    }
    func menuTitle() -> String { let t = summary(); return t.isEmpty ? "Dashboard" : "Dashboard (" + t + ")" }

    // MARK: PLAY / PAUSE / STOP

    private func note(_ action: String, _ row: DashRow?, _ id: String, _ by: String, _ after: String) {
        RunLog.shared.add(["event": "dashboard", "action": action, "id": id, "name": row?.name ?? "", "kind": row?.kind ?? "",
                           "by": by, "state_after": after])
    }
    private func fail(_ id: String, _ why: String) -> [String: Any] { ["ok": false, "id": id, "error": why] }

    func act(_ action: String, _ id: String, by: String = "dashboard") -> [String: Any] {
        guard let row = rows().first(where: { $0.id == id }) else { return fail(id, "no such row") }
        let ok = ["ok": true, "id": id] as [String: Any]
        let watch = VisualTriggerWatch.shared
        if id.hasPrefix("vt:") {
            let n = String(id.dropFirst(3))
            guard var t = e.settings.visualTriggers[n] else { return fail(id, "no such visual trigger") }
            switch action {
            case "play":
                if !t.on { t.on = true; e.settings.visualTriggers[n] = t; e.settings.save() }       // saved: it watches again after a restart
                watch.paused.remove(n)
            case "pause":
                guard t.on else { return fail(id, "it is stopped: PLAY it first") }
                watch.paused.insert(n)
            default:                                                                                // stop: off, and saved
                t.on = false; e.settings.visualTriggers[n] = t; e.settings.save()
                watch.paused.remove(n)
            }
            watch.changed(n)
            changedAt[id] = Date(); note(action, row, id, by, action == "play" ? "WATCHING" : action == "pause" ? "PAUSED" : "STOPPED")
            e.say("visual trigger \(action == "play" ? "on" : action == "pause" ? "paused" : "OFF"): " + n, action == "play" ? GREENC : GREYC, 2)
            e.changed(); return ok
        }
        if id.hasPrefix("hk:") {
            let n = String(id.dropFirst(3))
            switch action {
            case "play": sessionPaused.remove(id); if e.settings.triggers[n]?.on != true { _ = e.setTrigger(n, key: nil, on: true) }
            case "pause": guard e.settings.triggers[n]?.on == true else { return fail(id, "it is stopped: PLAY it first") }; sessionPaused.insert(id)
            default: sessionPaused.remove(id); _ = e.setTrigger(n, key: nil, on: false)
            }
            changedAt[id] = Date(); note(action, row, id, by, action == "play" ? "ARMED" : action == "pause" ? "PAUSED" : "STOPPED")
            e.changed(); return ok
        }
        if id.hasPrefix("run:"), let rid = Int(id.dropFirst(4)) {
            var did = false
            switch action {
            case "play": did = e.resumeRun(rid)
            case "pause": did = e.pauseRun(rid)
            default:
                if e.activeRuns.contains(where: { $0.id == rid }) { e.stopRun(rid); did = true }
            }
            note(action, row, id, by, did ? (action == "play" ? "RUNNING" : action == "pause" ? "PAUSED" : "STOPPING") : "unchanged")
            return did ? ok : fail(id, "the run is not " + (action == "play" ? "paused" : action == "pause" ? "running" : "there any more"))
        }
        return fail(id, "a channel has no PLAY, PAUSE or STOP: it only acts when something calls it")
    }

    func act(_ action: String, ids: [String], by: String = "dashboard") -> [[String: Any]] { ids.map { act(action, $0, by: by) } }

    /// STOP ALL: every trigger off (saved) and every job stopped. `except`: names left alone (for tests); `kinds`: only these kinds.
    func stopAll(except: [String] = [], kinds: [String]? = nil, by: String = "dashboard") -> [String: Any] {
        var stopped: [String] = []
        for row in rows() where row.canStop && !except.contains(row.name) && (kinds == nil || kinds!.contains(row.kind)) {
            if (act("stop", row.id, by: by)["ok"] as? Bool) == true { stopped.append(row.id) }
        }
        RunLog.shared.add(["event": "dashboard", "action": "stop-all", "by": by, "stopped": stopped, "except": except])
        return ["ok": true, "stopped": stopped]
    }

    /// start one or several stored macros from the dashboard (the engine queues the ones that need the mouse and keyboard)
    func start(_ names: [String], by: String = "dashboard") -> [String: Any] {
        var started: [String] = [], missing: [String] = []
        for n in names {
            if Macros.exists(n) { e.runMacro(n, source: by, keepPlayer: true); started.append(n) } else { missing.append(n) }
        }
        RunLog.shared.add(["event": "dashboard", "action": "start", "by": by, "macros": started])
        return ["ok": missing.isEmpty, "started": started, "missing": missing]
    }

    // MARK: the API (called on the main thread by LockServer)

    func snapshot() -> [String: Any] {
        let c = counts()
        return ["ok": true, "version": VERSION, "title": menuTitle(), "watching": c.watching, "running": c.running, "paused": c.paused, "app_paused": PauseGate.shared.paused,
                "app_started": ISO8601DateFormatter().string(from: launched), "run_log": RUN_LOG_FILE,
                "rows": rows().map { $0.json }]
    }

    func api(_ method: String, _ rawPath: String, _ j: [String: Any]) -> ([String: Any], Int) {
        let parts = rawPath.split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts[0], query = parts.count > 1 ? parts[1] : ""
        let ids = (j["ids"] as? [String]) ?? (j["id"] as? String).map { [$0] } ?? []
        let by = j["by"] as? String ?? "api"
        switch (method, path) {
        case ("GET", "/dashboard"): return (snapshot(), 200)
        case ("GET", "/dashboard/log"):
            let n = query.split(separator: "&").compactMap { p -> Int? in
                p.hasPrefix("limit=") ? Int(p.dropFirst(6)) : nil }.first ?? 50
            return (["ok": true, "file": RUN_LOG_FILE, "events": RunLog.shared.tail(n)], 200)
        case ("POST", "/dashboard/play"), ("POST", "/dashboard/pause"), ("POST", "/dashboard/stop"):
            guard !ids.isEmpty else { return (["ok": false, "error": "send {\"id\": \"vt:Name\"} or {\"ids\": [...]}"], 409) }
            let r = act(String(path.dropFirst("/dashboard/".count)), ids: ids, by: by)
            let ok = r.allSatisfy { ($0["ok"] as? Bool) == true }
            return (["ok": ok, "results": r], ok ? 200 : 409)
        case ("POST", "/dashboard/stop-all"):
            return (stopAll(except: j["except"] as? [String] ?? [], kinds: j["kinds"] as? [String], by: by), 200)
        case ("POST", "/dashboard/start"):
            let r = start(j["macros"] as? [String] ?? [], by: by)
            return (r, (r["ok"] as? Bool) == true ? 200 : 409)
        case ("POST", "/dashboard/open"):
            DashboardWindow.show(focus: j["focus"] as? Bool ?? true)
            return (["ok": true, "window_number": DashboardWindow.window?.windowNumber ?? 0], 200)
        case ("POST", "/dashboard/close"):
            DashboardWindow.window?.orderOut(nil)
            return (["ok": true], 200)
        default: return (["error": "no such route"], 404)
        }
    }
}
