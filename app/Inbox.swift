import Foundation

// Inbox (v5, Marko 31.10.2026: "We are not using Hammerspoon because Macro Recorder is now your ally"): Claude Code (or
// any script) drops <id>.ahk into ~/.mantra_macro/inbox; the app runs it like a macro and writes <id>.result.json next
// to it: {"ok": true|false, "message": "...", "line": n}. A file holding only "run: <name>" plays that stored macro.
// The `macro` command (tools/macro) writes the file and waits for the result.
let INBOX = DIR + "/inbox"

final class Inbox {
    static let shared = Inbox()
    private var timer: Timer?
    private var busy = false

    func start() {
        mkdirs(INBOX)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.look() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func look() {
        guard !busy, !Engine.shared.recording else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: INBOX) else { return }
        guard let f = names.filter({ $0.hasSuffix(".ahk") }).sorted().first else { return }
        let path = INBOX + "/" + f, id = String(f.dropLast(4))
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? fm.removeItem(atPath: path)
        busy = true
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var script = text, name = "inbox " + id
        if trimmed.hasPrefix("run:") {
            let n = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard let t = readText(MAC_DIR + "/" + n + ".ahk") else { return finish(id, false, "no macro called " + n, nil) }
            script = t; name = n
        }
        Engine.shared.runScript(script, name) { ok, msg, line in self.finish(id, ok, msg, line) }
    }
    private func finish(_ id: String, _ ok: Bool, _ msg: String?, _ line: Int?) {
        var o: [String: Any] = ["ok": ok, "at": Date().timeIntervalSince1970]
        if let m = msg { o["message"] = m }
        if let l = line { o["line"] = l }
        if let d = try? JSONSerialization.data(withJSONObject: o) {
            let tmp = INBOX + "/" + id + ".result.tmp"
            try? d.write(to: URL(fileURLWithPath: tmp))
            try? FileManager.default.moveItem(atPath: tmp, toPath: INBOX + "/" + id + ".result.json")
        }
        busy = false
    }
}
