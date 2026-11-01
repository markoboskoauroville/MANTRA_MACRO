// Recalibrate.swift (v8, 1.11.2026): RECALIBRATE. Marko, 1.11.2026: "If some actions were recorded for a certain
// piece of software, recalibrate should take a screenshot of that software, so that all mouse actions land in the
// same places, corrected. The screen resolution may have changed, or the user may have moved the window somewhere
// else on the screen ... by comparing the current view with the stored view, then recalculating the same actions for
// the new view."
//
// THE VIEW. When a recording stops, every window that was clicked in is stored with the macro: its app (name and
// bundle id), its title, its frame in screen points, the screen's scale, and a picture of the window taken when the
// pointer first came over it (before the click changed anything). ~/.mantra_macro/refs/<macro>/view.json + w0.png …
// (outside the macros folder, so a view is never listed as a macro). VIEW stores it again on demand: the windows under
// the macro's clicks, as they are now.
//
// RECALIBRATE. The app's window is found again and captured. For every literal x, y in the macro that lies inside
// the stored window: the places it may have gone (Coords.candidates: kept to an edge, the centre, or scaled) are each
// checked by looking: a patch of the stored picture around the point is matched in the new picture (normalised
// cross-correlation on grey at one pixel per point, so a 2× and a 1× screen compare). The first place that matches
// wins; if none does, the patch is searched in the whole window (found by picture). If it is not seen anywhere, a
// window that only moved still moves the point by the window's offset (that is exact); a resized one keeps the old
// point, and the report says so. The macro file is rewritten (the old one goes to the trash folder), and the new view
// is stored.
import AppKit
import Accelerate
import ScreenCaptureKit

let REF_DIR = DIR + "/refs"

struct RefWindow: Codable {
    var app: String
    var bundle: String
    var title: String
    var x, y, w, h: Double          // the frame, global points, top-left origin (what clicks use)
    var scale: Double                // pixels per point of the screen it was on
    var screenW, screenH: Double     // that screen, in points
    var image: String                // the picture's file in the view's folder
    var rect: Rect { Rect(x: x, y: y, w: w, h: h) }
    var label: String { "\(app) \(Int(w))×\(Int(h)) at \(Int(x)), \(Int(y))" }
}
struct RefFile: Codable {
    var version = 1
    var macro: String
    var made: String
    var windows: [RefWindow]
}

struct LiveWindow {
    var id: CGWindowID
    var pid: pid_t
    var app: String
    var title: String
    var frame: CGRect
    var bundle: String { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
    var rect: Rect { Rect(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height) }
}

// MARK: the stored views

enum Refs {
    static func dir(_ n: String) -> String { REF_DIR + "/" + n }
    static func load(_ n: String) -> RefFile? {
        guard let d = fm.contents(atPath: dir(n) + "/view.json") else { return nil }
        return try? JSONDecoder().decode(RefFile.self, from: d)
    }
    static func image(_ n: String, _ w: RefWindow) -> CGImage? { Eye.load(dir(n) + "/" + w.image) }
    static func now() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date()) }

    // a whole new view replaces the old one: written beside it, then swapped in
    @discardableResult static func save(_ n: String, _ wins: [(RefWindow, CGImage)]) -> Bool {
        mkdirs(REF_DIR)
        let tmp = REF_DIR + "/.tmp-" + UUID().uuidString
        mkdirs(tmp)
        var list: [RefWindow] = []
        for (i, (w, img)) in wins.enumerated() {
            var w = w; w.image = "w\(i).png"
            guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp + "/" + w.image) as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            guard CGImageDestinationFinalize(dest) else { continue }
            list.append(w)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(RefFile(macro: n, made: now(), windows: list)),
              (try? d.write(to: URL(fileURLWithPath: tmp + "/view.json"))) != nil else { try? fm.removeItem(atPath: tmp); return false }
        // the report of the last recalibration stays with the view
        if has(dir(n) + "/report.txt") { try? fm.copyItem(atPath: dir(n) + "/report.txt", toPath: tmp + "/report.txt") }
        try? fm.removeItem(atPath: dir(n))
        return (try? fm.moveItem(atPath: tmp, toPath: dir(n))) != nil
    }
    static func rename(_ old: String, _ new: String) {
        guard has(dir(old)) else { return }
        try? fm.removeItem(atPath: dir(new)); try? fm.moveItem(atPath: dir(old), toPath: dir(new))
    }
    static func trash(_ n: String) {
        guard has(dir(n)) else { return }
        mkdirs(TRASH_DIR)
        try? fm.moveItem(atPath: dir(n), toPath: TRASH_DIR + "/" + n + " " + Macros.stamp() + " (view)")
    }
    static func describe(_ n: String) -> String? {
        guard let r = load(n), !r.windows.isEmpty else { return nil }
        return "view: " + r.windows.map { $0.label }.joined(separator: " · ")
    }
}

// MARK: the windows on the screen

enum Windows {
    // the app windows on screen, front to back, not this app's own: normal ones, and the floating, modal and utility
    // levels (0 to 19) too, since a window kept on top (TOP in Marko's apps) sits at level 3. Not the Dock (20), the
    // menu bar (24, 25) or pop-up menus (101).
    static func all() -> [LiveWindow] {
        let me = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  let pid = (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }), pid != me,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  b.width > 40, b.height > 40,
                  let id = (w[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }) else { return nil }
            return LiveWindow(id: id, pid: pid, app: (w[kCGWindowOwnerName as String] as? String) ?? "",
                              title: (w[kCGWindowName as String] as? String) ?? "", frame: b)
        }
    }
    static func at(_ p: CGPoint) -> LiveWindow? { all().first { $0.frame.contains(p) } }

    // the stored window, now: the same app (bundle id, else its name); the same title if it has one, else its biggest
    static func find(_ r: RefWindow) -> LiveWindow? {
        let mine = all().filter { w in
            if !r.bundle.isEmpty { return w.bundle == r.bundle }
            return w.app == r.app
        }
        if !r.title.isEmpty, let w = mine.first(where: { $0.title == r.title }) { return w }
        return mine.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    // the screen a frame sits on: its size in points and its pixels per point
    static func screen(_ f: CGRect) -> (w: Double, h: Double, scale: Double) {
        let c = CGPoint(x: f.midX, y: f.midY)
        let d = Eye.displays().first { $0.frame.contains(c) } ?? Eye.displays().first
        guard let d = d else { return (0, 0, 2) }
        let s = CGDisplayCopyDisplayMode(d.id).map { Double($0.pixelWidth) / Double(d.frame.width) } ?? 2
        return (Double(d.frame.width), Double(d.frame.height), s)
    }

    // a picture of one window alone, even if another covers it (ScreenCaptureKit). Blocks: never on the main thread.
    static func capture(_ id: CGWindowID) -> CGImage? {
        let sem = DispatchSemaphore(value: 0)
        var out: CGImage?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let win = content?.windows.first(where: { $0.windowID == id }) else { sem.signal(); return }
            let f = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int(f.contentRect.width * CGFloat(f.pointPixelScale)))
            cfg.height = max(1, Int(f.contentRect.height * CGFloat(f.pointPixelScale)))
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg) { img, _ in out = img; sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    static func ref(_ w: LiveWindow) -> RefWindow {
        let s = screen(w.frame)
        return RefWindow(app: w.app, bundle: w.bundle, title: w.title, x: Double(w.frame.minX), y: Double(w.frame.minY),
                         w: Double(w.frame.width), h: Double(w.frame.height), scale: s.scale, screenW: s.w, screenH: s.h, image: "")
    }
}

// MARK: RECALIBRATE

enum Recal {
    static let ACCEPT: Float = 0.80        // a patch this alike is the same spot
    static let NEAR = 8                    // points searched around each candidate place

    struct Result { var ok: Bool; var summary: String; var report: String }

    // one picture as grey at k pixels per point of the window
    static func grey(_ img: CGImage, _ w: Double, _ h: Double, _ k: Double) -> Grey? {
        Grey(img, width: max(4, Int((w * k).rounded())), height: max(4, Int((h * k).rounded())))
    }
    static func stdev(_ g: Grey) -> Float {
        var m: Float = 0, s: Float = 0
        vDSP_normalize(g.px, 1, nil, 1, &m, &s, vDSP_Length(g.px.count))
        return s
    }
    // the patch of g around (cx, cy), clipped to the picture; off = where the point sits inside it
    static func patch(_ g: Grey, _ cx: Int, _ cy: Int, _ half: Int) -> (p: Grey, offX: Int, offY: Int)? {
        let x0 = max(0, cx - half), y0 = max(0, cy - half), x1 = min(g.w, cx + half), y1 = min(g.h, cy + half)
        guard x1 - x0 >= 8, y1 - y0 >= 8 else { return nil }
        var px = [Float](); px.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { px.append(contentsOf: g.px[(y * g.w + x0)..<(y * g.w + x1)]) }
        return (Grey(w: x1 - x0, h: y1 - y0, px: px), cx - x0, cy - y0)
    }
    // the best score of a patch near a place (top-left of the patch), and where
    static func near(_ g: Grey, _ p: Grey, _ tx: Int, _ ty: Int, _ r: Int) -> (Float, Int, Int) {
        var best: (Float, Int, Int) = (-1, tx, ty)
        for dy in -r...r { for dx in -r...r {
            let s = Eye.score(g, p, tx + dx, ty + dy)
            if s > best.0 || (s == best.0 && abs(dx) + abs(dy) < abs(best.1 - tx) + abs(best.2 - ty)) { best = (s, tx + dx, ty + dy) }
        } }
        return best
    }

    struct Fix { var x: Double; var y: Double; var how: String; var moved: Bool; var kept: Bool }

    // one point: old window o with its grey picture og, new window n with ng (both one pixel per point)
    static func fix(_ px: Double, _ py: Double, _ o: Rect, _ og: Grey, _ ogc: Grey, _ n: Rect, _ ng: Grey, _ ngc: Grey) -> Fix {
        let sameSize = abs(o.w - n.w) < 1 && abs(o.h - n.h) < 1
        let cands = Coords.candidates(px, py, old: o, new: n)
        // a patch with something in it: bigger until it is not one flat colour
        let lx = Int((px - o.x).rounded()), ly = Int((py - o.y).rounded())
        var pat: (p: Grey, offX: Int, offY: Int)?
        for half in [24, 40, 64] {
            if let t = patch(og, lx, ly, half), stdev(t.p) > 6 { pat = t; break }
        }
        let geometric = { (why: String) -> Fix in
            if sameSize, let c = cands.first {
                let moved = abs(c.x - px) >= 0.5 || abs(c.y - py) >= 0.5
                return Fix(x: c.x, y: c.y, how: c.label + ", " + why + " (the window only moved, so the offset is exact)", moved: moved, kept: false)
            }
            return Fix(x: px, y: py, how: "NOT FOUND, kept as it was: " + why + "; check this line", moved: false, kept: true)
        }
        guard let t = pat else { return geometric("a plain area with nothing to match") }
        // 1. the likely places, each looked at
        var bestC: (Float, Double, Double, String)? = nil
        for c in cands {
            let tx = Int((c.x - n.x).rounded()) - t.offX, ty = Int((c.y - n.y).rounded()) - t.offY
            let (s, bx, by) = near(ng, t.p, tx, ty, NEAR)
            let fx = n.x + Double(bx + t.offX), fy = n.y + Double(by + t.offY)
            if bestC == nil || s > bestC!.0 + 0.02 { bestC = (s, fx, fy, c.label) }
        }
        if let b = bestC, b.0 >= ACCEPT {
            let moved = abs(b.1 - px) >= 0.5 || abs(b.2 - py) >= 0.5
            // named after the likely place nearest to where it settled (a centred button refined from the scaled place
            // is "kept to the centre"), or unchanged
            let nearest = cands.min { hypot($0.x - b.1, $0.y - b.2) < hypot($1.x - b.1, $1.y - b.2) }
            let label = !moved ? "unchanged" : (nearest?.label ?? b.3)
            return Fix(x: b.1, y: b.2, how: String(format: "%@, seen %.0f%%", label, b.0 * 100), moved: moved, kept: false)
        }
        // 2. anywhere in the window, on a half-size copy, then verified at full size
        let cl = Int((Double(lx) / 2).rounded()), cy = Int((Double(ly) / 2).rounded())
        if let tc = patch(ogc, cl, cy, max(8, (t.p.w / 2) / 2 + 1)), let m = Eye.bestMatch(ngc, tc.p), m.0 >= ACCEPT - 0.1 {
            let gx = (m.1 + tc.offX) * 2 - t.offX, gy = (m.2 + tc.offY) * 2 - t.offY
            let (s, bx, by) = near(ng, t.p, gx, gy, 3)
            if s >= ACCEPT {
                let fx = n.x + Double(bx + t.offX), fy = n.y + Double(by + t.offY)
                let moved = abs(fx - px) >= 0.5 || abs(fy - py) >= 0.5
                return Fix(x: fx, y: fy, how: String(format: "found by picture (%@, %@), seen %.0f%%", Coords.sign(Int((fx - px).rounded())), Coords.sign(Int((fy - py).rounded())), s * 100), moved: moved, kept: false)
            }
        }
        return geometric(String(format: "not seen in the window now (best %.0f%%)", max(0, (bestC?.0 ?? 0)) * 100))
    }

    // does any stored window stand somewhere else now (or at another size)? Cheap: no picture taken.
    static func differs(_ name: String) -> Bool {
        guard let r = Refs.load(name) else { return false }
        for w in r.windows {
            guard let l = Windows.find(w) else { continue }
            if abs(Double(l.frame.minX) - w.x) > 0.5 || abs(Double(l.frame.minY) - w.y) > 0.5 ||
               abs(Double(l.frame.width) - w.w) > 0.5 || abs(Double(l.frame.height) - w.h) > 0.5 { return true }
        }
        return false
    }

    // RECALIBRATE "name": blocks (pictures are taken); call it off the main thread
    static func recalibrate(_ name: String) -> Result {
        guard let text = readText(Macros.ahk(name)) else { return Result(ok: false, summary: "no script called " + name, report: "") }
        guard let ref = Refs.load(name), !ref.windows.isEmpty else {
            return Result(ok: false, summary: name + " has no stored view: record it again, or press VIEW while its window is where the clicks fit", report: "")
        }
        let pts = Coords.points(text)
        var rep = ["RECALIBRATE \(name), \(Refs.now())"]
        // each stored window, found now and captured
        struct W { var ref: RefWindow; var live: LiveWindow?; var og, ogc, ng, ngc: Grey?; var img: CGImage? }
        var ws: [W] = []
        for r in ref.windows {
            var w = W(ref: r)
            w.live = Windows.find(r)
            if let l = w.live, let oi = Refs.image(name, r), let ni = Windows.capture(l.id) {
                w.img = ni
                w.og = grey(oi, r.w, r.h, 1); w.ogc = grey(oi, r.w, r.h, 0.5)
                w.ng = grey(ni, Double(l.frame.width), Double(l.frame.height), 1); w.ngc = grey(ni, Double(l.frame.width), Double(l.frame.height), 0.5)
                let s = Windows.screen(l.frame)
                rep.append("window \(r.app): was \(Int(r.w))×\(Int(r.h)) at \(Int(r.x)), \(Int(r.y)) (scale \(r.scale)×), now \(Int(l.frame.width))×\(Int(l.frame.height)) at \(Int(l.frame.minX)), \(Int(l.frame.minY)) (scale \(s.scale)×)")
            } else if w.live == nil {
                rep.append("window \(r.app) \"\(r.title)\": not on the screen now; its points are kept")
            } else {
                rep.append("window \(r.app): could not take its picture (Screen Recording allowed?); its points are kept")
            }
            ws.append(w)
        }
        var new: [String: (Double, Double)] = [:]
        var moved = 0, kept = 0, same = 0, outside = 0
        for c in pts {
            // the window it was in: the smallest stored frame holding it (a dialog before its main window)
            let idx = ws.indices.filter { ws[$0].ref.rect.contains(c.x, c.y) }.min { ws[$0].ref.rect.area < ws[$1].ref.rect.area }
            let head = "line \(c.line)  \(c.command) \(Coords.fmt(c.x)), \(Coords.fmt(c.y))"
            guard let i = idx else { outside += 1; rep.append(head + "  outside the stored windows, kept"); continue }
            let w = ws[i]
            guard let l = w.live, let og = w.og, let ogc = w.ogc, let ng = w.ng, let ngc = w.ngc else {
                kept += 1; rep.append(head + "  window not found now, kept"); continue
            }
            let f = fix(c.x, c.y, w.ref.rect, og, ogc, l.rect, ng, ngc)
            if f.kept { kept += 1 } else if f.moved { moved += 1 } else { same += 1 }
            if f.moved { new[Coords.key(c)] = (f.x, f.y) }
            rep.append(head + (f.moved ? "  → \(Coords.fmt(f.x)), \(Coords.fmt(f.y))" : "") + "  " + f.how)
        }
        let summary = "\(name): \(moved) moved, \(same) where they were, \(kept) not found (kept)" + (outside > 0 ? ", \(outside) outside the window" : "")
        rep.append(summary)
        if !new.isEmpty {
            var out = Coords.rewrite(text, new)
            let d = DateFormatter(); d.dateFormat = "d.M.yyyy HH:mm"
            out = Coords.stamp(out, "\(d.string(from: Date())): \(moved) moved, \(kept) not found (kept), the version before is in the trash folder")
            mkdirs(TRASH_DIR)
            _ = writeText(TRASH_DIR + "/" + name + " " + Macros.stamp() + " (before recalibrate).ahk", text)
            guard writeText(Macros.ahk(name), out) else { return Result(ok: false, summary: "could not write " + name, report: rep.joined(separator: "\n")) }
        }
        // the new view: the windows as they are now; a window not found keeps its old view
        var keep: [(RefWindow, CGImage)] = []
        for w in ws {
            if let l = w.live, let img = w.img { keep.append((Windows.ref(l), img)) }
            else if let img = Refs.image(name, w.ref) { keep.append((w.ref, img)) }
        }
        _ = writeText(Refs.dir(name) + "/report.txt", rep.joined(separator: "\n") + "\n")
        Refs.save(name, keep)
        return Result(ok: true, summary: summary, report: rep.joined(separator: "\n"))
    }

    // VIEW: store the view now, the windows under the macro's clicks as they stand (the macro fits the screen now).
    // app: only that app's windows (a name or bundle id), else whatever window is under each point.
    static func reference(_ name: String, app: String? = nil) -> Result {
        guard let text = readText(Macros.ahk(name)) else { return Result(ok: false, summary: "no script called " + name, report: "") }
        let all = Windows.all()
        let a = app?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let pool = a.isEmpty ? all : all.filter { $0.app.lowercased().contains(a) || $0.bundle.lowercased() == a }
        var used: [CGWindowID] = [], rep: [String] = []
        for c in Coords.points(text) {
            guard let w = pool.first(where: { $0.frame.contains(CGPoint(x: c.x, y: c.y)) }) else { continue }
            if !used.contains(w.id) { used.append(w.id) }
        }
        if used.isEmpty, !a.isEmpty, let w = pool.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) { used = [w.id] }
        guard !used.isEmpty else { return Result(ok: false, summary: "no window under the clicks of \(name)" + (a.isEmpty ? "" : " belongs to " + app!), report: "") }
        var keep: [(RefWindow, CGImage)] = []
        for id in used {
            guard let w = all.first(where: { $0.id == id }) else { continue }
            guard let img = Windows.capture(id) else { rep.append("could not take the picture of \(w.app) (Screen Recording allowed?)"); continue }
            keep.append((Windows.ref(w), img))
        }
        guard !keep.isEmpty, Refs.save(name, keep) else { return Result(ok: false, summary: "could not store the view of " + name, report: rep.joined(separator: "\n")) }
        let s = "\(name): view stored, " + keep.map { $0.0.label }.joined(separator: " · ")
        return Result(ok: true, summary: s, report: (rep + [s]).joined(separator: "\n"))
    }
}

// MARK: the view taken while recording

// The pointer's window is looked at as it moves (a few times a second); the first time a window is under the pointer
// its picture is taken, before any click in it. Each click counts for its window. When the recording stops, the
// windows that were clicked in are the macro's view.
final class RecordingView {
    struct Seen { var live: LiveWindow; var ref: RefWindow; var img: CGImage?; var clicks = 0 }
    private var seen: [CGWindowID: Seen] = [:]
    private var order: [CGWindowID] = []
    private var lastLook = 0.0
    private let q = DispatchQueue(label: "macro.recordingview")
    private let group = DispatchGroup()

    func reset() { q.sync { seen = [:]; order = [] }; lastLook = 0 }

    // from the event tap, on the main thread
    func pointer(_ p: CGPoint, click: Bool) {
        let t = Date().timeIntervalSince1970
        if !click && t - lastLook < 0.15 { return }
        lastLook = t
        guard let w = Windows.at(p) else { return }
        var isNew = false
        q.sync {
            if seen[w.id] == nil { seen[w.id] = Seen(live: w, ref: Windows.ref(w)); order.append(w.id); isNew = true }
            if click { seen[w.id]!.clicks += 1 }
        }
        guard isNew else { return }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Windows.capture(w.id)
            self.q.sync { self.seen[w.id]?.img = img }
            self.group.leave()
        }
    }

    // when the recording is saved under a name: wait for the pictures still being taken, then store the view
    func store(_ name: String, done: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            _ = self.group.wait(timeout: .now() + 4)
            let wins: [(RefWindow, CGImage)] = self.q.sync {
                self.order.compactMap { id in
                    guard let s = self.seen[id], s.clicks > 0, let img = s.img else { return nil }
                    return (s.ref, img)
                }
            }
            guard !wins.isEmpty else { return DispatchQueue.main.async { done(nil) } }
            let ok = Refs.save(name, wins)
            DispatchQueue.main.async { done(ok ? wins.map { $0.0.label }.joined(separator: " · ") : nil) }
        }
    }
}
