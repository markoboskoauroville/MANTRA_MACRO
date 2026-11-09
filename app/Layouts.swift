// Layouts.swift: save every visible window's place, and bring it back, opening the apps that are missing (v21, 9.11.2026).
// Uses WinMgr (ported from Rectangle, MIT, THIRD_PARTY/LICENSE.md): Accessibility only, no mouse, no focus taken.
// A layout is ~/.mantra_macro/layouts/<name>.json: per window the app (bundle id, path), title, display (name, number),
// the frame absolute AND as fractions of that display's visible frame, and the z-order at the time of saving.
import AppKit
import ApplicationServices

enum Layouts {
    static let dir = DIR + "/layouts"
    static func path(_ n: String) -> String { dir + "/" + n.replacingOccurrences(of: "/", with: "-") + ".json" }

    /// newest first (by file date); a name starting with "_" is hidden from the list (the file stays)
    static func names() -> [String] {
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") }
        func date(_ f: String) -> Date { ((try? fm.attributesOfItem(atPath: dir + "/" + f))?[.modificationDate] as? Date) ?? .distantPast }
        return all.sorted { date($0) > date($1) }.map { String($0.dropLast(5)) }
    }
    /// today's name, d.m.yyyy, then "d.m.yyyy 2", "d.m.yyyy 3" ... (v22)
    static func todayName() -> String {
        let f = DateFormatter(); f.dateFormat = "d.M.yyyy"
        let base = f.string(from: Date())
        var n = base, i = 2
        while has(path(n)) { n = base + " " + String(i); i += 1 }
        return n
    }
    static func delete(_ n: String) -> (Bool, String) {
        guard has(path(n)) else { return (false, "no layout called " + n) }
        try? FileManager.default.removeItem(atPath: path(n)); return (true, "deleted " + n)
    }

    private static func rectDict(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height] }
    private static func rect(_ d: [String: Double]?) -> CGRect? { d.map { CGRect(x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: $0["w"] ?? 0, height: $0["h"] ?? 0) } }

    /// every visible (not minimized) standard window of every regular app except this one
    static func save(_ name: String) -> (Bool, String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return (false, "a layout needs a name") }
        let scr = WinMgr.screens()
        guard !scr.isEmpty else { return (false, "no screen") }
        var out: [[String: Any]] = []
        for a in WinMgr.apps() where a.bundleIdentifier != Bundle.main.bundleIdentifier {
            for w in WinMgr.windows(of: a) {
                guard !WinMgr.isMinimized(w.el), let f = WinMgr.frame(w.el), f.width > 40, f.height > 40,
                      (WinMgr.attr(w.el, "AXFullScreen") as? Bool) != true else { continue }
                let d = WinMgr.screenOf(f, scr), v = d.visible
                out.append(["app": w.app, "bundle": a.bundleIdentifier ?? "", "path": a.bundleURL?.path ?? "", "title": w.title,
                            "display": d.name, "displayNumber": d.n, "frame": rectDict(f), "visible": rectDict(v),
                            "frac": ["x": (f.minX - v.minX) / v.width, "y": (f.minY - v.minY) / v.height, "w": f.width / v.width, "h": f.height / v.height],
                            "z": WinMgr.zOrder(w.id), "id": Int(w.id)])
            }
        }
        out.sort { ($0["z"] as? Int ?? 0) < ($1["z"] as? Int ?? 0) }
        mkdirs(dir)
        let doc: [String: Any] = ["name": n, "saved": ISO8601DateFormatter().string(from: Date()),
                                  "displays": scr.map { ["name": $0.name, "n": $0.n, "visible": rectDict($0.visible)] }, "windows": out]
        guard let d = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else { return (false, "could not write") }
        try? d.write(to: URL(fileURLWithPath: path(n)))
        return (true, "saved \(n): \(out.count) windows on \(scr.count) display\(scr.count == 1 ? "" : "s")")
    }

    /// the display by name (and size), else the nearest by size
    static func target(_ scr: [WinMgr.Scr], _ name: String, _ sv: CGRect) -> (scr: WinMgr.Scr, fallback: Bool) {
        for s in scr where s.name == name && abs(s.visible.width - sv.width) < 2 && abs(s.visible.height - sv.height) < 2 { return (s, false) }
        for s in scr where s.name == name { return (s, false) }
        var best = scr[0], bd = Double.infinity
        for s in scr { let d = abs(Double(s.visible.width * s.visible.height - sv.width * sv.height)); if d < bd { bd = d; best = s } }
        return (best, true)
    }

    static func run(_ name: String) -> (Bool, String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path(name))),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let wins = doc["windows"] as? [[String: Any]] else { return (false, "no layout called " + name) }
        var notes: [String] = []
        // 1. open the apps that are not running, in the background (no focus), wait for their window
        var opened: Set<String> = []
        for w in wins {
            let b = w["bundle"] as? String ?? "", p = w["path"] as? String ?? ""
            guard !b.isEmpty, !opened.contains(b), WinMgr.apps().first(where: { $0.bundleIdentifier == b }) == nil else { continue }
            opened.insert(b)
            let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            pr.arguments = p.isEmpty ? ["-g", "-b", b] : ["-g", p]
            try? pr.run(); pr.waitUntilExit()
            notes.append("opened " + (w["app"] as? String ?? b))
        }
        for b in opened {
            let end = Date().addingTimeInterval(20)
            while Date() < end {
                if let a = WinMgr.apps().first(where: { $0.bundleIdentifier == b }), !WinMgr.windows(of: a).isEmpty { break }
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        // 2. place every window, matched by app and title, else the next unmatched window of that app
        let scr = WinMgr.screens()
        if scr.isEmpty { return (false, "no screen") }
        var used: Set<CGWindowID> = []
        var placed = 0, refused: [String] = [], missing: [String] = [], fallbacks: Set<String> = []
        var raise: [(Int, AXUIElement)] = []
        for w in wins {
            let b = w["bundle"] as? String ?? "", title = w["title"] as? String ?? "", label = (w["app"] as? String ?? b) + " \"" + title + "\""
            guard let a = WinMgr.apps().first(where: { $0.bundleIdentifier == b }) else { missing.append(label); continue }
            let cands = WinMgr.windows(of: a).filter { !used.contains($0.id) }
            guard let win = cands.first(where: { Int($0.id) == (w["id"] as? Int ?? -1) }) ?? cands.first(where: { $0.title == title }) ?? cands.first(where: { !$0.title.isEmpty && title.contains($0.title) || $0.title.contains(title) && !title.isEmpty })
                    ?? cands.max(by: { (WinMgr.frame($0.el)?.area ?? 0) < (WinMgr.frame($1.el)?.area ?? 0) }) else { missing.append(label); continue }
            used.insert(win.id)
            guard let saved = rect(w["frame"] as? [String: Double]), let sv = rect(w["visible"] as? [String: Double]),
                  let fr = w["frac"] as? [String: Double] else { continue }
            // the display: by name, else the nearest by size (and say so)
            let dn = w["display"] as? String ?? ""
            let pick = target(scr, dn, sv)
            if pick.fallback { fallbacks.insert(dn + " -> " + pick.scr.name) }
            let t = pick.scr
            let same = abs(t.visible.minX - sv.minX) < 2 && abs(t.visible.minY - sv.minY) < 2 && abs(t.visible.width - sv.width) < 2 && abs(t.visible.height - sv.height) < 2
            let goal = same ? saved : CGRect(x: t.visible.minX + (fr["x"] ?? 0) * t.visible.width, y: t.visible.minY + (fr["y"] ?? 0) * t.visible.height,
                                             width: (fr["w"] ?? 0) * t.visible.width, height: (fr["h"] ?? 0) * t.visible.height).integral
            if WinMgr.isMinimized(win.el) { AXUIElementSetAttributeValue(win.el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            WinMgr.setFrame(win.el, goal)
            if let now = WinMgr.frame(win.el) {
                if abs(now.width - goal.width) > 2 || abs(now.height - goal.height) > 2 { refused.append("\(label) wants \(Int(now.width))x\(Int(now.height)), not \(Int(goal.width))x\(Int(goal.height))") }
                else if abs(now.minX - goal.minX) > 2 || abs(now.minY - goal.minY) > 2 { refused.append("\(label) stayed at \(Int(now.minX)),\(Int(now.minY))") }
            }
            placed += 1; raise.append((w["z"] as? Int ?? 0, win.el))
        }
        // 3. the stacking inside each app, back to front (AXRaise never takes focus)
        for (_, e) in raise.sorted(by: { $0.0 > $1.0 }) { AXUIElementPerformAction(e, kAXRaiseAction as CFString) }
        var msg = "layout \(name): \(placed) of \(wins.count) windows placed"
        if !notes.isEmpty { msg += "; " + notes.joined(separator: ", ") }
        if !fallbacks.isEmpty { msg += "; display missing, used the nearest: " + fallbacks.sorted().joined(separator: ", ") }
        if !missing.isEmpty { msg += "; no window found for: " + missing.joined(separator: ", ") }
        if !refused.isEmpty { msg += "; refused or stuck: " + refused.joined(separator: "; ") }
        return (true, msg)
    }

    static func fromInbox(_ cmd: String, _ arg: String) -> (Bool, String) {
        let n = arg.trimmingCharacters(in: .whitespaces)
        switch cmd {
        case "layout-save:": return save(n)
        case "layout-new:": return save(todayName())
        case "layout-run:": return run(n)
        case "layout-delete:": return delete(n)
        default: return (true, names().joined(separator: "\n"))
        }
    }
}
