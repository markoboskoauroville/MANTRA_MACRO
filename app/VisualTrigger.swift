import Foundation

final class VisualTriggerWatch {
    static let shared = VisualTriggerWatch()

    private var timer: Timer?
    private let queue = DispatchQueue(label: "macro.visual-trigger", qos: .utility)
    private var checking = false
    private var seen: [String: Bool] = [:]

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
            guard trigger.on, Macros.exists(name) else { return nil }
            let zone = engine.settings.zones[trigger.image]
            return (name, trigger, zone.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) })
        }
        guard !snapshots.isEmpty else { return }
        let live = Set(snapshots.map(\.0))
        seen = seen.filter { live.contains($0.key) }
        checking = true
        queue.async {
            var matches: [String: Bool] = [:]
            for (name, trigger, region) in snapshots {
                matches[name] = Eye.search(Pictures.path(trigger.image), region: region, threshold: 0.85) != nil
            }
            DispatchQueue.main.async {
                self.checking = false
                for (name, present) in matches {
                    let wasPresent = self.seen[name] ?? false
                    self.seen[name] = present
                    guard present, !wasPresent, !Engine.shared.recording else { continue }
                    Engine.shared.note = "visual trigger: " + name
                    Engine.shared.runNamed(name)
                }
            }
        }
    }
}
