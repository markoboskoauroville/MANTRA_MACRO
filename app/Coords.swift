// Coords.swift (v8, 1.11.2026): the mouse coordinates written in a macro, read out and written back, and the places a
// point may have gone when its window moved or changed size. Foundation only, so tests/RecalTests.swift checks it
// without the app. RECALIBRATE (Recalibrate.swift) decides which place is right by looking at the window.
//
// Marko, 1.11.2026: "If some actions were recorded for a certain piece of software, recalibrate should take a
// screenshot of that software, so that all mouse actions land in the same places, corrected."
import Foundation

struct CoordRef: Equatable {
    var line: Int          // 1-based line of the script
    var pair: Int          // which x, y pair on that line: 0, or 1 for the end of a MouseClickDrag
    var x: Double
    var y: Double
    var command: String    // Click, MouseMove, MouseClick, MouseClickDrag
}

struct Rect: Equatable {
    var x, y, w, h: Double
    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && py >= y && px < x + w && py < y + h }
    var area: Double { w * h }
}

enum Coords {
    static let NUM = "(-?\\d+(?:\\.\\d+)?)"
    static let OPEN = "(?:\\s*\\(\\s*|\\s+)"         // command style "Click 1, 2" or function style "Click(1, 2)"
    static let SEP = "\\s*,\\s*"
    static let ARG = "(?:\"[^\"]*\"|'[^']*'|[A-Za-z0-9_]+)"
    // each pattern: the command, and the capture groups of x, y (and x2, y2) in order
    static let PATTERNS: [(String, NSRegularExpression)] = [
        ("MouseClickDrag", try! NSRegularExpression(pattern: "^\\s*(MouseClickDrag)" + OPEN + ARG + SEP + NUM + SEP + NUM + SEP + NUM + SEP + NUM, options: [.caseInsensitive])),
        ("MouseClick", try! NSRegularExpression(pattern: "^\\s*(MouseClick)" + OPEN + ARG + SEP + NUM + SEP + NUM, options: [.caseInsensitive])),
        ("Click", try! NSRegularExpression(pattern: "^\\s*(Click)" + OPEN + NUM + SEP + NUM, options: [.caseInsensitive])),
        ("MouseMove", try! NSRegularExpression(pattern: "^\\s*(MouseMove)" + OPEN + NUM + SEP + NUM, options: [.caseInsensitive])),
    ]

    // every literal x, y the script clicks or moves to. A coordinate held in a variable or an expression is left out:
    // it is the script's own business (e.g. relative to WinGetPos already).
    static func points(_ text: String) -> [CoordRef] {
        var out: [CoordRef] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            for (cmd, m) in matches(line) {
                let ns = line as NSString
                let n = (m.numberOfRanges - 2) / 2
                for p in 0..<n {
                    guard let x = Double(ns.substring(with: m.range(at: 2 + p * 2))),
                          let y = Double(ns.substring(with: m.range(at: 3 + p * 2))) else { continue }
                    out.append(CoordRef(line: i + 1, pair: p, x: x, y: y, command: cmd))
                }
            }
        }
        return out
    }
    private static func matches(_ line: String) -> [(String, NSTextCheckingResult)] {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(";") || t.hasPrefix("//") { return [] }
        let r = NSRange(location: 0, length: (line as NSString).length)
        for (cmd, re) in PATTERNS { if let m = re.firstMatch(in: line, range: r) { return [(cmd, m)] } }
        return []
    }

    // the same text with some points replaced; everything else on the line, and every other line, as it was
    static func rewrite(_ text: String, _ new: [String: (Double, Double)]) -> String {
        var lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            guard let (_, m) = matches(line).first else { continue }
            let n = (m.numberOfRanges - 2) / 2
            var s = line as NSString
            // from the last number to the first, so the earlier ranges stay where they are
            for p in stride(from: n - 1, through: 0, by: -1) {
                guard let v = new["\(i + 1):\(p)"] else { continue }
                s = s.replacingCharacters(in: m.range(at: 3 + p * 2), with: fmt(v.1)) as NSString
                s = s.replacingCharacters(in: m.range(at: 2 + p * 2), with: fmt(v.0)) as NSString
            }
            lines[i] = s as String
        }
        return lines.joined(separator: "\n")
    }
    static func key(_ c: CoordRef) -> String { "\(c.line):\(c.pair)" }
    static func fmt(_ v: Double) -> String { String(Int((v).rounded())) }

    // the places a point inside the old window may have gone in the new one, the likeliest first. On each axis the
    // point keeps its distance to the left (top) edge, to the right (bottom) edge, to the centre, or its proportion.
    // A window that only moved gives one place; a resized one up to sixteen.
    static func candidates(_ px: Double, _ py: Double, old o: Rect, new n: Rect) -> [(label: String, x: Double, y: Double)] {
        let rx = px - o.x, ry = py - o.y
        let xs: [(String, Double)] = [("left", n.x + rx), ("right", n.x + n.w - (o.w - rx)),
                                      ("scaled", n.x + rx * n.w / max(1, o.w)), ("centre", n.x + n.w / 2 + (rx - o.w / 2))]
        let ys: [(String, Double)] = [("top", n.y + ry), ("bottom", n.y + n.h - (o.h - ry)),
                                      ("scaled", n.y + ry * n.h / max(1, o.h)), ("centre", n.y + n.h / 2 + (ry - o.h / 2))]
        var out: [(String, Double, Double)] = []
        for (lx, x) in xs { for (ly, y) in ys {
            if out.contains(where: { abs($0.1 - x) < 1.5 && abs($0.2 - y) < 1.5 }) { continue }
            out.append((describe(lx, ly, px, py, x, y, o, n), x, y))
        } }
        return out
    }
    static func describe(_ lx: String, _ ly: String, _ px: Double, _ py: Double, _ x: Double, _ y: Double, _ o: Rect, _ n: Rect) -> String {
        let dx = Int((x - px).rounded()), dy = Int((y - py).rounded())
        if dx == 0 && dy == 0 { return "unchanged" }
        let sameSize = abs(o.w - n.w) < 1 && abs(o.h - n.h) < 1
        if sameSize || (lx == "left" && ly == "top") { return "moved by offset (\(sign(dx)), \(sign(dy)))" }
        if lx == "scaled" && ly == "scaled" { return String(format: "scaled (×%.2f, ×%.2f)", n.w / o.w, n.h / o.h) }
        return "kept to the \(lx == "left" ? "left edge" : lx == "right" ? "right edge" : lx == "centre" ? "centre" : "proportion") across, "
             + "\(ly == "top" ? "top edge" : ly == "bottom" ? "bottom edge" : ly == "centre" ? "centre" : "proportion") down (\(sign(dx)), \(sign(dy)))"
    }
    static func sign(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }

    // the one comment line that says when and how the macro was recalibrated: replaced, never piled up. It goes after
    // the first comment line (which carries "recorded …", read by the window), or on top when there is none.
    static func stamp(_ text: String, _ note: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { $0.hasPrefix("; recalibrated ") }
        let at = (lines.first?.hasPrefix(";") ?? false) ? 1 : 0
        lines.insert("; recalibrated " + note, at: at)
        return lines.joined(separator: "\n")
    }
}
