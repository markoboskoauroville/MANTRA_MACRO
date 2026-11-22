// BlobRules.swift: the pure rules of the text blob (v32, 22.11.2026). No windows here, so tests/BlobTests.swift compiles this
// file alone on GitHub: how long a blob stays, how its text wraps and is cut, the stack (newest on top, at most three,
// replace or clear by id), when "You can use the computer now" may show, and where a blob sits on a screen layout.
// Marko, 22.11.2026: "a text blob ... if something needs to be said to me while I'm working on computer and you are working
// in the background."
import Foundation
import CoreGraphics

enum BlobKind: String { case info, done, ask }

struct BlobItem: Equatable {
    var id: String
    var text: String
    var kind: BlobKind
    var sticky: Bool
    var seconds: Double?          // nil = sticky (stays until he clicks it)
    var shownAt: Date
}

enum BlobRules {
    static let maxStack = 3, maxLines = 3
    static let minSeconds = 6.0, maxSeconds = 30.0
    static let doneText = "You can use the computer now"
    static let doneID = "lock-done"

    /// Plain text only: control characters and line breaks become single spaces, nothing is rendered as markup.
    static func clean(_ s: String) -> String {
        var spaced = ""
        for u in s.unicodeScalars { spaced.unicodeScalars.append(CharacterSet.controlCharacters.contains(u) || CharacterSet.newlines.contains(u) ? " " : u) }
        return spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// How long a blob stays: sticky never leaves by itself (nil); an explicit --seconds counts as given (1 to 120);
    /// else long enough to read, 6 s at least, 30 s at most, 4 s plus 0.07 s per character in between.
    static func duration(text: String, seconds: Double?, sticky: Bool) -> Double? {
        if sticky { return nil }
        if let s = seconds { return min(120, max(1, s)) }
        return min(maxSeconds, max(minSeconds, 4 + Double(text.count) * 0.07))
    }

    /// Greedy word wrap to `width` by `measure`, at most `maxLines` lines. A word wider than a line is broken by characters.
    /// More text than fits: the last line ends with an ellipsis that still fits, and `truncated` is true.
    static func wrap(_ text: String, width: CGFloat, maxLines: Int = BlobRules.maxLines, measure: (String) -> CGFloat) -> (lines: [String], truncated: Bool) {
        var lines: [String] = []
        var cur = ""
        func push() { if !cur.isEmpty { lines.append(cur); cur = "" } }
        for w in text.split(separator: " ").map(String.init) {
            var word = w
            while measure(word) > width && word.count > 1 {         // a word wider than the line: break it
                if !cur.isEmpty { push() }
                var n = word.count
                while n > 1 && measure(String(word.prefix(n))) > width { n -= 1 }
                lines.append(String(word.prefix(n)))
                word = String(word.dropFirst(n))
            }
            let trial = cur.isEmpty ? word : cur + " " + word
            if measure(trial) <= width || cur.isEmpty { cur = trial } else { push(); cur = word }
        }
        push()
        if lines.count <= maxLines { return (lines, false) }
        var out = Array(lines.prefix(maxLines))
        var last = out[maxLines - 1]
        while !last.isEmpty && measure(last + "…") > width { last.removeLast() }
        out[maxLines - 1] = last.trimmingCharacters(in: .whitespaces) + "…"
        return (out, true)
    }

    /// Placement of the blobs of a stack on one screen's visible frame (AppKit coordinates, origin bottom left): top centre
    /// under the menu bar, the newest (index 0) on top, the others below it. Never wider than the screen less its margins.
    static func frames(visible: CGRect, sizes: [CGSize], margin: CGFloat = 12, gap: CGFloat = 8) -> [CGRect] {
        var out: [CGRect] = []
        var top = visible.maxY - margin
        for s in sizes {
            let w = min(s.width, max(40, visible.width - 2 * margin))
            let x = max(visible.minX + margin, (visible.midX - w / 2).rounded())
            out.append(CGRect(x: x, y: top - s.height, width: w, height: s.height))
            top -= s.height + gap
        }
        return out
    }

    /// AX rectangle (origin top-left of the primary screen) to an AppKit rectangle (origin bottom-left of the primary screen).
    /// Copied from FocusScreen.swift of MANTRA_VOICE_TO_TEXT (v65): same rule, which screen he is working on.
    static func appKitRect(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    /// the index of the screen holding the rectangle's centre, else the one with the biggest overlap
    static func screenIndex(of r: CGRect, frames: [CGRect]) -> Int? {
        let c = CGPoint(x: r.midX, y: r.midY)
        if let i = frames.firstIndex(where: { $0.contains(c) }) { return i }
        var best: (Int, CGFloat)?
        for (i, f) in frames.enumerated() {
            let x = f.intersection(r)
            let a = x.isNull ? 0 : x.width * x.height
            if a > 0, a > (best?.1 ?? 0) { best = (i, a) }
        }
        return best?.0
    }
}

/// The blobs on screen: newest first (index 0 = on top), at most three; older ones leave first.
struct BlobStack {
    private(set) var items: [BlobItem] = []
    enum Event: Equatable { case added(String), replaced(String), evicted(String) }

    /// Show an item. Same id: replaced in place (its time starts again). A fourth blob pushes the oldest out.
    mutating func show(_ it: BlobItem) -> [Event] {
        if let i = items.firstIndex(where: { $0.id == it.id }) { items[i] = it; return [.replaced(it.id)] }
        items.insert(it, at: 0)
        var ev: [Event] = [.added(it.id)]
        while items.count > BlobRules.maxStack { ev.append(.evicted(items.removeLast().id)) }
        return ev
    }
    mutating func clear(_ id: String) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: i); return true
    }
    mutating func clearAll() -> [String] { let ids = items.map { $0.id }; items = []; return ids }
    /// Non-sticky blobs whose time is over leave; returns their ids.
    mutating func expire(now: Date) -> [String] {
        var ids: [String] = []
        items.removeAll { it in
            guard !it.sticky, let s = it.seconds, now.timeIntervalSince(it.shownAt) >= s else { return false }
            ids.append(it.id); return true
        }
        return ids
    }
}

/// "You can use the computer now" only when the lock is released and no other lock follows within `window` seconds
/// (workers take the lock several times in a row), and only when the whole busy stretch lasted `minBusy` seconds or more
/// (a click that took half a second is not worth a notice).
struct DoneGate {
    var window = 2.0, minBusy = 2.0
    private var busySince: Date?
    private var releasedAt: Date?
    var pending: Bool { releasedAt != nil }
    mutating func taken(at t: Date) { if busySince == nil { busySince = t }; releasedAt = nil }
    mutating func released(at t: Date) { releasedAt = t }
    /// called by a timer: true exactly once, when the blob is due
    mutating func poll(now: Date) -> Bool {
        guard let r = releasedAt else { return false }
        guard let b = busySince else { releasedAt = nil; return false }
        if now.timeIntervalSince(r) < window { return false }
        busySince = nil; releasedAt = nil
        return r.timeIntervalSince(b) >= minBusy
    }
}
