import Foundation

// Inbox (v5, Marko 31.10.2026: "We are not using Hammerspoon because Macro Recorder is now your ally"): Claude Code (or
// any script) drops <id>.ahk into ~/.mantra_macro/inbox; the app runs it like a macro and writes <id>.result.json next
// to it: {"ok": true|false, "message": "...", "line": n}. A file holding only "run: <name>" plays that stored macro.
// The `macro` command (tools/macro) writes the file and waits for the result.
// v8 (1.11.2026): "recalibrate: <name>" runs RECALIBRATE, "view: <name> [| app]" stores the view; the report comes back as the message.
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
        guard !busy else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: INBOX) else { return }
        guard let f = names.filter({ $0.hasSuffix(".ahk") }).sorted().first else { return }
        let path = INBOX + "/" + f, id = String(f.dropLast(4))
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // while it records, only "stop:" is taken; everything else waits for the recording to end
        if Engine.shared.recording && trimmed != "stop:" { return }
        try? fm.removeItem(atPath: path)
        busy = true
        // v8: "record: <name>" records a new macro under that name (it stores the view of the windows clicked in);
        // "stop:" ends it and saves it
        if trimmed.hasPrefix("record:") {
            let n = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
            if Macros.exists(Macros.clean(n)) { return finish(id, false, "there is already a macro called " + n, nil) }
            Engine.shared.newMacroNamed(n)
            return finish(id, Engine.shared.recording, Engine.shared.recording ? "recording " + n : "could not start recording (Input Monitoring?)", nil)
        }
        if trimmed == "stop:" {
            let was = Engine.shared.recording, n = Engine.shared.pending
            let count = was ? Engine.shared.stopRecording() : 0
            return finish(id, was, was ? "saved \(n ?? "last recording"), \(count) events" : "nothing was recording", nil)
        }
        // v8: "recalibrate: <name>" and "view: <name> [| app]" answer with the report, nothing is played
        for (cmd, isRecal) in [("recalibrate:", true), ("view:", false)] where trimmed.hasPrefix(cmd) {
            let arg = trimmed.dropFirst(cmd.count).trimmingCharacters(in: .whitespaces)
            let parts = arg.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            DispatchQueue.global(qos: .userInitiated).async {
                let r = isRecal ? Recal.recalibrate(parts[0]) : Recal.reference(parts[0], app: parts.count > 1 ? parts[1] : nil)
                DispatchQueue.main.async {
                    if Engine.shared.current == parts[0] { _ = Engine.shared.loadMacro(parts[0], quiet: true) }
                    Engine.shared.changed()
                    self.finish(id, r.ok, r.report.isEmpty ? r.summary : r.report, nil)
                }
            }
            return
        }
        if trimmed.hasPrefix("run:") {
            let n = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard has(MAC_DIR + "/" + n + ".ahk") else { return finish(id, false, "no macro called " + n, nil) }
            // a stored macro plays the way the slots play it: recalibrated first when its window moved (v8)
            return Engine.shared.runMacro(n) { ok, msg, line in self.finish(id, ok, msg, line) }
        }
        Engine.shared.runScript(text, "inbox " + id) { ok, msg, line in self.finish(id, ok, msg, line) }
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
