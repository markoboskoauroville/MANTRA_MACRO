import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// v11 (Marko, 2.11.2026: "you need to build in my macro recorder screen capture algorithm, which can capture the whole
// page. If something is cut off, it needs to scroll down and stitch the image"): the whole page as one picture.
// A rectangle of the screen (the part that scrolls: a page, a chat) is shot, scrolled by about two thirds of its height,
// shot again, and each new shot is laid on the last by the rows they share, until the scroll stops moving. "up" goes the
// other way, for a chat whose older messages are above. The pointer is put over the rectangle (scrolling goes to what is
// under it) and brought back where it was afterwards.
//   Script:  CapturePage "file.png", x, y, w, h [, "down"|"up" [, most shots]]   -> the picture's height in pixels
//   Inbox:   "capture-page: x, y, w, h | down | /path/file.png [| most shots]"   (also "front" for the front window)
enum PageCapture {
    static let EDGE = 4
    struct Result { let ok: Bool; let message: String }

    /// rows as small grey signatures, to find where two shots overlap
    private static func signature(_ img: CGImage, cols: Int = 96) -> [[Float]] {
        let w = cols, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // a bitmap context's memory starts with the picture's top row: the rows are already top-down
        return (0..<h).map { row in (0..<w).map { Float(buf[row * w + $0]) } }
    }

    private static func rowDiff(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0; for i in 0..<a.count { s += abs(a[i] - b[i]) }; return s / Float(a.count)
    }

    /// how many rows the content moved from `prev` to `next` (scrolling down: next shows content further down).
    /// Returns nil when nothing moved. `skipTop` rows (a floating date chip, a sticky header) are not compared.
    private static func shift(_ prev: [[Float]], _ next: [[Float]], skipTop: Int, expected: Int) -> Int? {
        let h = prev.count
        if zip(prev, next).allSatisfy({ rowDiff($0, $1) < 0.5 }) { return nil }
        var best = (cost: Float.greatestFiniteMagnitude, d: 0)
        let minOverlap = max(40, h / 8)
        // the content moved at most a little more than the scroll asked (the end of a page moves less)
        for d in 1...min(h - minOverlap, Int(Double(expected) * 1.25) + 4) {
            var cost: Float = 0, n = 0
            var r = skipTop
            while r + d < h { cost += rowDiff(prev[r + d], next[r]); n += 1; r += 3 }
            guard n > 8 else { continue }
            let c = cost / Float(n)
            if c < best.cost { best = (c, d) }
        }
        return best.cost < 6 ? best.d : nil
    }

    private static func crop(_ img: CGImage, top: Int, rows: Int) -> CGImage? {
        img.cropping(to: CGRect(x: 0, y: top, width: img.width, height: rows))
    }

    private static func scroll(at p: CGPoint, pixels: Int32) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) {
            ev.location = p; ev.post(tap: .cghidEventTap)
        }
    }

    /// the front app's front window, in global points
    static func frontWindow() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
                return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            }
        }
        return nil
    }

    /// Runs off the main thread (Eye.shot blocks).
    static func capture(_ rect: CGRect, up: Bool, out: String, most: Int = 400, maxHeight: Int = 120_000) -> Result {
        guard let first = Eye.shot(rect) else { return Result(ok: false, message: "no picture of the screen (Screen Recording permission?)") }
        let scale = Double(first.height) / Double(rect.height)
        let mouseBack = CGEvent(source: nil)?.location
        let at = CGPoint(x: rect.midX, y: rect.midY)
        CGWarpMouseCursorPosition(at)
        defer { if let m = mouseBack { CGWarpMouseCursorPosition(m) } }
        Thread.sleep(forTimeInterval: 0.15)

        var pieces: [CGImage] = [first]        // in reading order, top to bottom
        var last = first, lastSig = signature(first)
        let step = Int32(rect.height * 0.66) * (up ? 1 : -1)
        let skip = Int(Double(first.height) * 0.06)
        var total = first.height, shots = 1, still = 0, note = ""
        while shots < most {
            scroll(at: at, pixels: step)
            Thread.sleep(forTimeInterval: up ? 0.9 : 0.3)   // a chat loads older messages as it goes up
            // smooth scrolling: shoot until two shots in a row are the same, so the picture stands still
            guard var img = Eye.shot(rect) else { break }
            var sig = signature(img)
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.15)
                guard let again = Eye.shot(rect) else { break }
                let s2 = signature(again)
                let same = zip(sig, s2).allSatisfy { rowDiff($0, $1) < 0.5 }
                img = again; sig = s2
                if same { break }
            }
            // scrolling down: new content enters at the bottom; up: at the top (compare the other way round)
            let expected = Int(Double(abs(step)) * scale)
            let d = up ? shift(sig, lastSig, skipTop: skip, expected: expected) : shift(lastSig, sig, skipTop: 0, expected: expected)
            guard let moved = d else {
                still += 1
                if still >= (up ? 3 : 2) { break }        // the end: nothing moves any more (a chat may still be loading)
                continue
            }
            still = 0; shots += 1
            // each piece takes EDGE rows more than it adds, laid over the last one, so the shots' own edge lines
            // (a pane's hairline, a shadow) never show at the joins
            let e = min(EDGE, img.height - moved)
            if up {
                if let top = crop(img, top: 0, rows: moved + e) { pieces.insert(top, at: 0) }
            } else {
                if let bottom = crop(img, top: img.height - moved - e, rows: moved + e) { pieces.append(bottom) }
            }
            total += moved; last = img; lastSig = sig
            if total >= maxHeight { note = " (stopped at \(maxHeight) pixels)"; break }
        }
        _ = last
        guard let ctx = CGContext(data: nil, width: first.width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Result(ok: false, message: "the picture is too large to make (\(total) pixels high)") }
        // laid from the first shot on, each new piece over the EDGE rows of the one before (CG's y runs upward)
        if up {
            var y = 0                                   // pieces[last] is the first shot, at the bottom
            for p in pieces.reversed() { ctx.draw(p, in: CGRect(x: 0, y: y, width: p.width, height: p.height)); y += p.height - EDGE }
        } else {
            var top = 0                                  // distance from the picture's top
            for (i, p) in pieces.enumerated() {
                if i > 0 { top -= EDGE }
                ctx.draw(p, in: CGRect(x: 0, y: total - top - p.height, width: p.width, height: p.height)); top += p.height
            }
        }
        guard let whole = ctx.makeImage() else { return Result(ok: false, message: "could not join the pieces") }
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        let type = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? UTType.jpeg : UTType.png
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return Result(ok: false, message: "cannot write " + url.path)
        }
        CGImageDestinationAddImage(dest, whole, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return Result(ok: false, message: "cannot write " + url.path) }
        return Result(ok: true, message: "\(url.path): \(first.width)×\(total) pixels from \(shots) shots\(note)")
    }

    /// "x, y, w, h | down | path [| most]" or "front | down | path"
    static func fromInbox(_ arg: String) -> Result {
        let p = arg.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count >= 3 else { return Result(ok: false, message: "capture-page: x, y, w, h | down | /path/file.png") }
        let rect: CGRect
        if p[0].lowercased() == "front" {
            guard let r = frontWindow() else { return Result(ok: false, message: "no front window") }
            rect = r
        } else {
            let n = p[0].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 4 else { return Result(ok: false, message: "the rectangle is x, y, w, h") }
            rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
        let most = p.count > 3 ? Int(p[3]) ?? 400 : 400
        return capture(rect, up: p[1].lowercased() == "up", out: p[2], most: most)
    }
}
