import Foundation

final class VisualTriggerWatch {
    static let shared = VisualTriggerWatch()

    private var timer: Timer?
    private let queue = DispatchQueue(label: "macro.visual-trigger", qos: .utility)
    private var checking = false
    private var seen: [String: Bool] = [:]
    /// v41: the triggers the Dashboard has paused (this run of the app only; a restart arms them again from settings.json)
    var paused = Set<String>()

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        seen.removeAll()
    }

    func changed(_ macro: String? = nil) {
        if let macro { seen[macro] = false }
        else { seen.removeAll() }
    }

    private func tick() {
        guard !checking else { return }
        let engine = Engine.shared
        guard !engine.recording, !PauseGate.shared.paused else { return }
        let snapshots = engine.settings.visualTriggers.compactMap { name, trigger -> (String, VisualTrigger, CGRect?)? in
            guard trigger.on, !paused.contains(name), Macros.exists(name) else { return nil }
            let zone = engine.settings.zones[trigger.image]
            return (name, trigger, zone.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) })
        }
        guard !snapshots.isEmpty else { return }
        let live = Set(snapshots.map(\.0))
        seen = seen.filter { live.contains($0.key) }
        checking = true
        queue.async {
            var matches: [String: Bool] = [:]
            var hits: [String: ImageHit] = [:]
            for (name, trigger, region) in snapshots {
                let hit = Eye.search(Pictures.path(trigger.image), region: region, threshold: 0.85)
                matches[name] = hit != nil
                if let hit { hits[name] = hit }
            }
            DispatchQueue.main.async {
                self.checking = false
                for (name, present) in matches {
                    let wasPresent = self.seen[name] ?? false
                    self.seen[name] = present
                    guard present, !wasPresent, !Engine.shared.recording else { continue }
                    Engine.shared.note = "visual trigger: " + name
                    // v41: written down before anything runs: when, which picture, how well it matched, and where
                    var o: [String: Any] = ["event": "trigger_fired", "kind": "visual trigger", "name": name, "by": "visual trigger",
                                            "threshold": 0.85]
                    if let t = Engine.shared.settings.visualTriggers[name] { o["image"] = t.image }
                    if let h = hits[name] { o["score"] = (h.score * 1000).rounded() / 1000; o["match"] = [Int(h.x), Int(h.y), Int(h.w), Int(h.h)] }
                    RunLog.shared.add(o)
                    Engine.shared.runNamed(name, source: "visual trigger")
                }
            }
        }
    }
}
