// DashboardView.swift: the Dashboard window (v41, 28.11.2026). One plain resizable window, titled once; the list is Dashboard.rows().
// Rows: name, kind, state, since, fired / ran, last, PLAY PAUSE STOP; tick boxes for several rows at once; STOP ALL at the top;
// the stored macros below, to start one or several. Text wraps and is never cut (swift-apps.md "Never cut text").
import SwiftUI
import AppKit

private let stampF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm:ss"; return f }()
private func ago(_ d: Date, _ now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 90 { return "\(s) s" }
    if s < 5400 { return "\(s / 60) min" }
    if s < 172800 { return "\(s / 3600) h" }
    return "\(s / 86400) days"
}

private func stateColor(_ s: String) -> Color {
    switch s {
    case "WATCHING", "ARMED", "RUNNING", "LISTENING": return .on
    case "PAUSED", "QUEUED": return .amber
    default: return .off
    }
}

struct DashboardView: View {
    @ObservedObject var e = Engine.shared
    @State private var selected = Set<String>()
    @State private var picks = Set<String>()
    @State private var now = Date()
    @State private var message = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let wCheck: CGFloat = 26, wKind: CGFloat = 104, wState: CGFloat = 92, wSince: CGFloat = 128, wCount: CGFloat = 58, wLast: CGFloat = 128, wCtl: CGFloat = 176

    var body: some View {
        let rows = Dashboard.shared.rows()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(Dashboard.shared.summary().isEmpty ? "Nothing is armed or running" : "Active: " + Dashboard.shared.summary())
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(.sand)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Word(text: "STOP ALL", color: .rec, size: 14, help: "every trigger OFF (saved) and every running macro stopped") {
                    let r = Dashboard.shared.stopAll()
                    message = "stopped \((r["stopped"] as? [String])?.count ?? 0)"; selected = []
                }
            }
            if PauseGate.shared.paused {
                HStack(alignment: .center, spacing: 10) {
                    Text("All macros are paused (by \(PauseGate.shared.by)): nothing fires and nothing starts until RESUME. The rows below show what would be armed.")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.amber).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Word(text: "RESUME", color: .on, size: 13, help: "the same as Resume macros in the menu") {
                        PauseGate.shared.resume(by: "dashboard"); message = "resumed"
                    }
                }
            }
            Text("A trigger that is on starts its macro by itself. STOP switches it off for good (saved), PAUSE holds it until PLAY while the app runs.")
                .font(.system(size: 11)).foregroundColor(.off).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 10) {
                Word(text: "SELECT ALL", color: .sand, help: "tick every row that can be changed") {
                    selected = Set(rows.filter { $0.canPlay || $0.canPause || $0.canStop }.map { $0.id })
                }
                Word(text: "NONE", color: .sand) { selected = [] }
                Text(selected.isEmpty ? "tick rows to act on several" : "\(selected.count) ticked").font(.system(size: 11)).foregroundColor(.off)
                Spacer()
                Word(text: "PLAY TICKED", color: .on) { act("play", Array(selected)) }
                Word(text: "PAUSE TICKED", color: .amber) { act("pause", Array(selected)) }
                Word(text: "STOP TICKED", color: .rec) { act("stop", Array(selected)) }
            }
            HStack(alignment: .center, spacing: 8) {
                Color.clear.frame(width: wCheck, height: 1)
                head("NAME").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                head("KIND").frame(width: wKind, alignment: .leading)
                head("STATE").frame(width: wState, alignment: .leading)
                head("SINCE").frame(width: wSince, alignment: .leading)
                head("COUNT").frame(width: wCount, alignment: .leading)
                head("LAST").frame(width: wLast, alignment: .leading)
                head("").frame(width: wCtl, alignment: .center)
            }.padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 6) { ForEach(rows, id: \.id) { row in rowView(row) } }
            }.frame(maxHeight: .infinity)
            Section(title: "START MACROS", hint: "Tick one or several stored macros and press PLAY. Macros that use the mouse and keyboard wait their turn; background ones run together.") {
                HStack(alignment: .center, spacing: 10) {
                    Word(text: "PLAY CHECKED", color: .on, size: 13) {
                        let r = Dashboard.shared.start(picks.sorted())
                        message = "started \((r["started"] as? [String])?.count ?? 0)"; picks = []
                    }
                    Word(text: "CLEAR", color: .sand) { picks = [] }
                    Text(picks.isEmpty ? "" : "\(picks.count) checked").font(.system(size: 11)).foregroundColor(.off)
                    Spacer()
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(Macros.list(), id: \.self) { n in
                            HStack(alignment: .center, spacing: 6) {
                                Word(text: picks.contains(n) ? "☑" : "☐", color: picks.contains(n) ? .on : .off, size: 14, ax: "pick-" + n) {
                                    if picks.contains(n) { picks.remove(n) } else { picks.insert(n) }
                                }
                                Text(n).font(.system(size: 12)).foregroundColor(.sand).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }.frame(minHeight: 70, maxHeight: 170)
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(.amber) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ground)
        .onReceive(timer) { now = $0 }
    }

    private func head(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5).foregroundColor(.off)
    }

    private func act(_ action: String, _ ids: [String]) {
        let r = Dashboard.shared.act(action, ids: ids)
        let bad = r.filter { ($0["ok"] as? Bool) != true }.compactMap { $0["error"] as? String }
        message = bad.isEmpty ? "" : bad.joined(separator: " · ")
    }

    private func rowView(_ row: DashRow) -> some View {
        let can = row.canPlay || row.canPause || row.canStop
        return HStack(alignment: .center, spacing: 8) {
            Group {
                if can {
                    Word(text: selected.contains(row.id) ? "☑" : "☐", color: selected.contains(row.id) ? .on : .off, size: 15, ax: "tick-" + row.id) {
                        if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
                    }
                } else { Color.clear }
            }.frame(width: wCheck)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13, weight: .bold)).foregroundColor(.sand)
                Text(row.detail).font(.system(size: 11)).foregroundColor(.off)
            }.fixedSize(horizontal: false, vertical: true).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text(row.kind).font(.system(size: 12)).foregroundColor(.sand).frame(width: wKind, alignment: .leading)
            Text(row.state).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(stateColor(row.state))
                .frame(width: wState, alignment: .leading)
            Text(row.since.map { stampF.string(from: $0) + "\n" + ago($0, now) } ?? "-")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.sand).fixedSize(horizontal: false, vertical: true)
                .frame(width: wSince, alignment: .leading)
            Text("\(row.count)\n" + row.countLabel).font(.system(size: 11, design: .monospaced)).foregroundColor(.sand)
                .frame(width: wCount, alignment: .leading)
            Text(row.last.map { stampF.string(from: $0) + "\n" + ago($0, now) + " ago" } ?? "never")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.sand).fixedSize(horizontal: false, vertical: true)
                .frame(width: wLast, alignment: .leading)
            HStack(alignment: .center, spacing: 6) {
                Word(text: "PLAY", color: row.canPlay ? .on : .off, ax: "play-" + row.id) { if row.canPlay { act("play", [row.id]) } }
                Word(text: "PAUSE", color: row.canPause ? .amber : .off, ax: "pause-" + row.id) { if row.canPause { act("pause", [row.id]) } }
                Word(text: "STOP", color: row.canStop ? .rec : .off, ax: "stop-" + row.id) { if row.canStop { act("stop", [row.id]) } }
            }.frame(width: wCtl, alignment: .center)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.card))
    }
}

final class DashboardWindow {
    static var window: NSWindow?
    /// focus false (the API): the window is put on the screen without taking the keyboard from whoever has it
    static func show(focus: Bool = true) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Dashboard · Macro Recorder (Mantra)"; w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: DashboardView())
            host.sizingOptions = []                  // the window keeps its own size: the content never makes it taller
            w.contentView = host
            w.setContentSize(NSSize(width: 1060, height: 640))
            w.minSize = NSSize(width: 960, height: 420)
            w.backgroundColor = GROUND
            w.center()
            window = w
        }
        guard let w = window else { return }
        if focus { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) } else { w.orderFrontRegardless() }
    }
}
