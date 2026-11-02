import AppKit
import ApplicationServices

// v9 (Marko, 2.11.2026: "Please build a Python API for every Star app so it's possible to control it remotely
// effortlessly ... instead of building 40 startups APIs, we need to have one common"): Macro Recorder holds the
// Accessibility permission, so the common Star API (STAR_API) asks it, through the inbox, to read an app's window and
// press its buttons by name. Every control of every Mantra app is an AX button (MANTRA_MANIFEST), so this reaches all.
//   "ax-read: <app>"            the app's windows: every button, check box, text and field, as JSON lines
//   "ax-press: <app> | <label>" presses the first control whose title, description or value is <label> (exact, then
//                               starting with it, then containing it; case and spaces ignored)
//   "ax-quit: <app>"            asks the app to quit, as ⌘Q would
enum AX {
    struct Node { let role: String; let label: String; let el: AXUIElement; let window: String }

    static func app(_ name: String) -> NSRunningApplication? {
        let n = norm(name)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        return apps.first { norm($0.localizedName ?? "") == n }
            ?? apps.first { norm($0.localizedName ?? "").hasPrefix(n) }
            ?? apps.first { norm($0.localizedName ?? "").contains(n) }
            ?? apps.first { norm($0.bundleURL?.deletingPathExtension().lastPathComponent ?? "").contains(n) }
    }

    static func norm(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace }
    }

    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private static func str(_ e: AXUIElement, _ a: String) -> String {
        if let s = attr(e, a) as? String { return s }
        if let n = attr(e, a) as? NSNumber { return n.stringValue }
        return ""
    }

    static let wanted: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton",
                                      "AXStaticText", "AXTextField", "AXTextArea", "AXSlider", "AXLink", "AXTab"]

    static func nodes(_ app: NSRunningApplication) -> [Node] {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var out: [Node] = []
        let windows = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows {
            let wt = str(w, kAXTitleAttribute)
            var stack: [(AXUIElement, Int)] = [(w, 0)]
            var seen = 0
            while let (e, d) = stack.popLast(), seen < 4000 {
                seen += 1
                let role = str(e, kAXRoleAttribute)
                if wanted.contains(role) {
                    let label = [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute), str(e, kAXHelpAttribute)]
                        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                    if !label.isEmpty || role != "AXStaticText" { out.append(Node(role: role, label: label, el: e, window: wt)) }
                }
                if d < 40, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                    for k in kids.reversed() { stack.append((k, d + 1)) }
                }
            }
        }
        return out
    }

    static func read(_ name: String) -> (Bool, String) {
        guard AXIsProcessTrusted() else { return (false, "Macro Recorder has no Accessibility permission") }
        guard let a = app(name) else { return (false, "not running: " + name) }
        let lines = nodes(a).map { n -> String in
            let o: [String: String] = ["role": String(n.role.dropFirst(2)).lowercased(), "label": n.label, "window": n.window]
            let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
            return String(data: d, encoding: .utf8) ?? ""
        }
        return (true, ([#"{"app":"\#(a.localizedName ?? name)"}"#] + lines).joined(separator: "\n"))
    }

    static func press(_ name: String, _ label: String) -> (Bool, String) {
        guard AXIsProcessTrusted() else { return (false, "Macro Recorder has no Accessibility permission") }
        guard let a = app(name) else { return (false, "not running: " + name) }
        let want = norm(label)
        let all = nodes(a).filter { $0.role != "AXStaticText" }
        let hit = all.first { norm($0.label) == want } ?? all.first { norm($0.label).hasPrefix(want) }
            ?? all.first { norm($0.label).contains(want) }
        guard let h = hit else { return (false, "no control called \"\(label)\" in \(a.localizedName ?? name)") }
        let r = AXUIElementPerformAction(h.el, kAXPressAction as CFString)
        return r == .success ? (true, "pressed \(h.label) (\(h.role.dropFirst(2))) in \(a.localizedName ?? name)")
                             : (false, "\(h.label) did not take the press (AX error \(r.rawValue))")
    }

    static func quit(_ name: String) -> (Bool, String) {
        guard let a = app(name) else { return (true, "was not running: " + name) }
        let n = a.localizedName ?? name
        return a.terminate() ? (true, "asked \(n) to quit") : (false, "\(n) refused to quit")
    }
}
