import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

// v19 (Marko, 9.11.2026: "take this free algorithm from Google ... the SDK to read the text on screen. Build it in a macro.
// It is OCR actually."): Google's ML Kit Text Recognition v2 is Android and iOS only. The free on-device equivalent on the
// Mac is Apple's Vision framework (VNRecognizeTextRequest, accurate): nothing to download, nothing leaves the Mac.
//   OcrText("window:Google Chrome")   FindText("Add", area)   ClickText "Add"   WaitText "Saved", 20     (Script.swift)
//   macro ocr [area] [--json]   macro find-text "<text>" [area]   macro wait-text "<text>" [secs] [area]   macro click-text ...
// area: "screen" (main display, default), "screen:2", "window:<app or title>", "rect:x,y,w,h" (global points).
// Every box is in global points, top-left origin, so a click lands on it. A window is read from its own pixels (also
// behind other windows or on another Space, ScreenCaptureKit), so its box is the window's own frame.
enum Ocr {
    static var languages: [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        let have = (try? req.supportedRecognitionLanguages()) ?? ["en-US"]
        // Croatian is not in Vision's list (macOS 15); Latin letters read well as English or German
        return ["en-US", "hr-HR", "de-DE"].filter { have.contains($0) }
    }

    /// the picture and the rectangle (global points) it shows
    static func shoot(_ spec: String) -> (CGImage, CGRect)? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        let low = s.lowercased()
        if low.hasPrefix("window:") {
            let q = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            guard let c = Capture.content(), let w = Capture.window(q, in: c) else { return nil }
            let f = SCContentFilter(desktopIndependentWindow: w)
            let sc = CGFloat(f.pointPixelScale)
            guard let img = Capture.shoot(f, width: Int(f.contentRect.width * sc), height: Int(f.contentRect.height * sc)) else { return nil }
            return (img, w.frame)
        }
        var rect = CGDisplayBounds(CGMainDisplayID())
        if low.hasPrefix("rect:") {
            let n = s.dropFirst(5).components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
            rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        } else if low.hasPrefix("screen:"), let i = Int(low.dropFirst(7).trimmingCharacters(in: .whitespaces)), i >= 1, i <= NSScreen.screens.count,
                  let id = NSScreen.screens[i - 1].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            rect = CGDisplayBounds(id)
        }
        guard let img = Eye.shot(rect) else { return nil }
        return (img, rect)
    }

    /// every line of text in the area, top to bottom, left to right
    static func read(_ spec: String) -> (lines: [OcrLine], error: String?) {
        guard let (img, rect) = shoot(spec) else {
            return ([], "no picture of \"\(spec.isEmpty ? "screen" : spec)\" (no such window, or Screen Recording permission?)")
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false            // web addresses and names must stay as they are
        req.recognitionLanguages = languages
        req.minimumTextHeight = 0
        do { try VNImageRequestHandler(cgImage: img, options: [:]).perform([req]) }
        catch { return ([], "Vision failed: \(error.localizedDescription)") }
        var out: [OcrLine] = []
        for o in req.results ?? [] {
            guard let c = o.topCandidates(1).first else { continue }
            let b = o.boundingBox                      // normalised, origin bottom left
            out.append(OcrLine(text: c.string, x: rect.minX + b.minX * rect.width, y: rect.minY + (1 - b.maxY) * rect.height,
                               w: b.width * rect.width, h: b.height * rect.height, conf: Double(c.confidence)))
        }
        // reading order: rows of about one text height, then left to right
        out.sort { a, b in abs(a.y - b.y) > min(a.h, b.h) * 0.6 ? a.y < b.y : a.x < b.x }
        return (out, nil)
    }

    static func json(_ lines: [OcrLine]) -> String {
        var a: [[String: Any]] = []
        for l in lines {
            var d: [String: Any] = [:]
            d["text"] = l.text
            d["x"] = Int(l.x.rounded()); d["y"] = Int(l.y.rounded())
            d["w"] = Int(l.w.rounded()); d["h"] = Int(l.h.rounded())
            d["cx"] = Int((l.x + l.w / 2).rounded()); d["cy"] = Int((l.y + l.h / 2).rounded())
            d["confidence"] = (l.conf * 100).rounded() / 100
            a.append(d)
        }
        let data = try? JSONSerialization.data(withJSONObject: a, options: [.prettyPrinted, .sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// inbox lines:  "ocr: <area> | json|text"   "find-text: <text> | <area>"   "click-text: <text> | <area>"
    ///               "wait-text: <text> | <seconds> | <area>"
    static func fromInbox(_ cmd: String, _ arg: String) -> (ok: Bool, message: String) {
        let p = arg.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        func p_(_ i: Int) -> String { i < p.count ? p[i] : "" }
        switch cmd {
        case "ocr:":
            let r = read(p_(0))
            if let e = r.error { return (false, e) }
            if p_(1) == "json" { return (true, json(r.lines)) }
            var rows: [String] = []
            for l in r.lines { rows.append("\(Int(l.x + l.w / 2)),\(Int(l.y + l.h / 2))\t" + l.text) }
            return (true, rows.joined(separator: "\n"))
        case "find-text:", "click-text:":
            let r = read(p_(1))
            if let e = r.error { return (false, e) }
            guard let m = ocrMatch(r.lines, p_(0)) else { return (false, "not on the screen: " + p_(0)) }
            let x = m.cx.rounded(), y = m.cy.rounded()
            if cmd == "click-text:" {
                CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
                for down in [true, false] {
                    CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
                    Thread.sleep(forTimeInterval: 0.05)
                }
                return (true, "clicked \(Int(x)),\(Int(y))  \(m.line.text)")
            }
            return (true, "\(Int(x)),\(Int(y))  \(m.line.text)")
        default: // wait-text
            let secs = Double(p_(1)) ?? 10
            let end = Date().addingTimeInterval(secs)
            while true {
                let r = read(p_(2))
                if let e = r.error, Date() >= end { return (false, e) }
                if let m = ocrMatch(r.lines, p_(0)) { return (true, "\(Int(m.cx.rounded())),\(Int(m.cy.rounded()))  \(m.line.text)") }
                if Date() >= end { return (false, "text did not appear in \(Int(secs)) s: " + p_(0)) }
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
    }
}
