// WinMgr.swift: move and arrange windows through Accessibility only (v20, 9.11.2026).
//
// Ported from Rectangle (https://github.com/rxhanson/Rectangle), MIT License,
// Copyright (c) 2019-2026 Ryan Hanson; based on Spectacle, Copyright (c) 2017 Eric Czarny.
// Permission notice: see THIRD_PARTY/Rectangle-LICENSE.txt, which must stay with every copy of this file.
// From Rectangle: AccessibilityElement.setFrame (size, position, size; the AXEnhancedUserInterface workaround),
// CGRect.screenFlipped (NSScreen bottom-left to Accessibility top-left), the window calculations (Maximize,
// AlmostMaximize, Center, LeftRightHalf, Top/BottomHalf, First/Center/Last Third, First/Last TwoThirds, corner
// quarters, orientation aware thirds) and NextPrevDisplay (DisplayTransfer: the same proportions on the other screen).
// Never moves or clicks the real mouse, never takes focus.
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WinMgr {
    // MARK: Accessibility helpers
    static func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
        var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
    }
    static func point(_ e: AXUIElement, _ n: String) -> CGPoint? {
        guard let v = attr(e, n), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    static func size(_ e: AXUIElement, _ n: String) -> CGSize? {
        guard let v = attr(e, n), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero; return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
    @discardableResult static func setPos(_ e: AXUIElement, _ p: CGPoint) -> Bool {
        var p = p; guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v) == .success
    }
    @discardableResult static func setSize(_ e: AXUIElement, _ s: CGSize) -> Bool {
        var s = s; guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, v) == .success
    }
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = point(e, kAXPositionAttribute), let s = size(e, kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }
    static func isMinimized(_ e: AXUIElement) -> Bool { (attr(e, kAXMinimizedAttribute) as? Bool) ?? false }

    /// Rectangle: size, then position, then size again (macOS enforces sizes that fit the current display), with
    /// AXEnhancedUserInterface switched off while it happens (it makes the window animate and the sets fail).
    static func setFrame(_ w: AXUIElement, _ f: CGRect) {
        var pid: pid_t = 0; AXUIElementGetPid(w, &pid)
        let app = AXUIElementCreateApplication(pid)
        let enhanced = (attr(app, "AXEnhancedUserInterface") as? Bool) ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        setSize(w, f.size); setPos(w, f.origin); setSize(w, f.size)
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    // MARK: screens (main thread snapshot)
    struct Scr { let n: Int; let name: String; let full: CGRect; let visible: CGRect }   // both in Accessibility coordinates
    /// Rectangle CGRect.screenFlipped: the primary screen's top is y = 0, y grows downward.
    static func flip(_ r: CGRect, _ primaryMaxY: CGFloat) -> CGRect { CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height) }
    static func screens() -> [Scr] {
        let get: () -> [Scr] = {
            let all = NSScreen.screens, top = all.first?.frame.maxY ?? 0
            return all.enumerated().map { Scr(n: $0.offset + 1, name: $0.element.localizedName, full: flip($0.element.frame, top), visible: flip($0.element.visibleFrame, top)) }
        }
        return Thread.isMainThread ? get() : DispatchQueue.main.sync(execute: get)
    }
    /// the screen a window mostly lies on (largest overlap), else the nearest by centre
    static func screenOf(_ f: CGRect, _ s: [Scr]) -> Scr {
        if let b = s.max(by: { f.intersection($0.full).area < f.intersection($1.full).area }), f.intersection(b.full).area > 0 { return b }
        let c = CGPoint(x: f.midX, y: f.midY)
        return s.min(by: { dist(c, $0.full) < dist(c, $1.full) }) ?? s[0]
    }
    static func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat { hypot(p.x - r.midX, p.y - r.midY) }
    /// a display given as a number (1 = the one with the menu bar) or a name part ("BenQ", "MacBook" = the built-in one)
    static func pick(_ which: String, _ s: [Scr]) -> Scr? {
        let w = which.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(w) { return s.first { $0.n == n } }
        let name = w == "macbook" || w == "built-in" || w == "builtin" ? "color lcd" : w
        return s.first { $0.name.lowercased().contains(name) } ?? (w == "macbook" ? s.first { $0.name.lowercased().contains("built") || $0.name.lowercased().contains("liquid") } : nil)
    }

    // MARK: windows
    struct Win { let app: String; let pid: pid_t; let title: String; let el: AXUIElement; let id: CGWindowID }
    static func windows(of a: NSRunningApplication) -> [Win] {
        let root = AXUIElementCreateApplication(a.processIdentifier)
        let ws = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return ws.compactMap { e in
            guard (attr(e, kAXRoleAttribute) as? String) == kAXWindowRole as String else { return nil }
            var id: CGWindowID = 0; _ = _AXUIElementGetWindow(e, &id)
            return Win(app: a.localizedName ?? "", pid: a.processIdentifier, title: (attr(e, kAXTitleAttribute) as? String) ?? "", el: e, id: id)
        }
    }
    static func apps() -> [NSRunningApplication] {
        let get: () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular } }
        return Thread.isMainThread ? get() : DispatchQueue.main.sync(execute: get)
    }
    /// like WinActivate: a window whose title contains the text, else the app's biggest window; empty = the front app's focused window
    static func find(_ title: String) -> Win? {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        let all = apps()
        if t.isEmpty {
            let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
            guard let a = front else { return nil }
            let root = AXUIElementCreateApplication(a.processIdentifier)
            if let fw = attr(root, kAXFocusedWindowAttribute) { var id: CGWindowID = 0; let e = fw as! AXUIElement; _ = _AXUIElementGetWindow(e, &id)
                return Win(app: a.localizedName ?? "", pid: a.processIdentifier, title: (attr(e, kAXTitleAttribute) as? String) ?? "", el: e, id: id) }
            return windows(of: a).first
        }
        var byApp: [NSRunningApplication: [Win]] = [:]
        for a in all { byApp[a] = windows(of: a) }
        if t.hasPrefix("#"), let n = UInt32(t.dropFirst()) {          // "#123": that window id (win-list prints it)
            for a in all { if let w = byApp[a]?.first(where: { $0.id == n }) { return w } }
            return nil
        }
        for a in all { if let w = byApp[a]?.first(where: { $0.title.lowercased().contains(t) }) { return w } }
        let app = all.first { ($0.localizedName ?? "").lowercased() == t } ?? all.first { ($0.localizedName ?? "").lowercased().contains(t) }
        guard let a = app, let ws = byApp[a] else { return nil }
        return ws.max { (frame($0.el)?.area ?? 0) < (frame($1.el)?.area ?? 0) }
    }
    /// z-order, 1 = frontmost, by CGWindowList (front to back); 0 when the window is not on screen (minimized, other Space)
    static func zOrder(_ id: CGWindowID) -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { $0[kCGWindowNumber as String] as? Int }
        return ids.firstIndex(of: Int(id)).map { $0 + 1 } ?? 0
    }

    static func fmt(_ w: Win, _ s: [Scr]) -> String {
        guard let f = frame(w.el) else { return "\(w.app)\t\(w.title)\t?" }
        let d = screenOf(f, s)
        return "\(w.app)\t\(w.title)\t\(Int(f.minX))\t\(Int(f.minY))\t\(Int(f.width))\t\(Int(f.height))\t\(d.n):\(d.name)\t\(zOrder(w.id))\t#\(w.id)\(isMinimized(w.el) ? "\tminimized" : "")"
    }
    static func list() -> String {
        let s = screens()
        return apps().flatMap { windows(of: $0) }.map { fmt($0, s) }.joined(separator: "\n")
    }

    // MARK: commands
    static var before: [CGWindowID: CGRect] = [:]     // the frame before maximize / snap, for WinRestore (Rectangle's restore rect)

    /// WinMove x, y, w, h: nil = keep (AutoHotkey: empty). Coordinates are screen points, top left of the primary screen = 0, 0.
    static func move(_ title: String, _ x: Double?, _ y: Double?, _ w: Double?, _ h: Double?) -> (Bool, String) {
        guard let win = find(title), let f = frame(win.el) else { return (false, "no window " + title) }
        before[win.id] = f
        let t = CGRect(x: x ?? f.minX, y: y ?? f.minY, width: w ?? f.width, height: h ?? f.height)
        setFrame(win.el, t)
        return (true, fmt(win, screens()))
    }
    static func minimize(_ title: String) -> (Bool, String) {
        guard let win = find(title) else { return (false, "no window " + title) }
        AXUIElementSetAttributeValue(win.el, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        return (true, fmt(win, screens()))
    }
    static func maximize(_ title: String) -> (Bool, String) { snap(title, "maximize", nil) }
    /// un-minimize, else put back the frame from before the last move / maximize / snap done through here
    static func restore(_ title: String) -> (Bool, String) {
        guard let win = find(title) else { return (false, "no window " + title) }
        if isMinimized(win.el) { AXUIElementSetAttributeValue(win.el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        else if let b = before[win.id] { setFrame(win.el, b); before[win.id] = nil }
        return (true, fmt(win, screens()))
    }
    /// AXRaise lifts the window above the other windows of its own app; across apps it needs the app in front, which
    /// would take focus, so it does not (documented in SCRIPT.md).
    static func moveTop(_ title: String) -> (Bool, String) {
        guard let win = find(title) else { return (false, "no window " + title) }
        AXUIElementPerformAction(win.el, kAXRaiseAction as CFString)
        return (true, fmt(win, screens()))
    }
    /// raises the app's other windows over this one (the only way through Accessibility); other apps are not touched
    static func moveBottom(_ title: String) -> (Bool, String) {
        guard let win = find(title), let app = apps().first(where: { $0.processIdentifier == win.pid }) else { return (false, "no window " + title) }
        for o in windows(of: app) where o.id != win.id && !isMinimized(o.el) { AXUIElementPerformAction(o.el, kAXRaiseAction as CFString) }
        return (true, fmt(win, screens()))
    }

    static let actions = ["left-half", "right-half", "top-half", "bottom-half", "maximize", "almost-maximize", "center",
                          "first-third", "center-third", "last-third", "first-two-thirds", "last-two-thirds",
                          "top-left", "top-right", "bottom-left", "bottom-right", "next-display", "previous-display"]

    /// Rectangle's calculations on the visible frame v (menu bar and Dock already out), Accessibility coordinates
    static func rect(_ action: String, _ v: CGRect, _ cur: CGRect) -> CGRect? {
        let landscape = v.width > v.height
        func third(_ i: Int, _ span: Int) -> CGRect {   // Rectangle OrientationAware: on a portrait screen thirds are rows
            landscape ? CGRect(x: v.minX + (v.width / 3).rounded(.down) * CGFloat(i), y: v.minY, width: (v.width / 3).rounded(.down) * CGFloat(span) + (i + span == 3 ? v.width - (v.width / 3).rounded(.down) * 3 : 0), height: v.height)
                      : CGRect(x: v.minX, y: v.minY + (v.height / 3).rounded(.down) * CGFloat(i), width: v.width, height: (v.height / 3).rounded(.down) * CGFloat(span) + (i + span == 3 ? v.height - (v.height / 3).rounded(.down) * 3 : 0))
        }
        let hw = (v.width / 2).rounded(.down), hh = (v.height / 2).rounded(.down)
        switch action {
        case "left-half": return CGRect(x: v.minX, y: v.minY, width: hw, height: v.height)
        case "right-half": return CGRect(x: v.minX + hw, y: v.minY, width: v.width - hw, height: v.height)
        case "top-half": return CGRect(x: v.minX, y: v.minY, width: v.width, height: hh)
        case "bottom-half": return CGRect(x: v.minX, y: v.minY + hh, width: v.width, height: v.height - hh)
        case "maximize": return v
        case "almost-maximize":
            let w = (v.width * 0.9).rounded(), h = (v.height * 0.9).rounded()
            return CGRect(x: ((v.width - w) / 2).rounded() + v.minX, y: ((v.height - h) / 2).rounded() + v.minY, width: w, height: h)
        case "center":
            if cur.width > v.width && cur.height > v.height { return v }
            let w = min(cur.width, v.width), h = min(cur.height, v.height)
            return CGRect(x: ((v.width - w) / 2).rounded() + v.minX, y: ((v.height - h) / 2).rounded() + v.minY, width: w, height: h)
        case "first-third": return third(0, 1)
        case "center-third": return third(1, 1)
        case "last-third": return third(2, 1)
        case "first-two-thirds": return third(0, 2)
        case "last-two-thirds": return third(1, 2)
        case "top-left": return CGRect(x: v.minX, y: v.minY, width: hw, height: hh)
        case "top-right": return CGRect(x: v.minX + hw, y: v.minY, width: v.width - hw, height: hh)
        case "bottom-left": return CGRect(x: v.minX, y: v.minY + hh, width: hw, height: v.height - hh)
        case "bottom-right": return CGRect(x: v.minX + hw, y: v.minY + hh, width: v.width - hw, height: v.height - hh)
        default: return nil
        }
    }

    /// Rectangle DisplayTransfer: the window keeps its proportions of the visible frame; a maximized one stays maximized
    static func transfer(_ r: CGRect, from s: CGRect, to d: CGRect) -> CGRect {
        if abs(r.width - s.width) < 3 && abs(r.height - s.height) < 3 { return d }
        let w = min(r.width * d.width / s.width, d.width), h = min(r.height * d.height / s.height, d.height)
        let x = d.minX + (r.minX - s.minX) * d.width / s.width, y = d.minY + (r.minY - s.minY) * d.height / s.height
        return CGRect(x: max(d.minX, min(x, d.maxX - w)).rounded(), y: max(d.minY, min(y, d.maxY - h)).rounded(), width: w.rounded(), height: h.rounded())
    }

    static func snap(_ title: String, _ action: String, _ display: String?) -> (Bool, String) {
        let a = action.lowercased().trimmingCharacters(in: .whitespaces)
        guard actions.contains(a) else { return (false, "unknown action \"\(action)\" (" + actions.joined(separator: ", ") + ")") }
        guard let win = find(title), let cur = frame(win.el) else { return (false, "no window " + title) }
        let s = screens()
        let here = screenOf(cur, s)
        var target = here
        if a == "next-display" || a == "previous-display" {
            guard s.count > 1 else { return (false, "only one display") }
            let order = s.sorted { $0.full.minX < $1.full.minX }       // Rectangle: neighbours by x
            let i = order.firstIndex { $0.n == here.n } ?? 0
            target = order[(i + (a == "next-display" ? 1 : order.count - 1)) % order.count]
            if let d = display, !d.isEmpty, let p = pick(d, s) { target = p }
            before[win.id] = cur
            if isMinimized(win.el) { AXUIElementSetAttributeValue(win.el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            setFrame(win.el, transfer(cur, from: here.visible, to: target.visible))
            return (true, fmt(win, screens()))
        }
        if let d = display, !d.isEmpty {
            guard let p = pick(d, s) else { return (false, "no display \"\(d)\" (" + s.map { "\($0.n) \($0.name)" }.joined(separator: ", ") + ")") }
            target = p
        }
        guard let r = rect(a, target.visible, cur) else { return (false, "no such action") }
        before[win.id] = cur
        if isMinimized(win.el) { AXUIElementSetAttributeValue(win.el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        setFrame(win.el, r)
        return (true, fmt(win, screens()))
    }

    /// the inbox: "win-list:" / "win-move: x | y | w | h | title" (empty = keep) / "win-snap: title | action | display" / win-min|max|restore|top|bottom
    static func fromInbox(_ cmd: String, _ arg: String) -> (Bool, String) {
        let p = arg.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        func n(_ i: Int) -> Double? { i < p.count ? Double(p[i]) : nil }
        let title = { (i: Int) in i < p.count ? p[i] : "" }
        switch cmd {
        case "win-list:": return (true, list())
        case "win-move:": return move(title(4), n(0), n(1), n(2), n(3))
        case "win-snap:": return snap(title(0), title(1), p.count > 2 ? p[2] : nil)
        case "win-minimize:": return minimize(title(0))
        case "win-maximize:": return maximize(title(0))
        case "win-restore:": return restore(title(0))
        case "win-top:": return moveTop(title(0))
        case "win-bottom:": return moveBottom(title(0))
        default: return (false, "unknown " + cmd)
        }
    }
}

extension CGRect { var area: CGFloat { isNull || isEmpty ? 0 : width * height } }
