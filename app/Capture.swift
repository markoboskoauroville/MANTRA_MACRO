import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// v13 (Marko, 3.11.2026: "For any capturing work, screen capturing ... macro recorder, which can grab or press and do many
// things, and use it for your work", "If some features are missing, you need them. Please code them inside that app."):
// every capture a session needs, from here.
//   capture-window "<app or title part>" [file]   the window's own pixels: also on another Space or behind other windows,
//                                                  nothing brought to the front, no focus taken (ScreenCaptureKit,
//                                                  desktop-independent window; `screencapture -l` gave a blank white
//                                                  picture of DaVinci Resolve on another Space, 3.11.2026)
//   capture-screen <display name part | index from 1> [file]   one whole display
//   capture-rect "x, y, w, h" [file]               a rectangle in global points (top-left origin), at the screen's pixels
// Default folder ~/.mantra_macro/captures/. The answer is the saved path with the picture's size; a picture that is one
// flat colour is reported as blank (ok false), so a caller never mistakes an empty frame for a capture.
enum Capture {
    struct Result { let ok: Bool; let message: String }

    static var folder: String {
        let f = NSHomeDirectory() + "/.mantra_macro/captures"
        try? FileManager.default.createDirectory(atPath: f, withIntermediateDirectories: true)
        return f
    }

    static func path(_ given: String?, _ stem: String) -> String {
        if let g = given, !g.isEmpty { return (g as NSString).expandingTildeInPath }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safe = stem.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        return folder + "/" + safe + "_" + df.string(from: Date()) + ".png"
    }

    static func write(_ img: CGImage, _ p: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let type: UTType = p.lowercased().hasSuffix(".jpg") || p.lowercased().hasSuffix(".jpeg") ? .jpeg : .png
        guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, nil)
        return CGImageDestinationFinalize(d)
    }

    /// one flat colour (a window not drawn, an empty frame): every sampled pixel within a few levels of the first
    static func blank(_ img: CGImage) -> Bool {
        let w = 64, h = 64
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lo = [Int](repeating: 255, count: 3), hi = [Int](repeating: 0, count: 3)
        for i in stride(from: 0, to: buf.count, by: 4) {
            for c in 0..<3 { lo[c] = min(lo[c], Int(buf[i + c])); hi[c] = max(hi[c], Int(buf[i + c])) }
        }
        return (0..<3).allSatisfy { hi[$0] - lo[$0] < 6 }
    }

    static func done(_ img: CGImage?, _ p: String, _ what: String) -> Result {
        guard let img = img else { return Result(ok: false, message: "no picture of " + what + " (Screen Recording permission?)") }
        if blank(img) { return Result(ok: false, message: "the picture of \(what) is one flat colour (blank), not saved") }
        guard write(img, p) else { return Result(ok: false, message: "could not write " + p) }
        return Result(ok: true, message: "\(p)  (\(img.width)x\(img.height), \(what))")
    }

    static func content() -> SCShareableContent? {
        let sem = DispatchSemaphore(value: 0)
        var out: SCShareableContent?
        // every window, also those on other Spaces and behind others
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { c, _ in out = c; sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    /// the window: app name or window title containing `q` (case-insensitive), normal layer, the biggest; on screen first
    static func window(_ q: String, in c: SCShareableContent) -> SCWindow? {
        let k = q.lowercased()
        let hits = c.windows.filter { w in
            w.windowLayer == 0 && w.frame.width >= 100 && w.frame.height >= 100 &&
            ((w.owningApplication?.applicationName.lowercased().contains(k) ?? false) || (w.title?.lowercased().contains(k) ?? false))
        }
        let exact = hits.filter { $0.owningApplication?.applicationName.lowercased() == k }
        let pool = exact.isEmpty ? hits : exact
        return pool.max { a, b in
            (a.isOnScreen ? 1 : 0, a.frame.width * a.frame.height) < (b.isOnScreen ? 1 : 0, b.frame.width * b.frame.height)
        }
    }

    static func shoot(_ f: SCContentFilter, width: Int, height: Int, source: CGRect? = nil) -> CGImage? {
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, width); cfg.height = max(1, height)
        if let s = source { cfg.sourceRect = s }
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        let sem = DispatchSemaphore(value: 0)
        var out: CGImage?
        SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg) { img, _ in out = img; sem.signal() }
        _ = sem.wait(timeout: .now() + 8)
        return out
    }

    static func captureWindow(_ q: String, _ file: String?) -> Result {
        guard let c = content() else { return Result(ok: false, message: "no answer from ScreenCaptureKit (Screen Recording permission?)") }
        guard let w = window(q, in: c) else { return Result(ok: false, message: "no window of \"\(q)\"") }
        let f = SCContentFilter(desktopIndependentWindow: w)
        let s = CGFloat(f.pointPixelScale)
        let img = shoot(f, width: Int(f.contentRect.width * s), height: Int(f.contentRect.height * s))
        let name = (w.owningApplication?.applicationName ?? q) + ((w.title ?? "").isEmpty ? "" : " - " + (w.title ?? ""))
        return done(img, path(file, w.owningApplication?.applicationName ?? q),
                    "window \"\(name)\"" + (w.isOnScreen ? "" : ", not on screen"))
    }

    static func captureScreen(_ which: String, _ file: String?) -> Result {
        guard let c = content() else { return Result(ok: false, message: "no answer from ScreenCaptureKit (Screen Recording permission?)") }
        let screens = NSScreen.screens
        var pick: NSScreen?
        if let n = Int(which.trimmingCharacters(in: .whitespaces)), n >= 1, n <= screens.count { pick = screens[n - 1] }
        else if which.trimmingCharacters(in: .whitespaces).isEmpty { pick = NSScreen.main }
        else { pick = screens.first { $0.localizedName.lowercased().contains(which.lowercased()) } }
        guard let sc = pick, let id = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let d = c.displays.first(where: { $0.displayID == id }) else {
            return Result(ok: false, message: "no display \"\(which)\" (" + screens.enumerated().map { "\($0.offset + 1) \($0.element.localizedName)" }.joined(separator: ", ") + ")")
        }
        let s = sc.backingScaleFactor
        let img = shoot(SCContentFilter(display: d, excludingWindows: []), width: Int(CGFloat(d.width) * s), height: Int(CGFloat(d.height) * s))
        return done(img, path(file, "screen_" + sc.localizedName), "display \"\(sc.localizedName)\"")
    }

    static func captureRect(_ r: CGRect, _ file: String?) -> Result {
        done(Eye.shot(r), path(file, "rect_\(Int(r.minX))_\(Int(r.minY))"), "rectangle \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))")
    }

    /// inbox lines: "capture-window: <q> | <file>", "capture-screen: <which> | <file>", "capture-rect: x, y, w, h | <file>"
    static func fromInbox(_ cmd: String, _ arg: String) -> Result {
        let parts = arg.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        let file = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        switch cmd {
        case "capture-window:":
            return parts[0].isEmpty ? Result(ok: false, message: "capture-window: <app or title> [| file]") : captureWindow(parts[0], file)
        case "capture-screen:":
            return captureScreen(parts[0], file)
        default:
            let n = parts[0].components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 4, n[2] > 0, n[3] > 0 else { return Result(ok: false, message: "capture-rect: x, y, w, h [| file]") }
            return captureRect(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), file)
        }
    }
}
