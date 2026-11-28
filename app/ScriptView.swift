// ScriptView.swift: v44 (28.11.2026). THE CODE EDITOR of the recorder window.
// Marko, 28.11.2026: "the part which is having lines, numbers, we call it code editor. It needs to be as such. Really like any code
// editor ... I can easily select multiple lines and delete them. Delete and backspace work the same way. And I can press Ctrl A and
// delete everything. So please make this text editor."
//
// It is a real text editor over the macro's script text: an NSTextView (TextKit) in a scroll view with a line-number ruler. The TEXT is the
// only model (v43 kept a list of rows; that is gone): the parsed actions (the counter, the duration, the Edit Action dialog) are derived
// from the text, and Save writes the text exactly as it stands. Everything a text view does works as it does everywhere: caret, click and
// shift-click, drag selection, shift+arrows, double click a word, triple click a line, typing in a line, Delete and Backspace over a
// selection, ⌘A, cut, copy, paste (plain text), ⌘Z and ⇧⌘Z through the text view's undo manager. On top of that:
//   ⌃A and ⌘A both select all (so ⌃A does not go to the start of the line here)     Tab = 4 spaces (selected lines: all indented), ⇧Tab outdents
//   Return keeps the indentation of the line, one level deeper after a line that ends with {      ⌥↑ ⌥↓ move the line or the selected lines
// Colours (the palette of v43, Mantra ground #0B0D10, sand ink): commands amber bold, block words blue bold, strings green, pictures cyan,
// numbers salmon, keys inside Send pink, A_ variables lavender, brackets dimmed, comments grey. The text is coloured again as he types.
// A line that does not parse never breaks the editor: Script.parse names the first one, it gets a red mark in the gutter, a red wavy
// underline and its reason on hover (and in the status line); the text stays exactly as typed.
import SwiftUI
import AppKit

extension Color {
    static let synCommand = Color(red: 0xE8/255, green: 0xA3/255, blue: 0x3D/255)
    static let synKeyword = Color(red: 0x8C/255, green: 0xBF/255, blue: 0xFF/255)
    static let synString = Color(red: 0x7F/255, green: 0xD9/255, blue: 0x8A/255)
    static let synPicture = Color(red: 0x5F/255, green: 0xD7/255, blue: 0xE0/255)
    static let synNumber = Color(red: 0xF2/255, green: 0x8C/255, blue: 0x6B/255)
    static let synKey = Color(red: 0xE8/255, green: 0x8F/255, blue: 0xD8/255)
    static let synVariable = Color(red: 0xB8/255, green: 0xA4/255, blue: 0xFF/255)
    static let synPunct = Color(red: 0xF2/255, green: 0xDD/255, blue: 0xB4/255).opacity(0.65)
}

enum SynKind { case command, keyword, string, picture, number, key, variable, punct, plain, comment, label }

struct SynToken {
    let text: String
    let kind: SynKind
}

private func ns(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

enum CodeColor {
    static let commands: Set<String> = Set(Script.commands.map { $0.name.lowercased() })
    static let sendLike: Set<String> = ["send", "sendinput", "sendevent", "sendplay"]
    static let picture: [String] = [".png", ".jpg", ".jpeg"]
    static let MONO12 = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let BOLD12 = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

    static func color(_ k: SynKind) -> NSColor {
        switch k {
        case .command: return ns(0xE8, 0xA3, 0x3D)
        case .keyword: return ns(0x8C, 0xBF, 0xFF)
        case .string: return ns(0x7F, 0xD9, 0x8A)
        case .picture: return ns(0x5F, 0xD7, 0xE0)
        case .number: return ns(0xF2, 0x8C, 0x6B)
        case .key: return ns(0xE8, 0x8F, 0xD8)
        case .variable: return ns(0xB8, 0xA4, 0xFF)
        case .punct: return ns(0xF2, 0xDD, 0xB4, 0.65)
        case .comment, .label: return ns(0x7A, 0x80, 0x87)
        case .plain: return ns(0xF2, 0xDD, 0xB4)
        }
    }

    /// the arguments: strings, numbers, words, brackets. The pieces put together are exactly the text given.
    static func scan(_ s: String, send: Bool) -> [SynToken] {
        var out: [SynToken] = []
        let c = Array(s)
        var plain = ""
        var i = 0
        func flush() {
            if !plain.isEmpty { out.append(SynToken(text: plain, kind: .plain)); plain = "" }
        }
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" {
                var j = i + 1
                while j < c.count && c[j] != ch {
                    if c[j] == "`" { j += 1 }
                    j += 1
                }
                let end = min(j, c.count - 1)
                flush()
                out.append(contentsOf: stringTokens(String(c[i...end]), send: send))
                i = end + 1
            } else if ch.isNumber && (i == 0 || !(c[i - 1].isLetter || c[i - 1] == "_")) {
                flush()
                var j = i
                if ch == "0", j + 1 < c.count, c[j + 1] == "x" || c[j + 1] == "X" {
                    j += 2
                    while j < c.count && c[j].isHexDigit { j += 1 }
                } else {
                    while j < c.count && (c[j].isNumber || c[j] == ".") { j += 1 }
                }
                out.append(SynToken(text: String(c[i..<j]), kind: .number))
                i = j
            } else if ch.isLetter || ch == "_" {
                var j = i
                while j < c.count && (c[j].isLetter || c[j].isNumber || c[j] == "_") { j += 1 }
                let word = String(c[i..<j])
                let lw = word.lowercased()
                if word.hasPrefix("A_") {
                    flush(); out.append(SynToken(text: word, kind: .variable))
                } else if KEYWORDS.contains(lw) {
                    flush(); out.append(SynToken(text: word, kind: .keyword))
                } else if commands.contains(lw) && j < c.count && c[j] == "(" {
                    flush(); out.append(SynToken(text: word, kind: .command))
                } else {
                    plain += word
                }
                i = j
            } else if "{}()[],:=<>+-*/&|!?.".contains(ch) {
                flush()
                out.append(SynToken(text: String(ch), kind: .punct))
                i += 1
            } else {
                plain.append(ch)
                i += 1
            }
        }
        flush()
        return out
    }

    /// one string literal, quotes included: a picture, plain text, or (in Send) text with keys in it
    static func stringTokens(_ lit: String, send: Bool) -> [SynToken] {
        guard lit.count >= 2, let first = lit.first, lit.last == first else { return [SynToken(text: lit, kind: .string)] }
        let lower = lit.lowercased()
        if picture.contains(where: { lower.dropLast().hasSuffix($0) }) { return [SynToken(text: lit, kind: .picture)] }
        guard send else { return [SynToken(text: lit, kind: .string)] }
        var out: [SynToken] = [SynToken(text: String(first), kind: .string)]
        let inner = Array(lit.dropFirst().dropLast())
        var buf = ""
        func put() {
            if !buf.isEmpty { out.append(SynToken(text: buf, kind: .string)); buf = "" }
        }
        var i = 0
        while i < inner.count {
            let ch = inner[i]
            if ch == "{", let close = inner[i...].firstIndex(of: "}") {
                put()
                out.append(SynToken(text: String(inner[i...close]), kind: .key))
                i = close + 1
            } else if "^!+#".contains(ch) {
                put()
                out.append(SynToken(text: String(ch), kind: .key))
                i += 1
            } else {
                buf.append(ch)
                i += 1
            }
        }
        put()
        out.append(SynToken(text: String(first), kind: .string))
        return out
    }

    /// the character offset where a trailing comment starts (a ; at the start or after a space, outside strings), as the lexer reads it
    static func commentOffset(_ line: String) -> Int? {
        var quote: Character? = nil
        var escaped = false
        var previous: Character = " "
        for (index, char) in line.enumerated() {
            let before = previous
            previous = char
            if escaped { escaped = false; continue }
            if let q = quote {
                if char == "`" { escaped = true } else if char == q { quote = nil }
                continue
            }
            if char == "\"" || char == "'" { quote = char; continue }
            if char == ";" && (before == " " || before == "\t") { return index }
        }
        return nil
    }

    /// the coloured pieces of one raw line, in order; together they are exactly the line
    static func pieces(_ line: String) -> [SynToken] {
        var out: [SynToken] = []
        var code = line
        var comment = ""
        if let at = commentOffset(line) {
            let i = line.index(line.startIndex, offsetBy: at)
            code = String(line[..<i]); comment = String(line[i...])
        }
        let lead = String(code.prefix { $0 == " " || $0 == "\t" })
        var rest = String(code.dropFirst(lead.count))
        if !lead.isEmpty { out.append(SynToken(text: lead, kind: .plain)) }
        if !rest.isEmpty {
            let stop = rest.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "\t" }) ?? rest.endIndex
            let action = String(rest[..<stop])
            rest = String(rest[stop...])
            let lower = action.lowercased()
            var kind = SynKind.plain
            if KEYWORDS.contains(lower) { kind = .keyword }
            else if commands.contains(lower) { kind = .command }
            else if action.hasPrefix("A_") { kind = .variable }
            else if action.hasPrefix("}") || action.hasPrefix("{") { kind = .punct }
            if !action.isEmpty { out.append(SynToken(text: action, kind: kind)) }
            if !rest.isEmpty { out.append(contentsOf: scan(rest, send: sendLike.contains(lower))) }
        }
        if !comment.isEmpty { out.append(SynToken(text: comment, kind: .comment)) }
        return out
    }
}

// MARK: the text view

final class CodeTextView: NSTextView {
    var onMoveLines: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f == .control, event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(nil); return }      // ⌃A selects all
        if f == .option, event.keyCode == 126 { onMoveLines?(-1); return }
        if f == .option, event.keyCode == 125 { onMoveLines?(1); return }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    /// the line the caret is on is lit
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString
        let loc = selectedRange().location
        var r = NSRect.zero
        if loc >= text.length && (text.length == 0 || text.character(at: text.length - 1) == 10) {
            r = lm.extraLineFragmentRect
        } else {
            let para = text.paragraphRange(for: NSRange(location: min(loc, max(0, text.length - 1)), length: 0))
            let glyphs = lm.glyphRange(forCharacterRange: para, actualCharacterRange: nil)
            r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        }
        guard r.height > 0 else { return }
        let o = textContainerOrigin
        let band = NSRect(x: 0, y: r.minY + o.y, width: bounds.width, height: r.height)
        if band.intersects(rect) {
            ns(0x23, 0x30, 0x3D, 0.55).setFill()
            band.fill()
        }
    }
}

// MARK: the line-number gutter

final class GutterRuler: NSRulerView {
    weak var controller: CodeEditorController?

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 50
    }

    required init(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let c = controller, let line = c.errorLine, let tv = clientView as? NSTextView, let lm = tv.layoutManager else { return "" }
        let p = convert(point, to: tv)
        let y = p.y - tv.textContainerOrigin.y
        let glyph = lm.glyphIndex(for: NSPoint(x: 1, y: y), in: tv.textContainer!)
        let char = lm.characterIndexForGlyph(at: glyph)
        return c.lineNumber(at: char) == line ? "line \(line): \(c.errorMessage)" : ""
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let c = controller, let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        ns(0x0B, 0x0D, 0x10).setFill(); bounds.fill()
        NSColor.black.withAlphaComponent(0.28).setFill(); bounds.fill()
        ns(0x23, 0x30, 0x3D).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        let text = tv.string as NSString
        let caretLine = c.liveCaretLine()
        let numberFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let first = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
        var number = c.lineNumber(at: first)
        var idx = text.lineRange(for: NSRange(location: min(first, text.length), length: 0)).location
        let endsWithNewline = text.length == 0 || text.character(at: text.length - 1) == 10
        while true {
            var frag = NSRect.zero
            if idx >= text.length {
                guard endsWithNewline else { break }
                frag = lm.extraLineFragmentRect
            } else {
                let g = lm.glyphIndexForCharacter(at: idx)
                frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            }
            if frag.height > 0 {
                let y = convert(NSPoint(x: 0, y: frag.minY + tv.textContainerOrigin.y), from: tv).y
                let bad = c.errorLine == number
                let color: NSColor = bad ? ns(0xEF, 0x44, 0x44) : (number == caretLine ? ns(0xF2, 0xDD, 0xB4) : ns(0x7A, 0x80, 0x87))
                let label = NSAttributedString(string: String(number), attributes: [.font: numberFont, .foregroundColor: color])
                let w = label.size().width
                label.draw(at: NSPoint(x: bounds.maxX - 10 - w, y: y + (frag.height - label.size().height) / 2))
                if bad {
                    ns(0xEF, 0x44, 0x44).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 7, y: y + frag.height / 2 - 3.5, width: 7, height: 7)).fill()
                }
                if y > bounds.maxY { break }
            }
            if idx >= text.length { break }
            idx = NSMaxRange(text.lineRange(for: NSRange(location: idx, length: 0)))
            number += 1
        }
    }
}

// MARK: the controller: the text, its colours, its lines, its edits

final class CodeEditorController: NSObject, ObservableObject, NSTextViewDelegate {
    static let shared = CodeEditorController()

    @Published private(set) var text = ""              // a mirror of the text view, for the counters; the view is the model
    @Published private(set) var caretLine = 1          // 1-based, follows the caret
    @Published private(set) var revision = 0
    @Published private(set) var errorLine: Int?
    @Published private(set) var errorMessage = ""

    private(set) lazy var scrollView: NSScrollView = build()
    private var tv: CodeTextView?
    private var ruler: GutterRuler?
    private var parseWork: DispatchWorkItem?
    static let INDENT = "    "

    private func build() -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.font = CodeColor.MONO12
        view.textColor = ns(0xF2, 0xDD, 0xB4)
        view.backgroundColor = ns(0x0B, 0x0D, 0x10)
        view.drawsBackground = true
        view.insertionPointColor = ns(0xE8, 0xA3, 0x3D)
        view.selectedTextAttributes = [.backgroundColor: ns(0x3A, 0x55, 0x72), .foregroundColor: ns(0xFF, 0xFF, 0xFF)]
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.usesFindBar = true
        view.textContainerInset = NSSize(width: 8, height: 6)
        view.delegate = self
        view.onMoveLines = { [weak self] step in self?.moveLines(step) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = ns(0x0B, 0x0D, 0x10)
        scroll.documentView = view
        let gutter = GutterRuler(scrollView: scroll)
        gutter.controller = self
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        gutter.clientView = view
        tv = view
        ruler = gutter
        return scroll
    }

    /// the text view (made on first use)
    private var view: CodeTextView {
        _ = scrollView
        return tv!
    }

    var string: String { view.string }
    var firstResponderIsEditor: Bool { view.window?.firstResponder === view }

    // MARK: lines (1-based)

    private func starts() -> [Int] {
        let s = view.string as NSString
        var out = [0]
        var i = 0
        while i < s.length {
            if s.character(at: i) == 10 { out.append(i + 1) }
            i += 1
        }
        return out
    }

    var lineCount: Int { starts().count }

    func lineNumber(at location: Int) -> Int {
        let s = starts()
        var lo = 0, hi = s.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if s[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// the line with its line break
    func lineRange(_ n: Int) -> NSRange {
        let s = starts()
        let length = (view.string as NSString).length
        let i = min(max(n, 1), s.count) - 1
        let end = i + 1 < s.count ? s[i + 1] : length
        return NSRange(location: s[i], length: end - s[i])
    }

    /// the line without its line break
    func lineText(_ n: Int) -> String {
        let s = view.string as NSString
        var r = lineRange(n)
        if r.length > 0 && s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return s.substring(with: r)
    }

    func liveCaretLine() -> Int { lineNumber(at: view.selectedRange().location) }

    /// the lines the selection touches; a selection that ends at the start of a line does not include that line
    func selectedLines() -> ClosedRange<Int> {
        let r = view.selectedRange()
        let a = lineNumber(at: r.location)
        let end = r.length > 0 ? max(r.location, NSMaxRange(r) - 1) : r.location
        return a...max(a, lineNumber(at: end))
    }

    // MARK: setting and changing the text

    /// a whole new text (another macro, a reload): no undo of the old one, the caret kept on the same line number
    func setText(_ s: String, keepCaret: Bool = true) {
        let line = liveCaretLine()
        view.string = s
        view.undoManager?.removeAllActions()
        let n = min(keepCaret ? line : 1, lineCount)
        view.setSelectedRange(NSRange(location: lineRange(n).location, length: 0))
        changed()
    }

    /// one undoable edit
    func replace(_ range: NSRange, with s: String, select: NSRange? = nil) {
        let v = view
        guard v.shouldChangeText(in: range, replacementString: s) else { return }
        v.textStorage?.replaceCharacters(in: range, with: s)
        v.didChangeText()
        if let select { v.setSelectedRange(select) }
    }

    func replaceLine(_ n: Int, with s: String) {
        var r = lineRange(n)
        let t = view.string as NSString
        if r.length > 0 && t.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        let caret = view.selectedRange()
        let delta = (s as NSString).length - r.length
        var sel = caret
        if caret.location >= NSMaxRange(r) { sel.location += delta }
        replace(r, with: s, select: sel)
    }

    /// the indentation a new line after line n gets
    func indent(after n: Int) -> String {
        let t = lineText(n)
        let lead = String(t.prefix { $0 == " " || $0 == "\t" })
        let code = CodeColor.commentOffset(t).map { String(t.prefix($0)) } ?? t
        return lead + (code.trimmingCharacters(in: .whitespaces).hasSuffix("{") ? CodeEditorController.INDENT : "")
    }

    /// a new line after line n (0 = at the top), one undoable edit. The caret goes to it, or stays where it was.
    @discardableResult
    func insertLine(after n: Int, _ s: String, moveCaret: Bool) -> Int {
        let t = view.string as NSString
        let caret = view.selectedRange()
        let count = lineCount
        var at = 0, add = s + "\n", newLine = 1
        if n >= 1 {
            let k = min(n, count)
            at = NSMaxRange(lineRange(k))
            let endsWithBreak = t.length == 0 || t.character(at: t.length - 1) == 10
            if k == count && endsWithBreak {
                newLine = k                              // after the empty last line: it takes the new line, an empty one stays below
            } else if k == count {
                add = "\n" + s; newLine = k + 1         // the last line has no break: the new line brings its own
            } else {
                newLine = k + 1
            }
        }
        let sel = moveCaret ? NSRange(location: at + (add.hasPrefix("\n") ? 1 : 0), length: 0)
                            : NSRange(location: caret.location >= at ? caret.location + (add as NSString).length : caret.location, length: caret.length)
        replace(NSRange(location: at, length: 0), with: add, select: sel)
        return newLine
    }

    func deleteLines(_ r: ClosedRange<Int>) {
        let a = lineRange(r.lowerBound), b = lineRange(r.upperBound)
        var range = NSRange(location: a.location, length: NSMaxRange(b) - a.location)
        let t = view.string as NSString
        // the last line has no break after it: take the one before it, so no empty line is left behind
        if range.length > 0 && t.character(at: NSMaxRange(range) - 1) != 10 && range.location > 0 {
            range.location -= 1; range.length += 1
        }
        replace(range, with: "", select: NSRange(location: min(range.location, max(0, t.length - range.length)), length: 0))
    }

    func moveLines(_ step: Int) {
        let sel = selectedLines()
        let first = sel.lowerBound, last = sel.upperBound
        let count = lineCount
        if step < 0 && first <= 1 { return }
        if step > 0 && last >= count { return }
        let t = view.string as NSString
        let block = NSRange(location: lineRange(first).location, length: NSMaxRange(lineRange(last)) - lineRange(first).location)
        let other = step < 0 ? lineRange(first - 1) : lineRange(last + 1)
        let whole = NSUnionRange(block, other)
        var a = t.substring(with: block), b = t.substring(with: other)
        // a last line without its break swaps its break with the other one
        if a.hasSuffix("\n") == false { a += "\n"; if b.hasSuffix("\n") { b.removeLast() } }
        else if b.hasSuffix("\n") == false { b += "\n"; if a.hasSuffix("\n") { a.removeLast() } }
        let out = step < 0 ? a + b : b + a
        let shift = step < 0 ? -(other.length) : other.length
        let old = view.selectedRange()
        replace(whole, with: out, select: NSRange(location: max(0, old.location + shift), length: old.length))
    }

    func selectLines(_ from: Int, _ to: Int) {
        let a = lineRange(from), b = lineRange(max(from, to))
        view.setSelectedRange(NSRange(location: a.location, length: NSMaxRange(b) - a.location))
        view.scrollRangeToVisible(a)
    }

    func goToLine(_ n: Int) {
        let r = lineRange(n)
        view.setSelectedRange(NSRange(location: r.location, length: 0))
        view.scrollRangeToVisible(r)
        updateCaret()
    }

    func textFrom(line n: Int) -> String {
        (view.string as NSString).substring(from: lineRange(n).location)
    }

    func replaceAll(_ find: String, _ with: String) {
        guard !find.isEmpty else { return }
        let t = view.string
        let out = t.replacingOccurrences(of: find, with: with)
        guard out != t else { return }
        replace(NSRange(location: 0, length: (t as NSString).length), with: out, select: NSRange(location: 0, length: 0))
    }

    /// the next match after the caret (wraps round); false when there is none
    @discardableResult
    func find(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let t = view.string as NSString
        let from = NSMaxRange(view.selectedRange())
        var r = t.range(of: s, options: [.caseInsensitive], range: NSRange(location: min(from, t.length), length: t.length - min(from, t.length)))
        if r.location == NSNotFound { r = t.range(of: s, options: [.caseInsensitive]) }
        guard r.location != NSNotFound else { return false }
        view.setSelectedRange(r)
        view.scrollRangeToVisible(r)
        view.showFindIndicator(for: r)
        return true
    }

    /// the editor's own commands, for ⌘A-style buttons and the API (they are the text view's real methods)
    func command(_ name: String) {
        let v = view
        switch name {
        case "select-all": v.selectAll(nil)
        case "delete", "backspace": v.deleteBackward(nil)
        case "forward-delete": v.deleteForward(nil)
        case "undo": v.undoManager?.undo()
        case "redo": v.undoManager?.redo()
        case "cut": v.cut(nil)
        case "copy": v.copy(nil)
        case "paste": v.paste(nil)
        case "indent": indentLines(true)
        case "outdent": indentLines(false)
        default: break
        }
    }

    func focus() { view.window?.makeFirstResponder(view) }

    var selection: NSRange { view.selectedRange() }

    // MARK: Tab, Shift-Tab, Return

    private func indentLines(_ more: Bool) {
        let sel = selectedLines()
        var lines: [String] = []
        for n in sel { lines.append(lineText(n)) }
        let out = lines.map { l -> String in
            if more { return CodeEditorController.INDENT + l }
            var l2 = l
            var k = 0
            while k < 4, l2.first == " " { l2.removeFirst(); k += 1 }
            if k == 0, l2.first == "\t" { l2.removeFirst() }
            return l2
        }
        let a = lineRange(sel.lowerBound), b = lineRange(sel.upperBound)
        let t = view.string as NSString
        var range = NSRange(location: a.location, length: NSMaxRange(b) - a.location)
        let hadBreak = range.length > 0 && t.character(at: NSMaxRange(range) - 1) == 10
        if hadBreak { range.length -= 1 }
        let joined = out.joined(separator: "\n")
        replace(range, with: joined, select: NSRange(location: range.location, length: (joined as NSString).length))
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let r = textView.selectedRange()
            let n = lineNumber(at: r.location)
            let line = lineText(n)
            let col = min(max(0, r.location - lineRange(n).location), (line as NSString).length)
            let before = (line as NSString).substring(to: col)
            let lead = String(before.prefix { $0 == " " || $0 == "\t" })
            let code = CodeColor.commentOffset(before).map { String(before.prefix($0)) } ?? before
            let deeper = code.trimmingCharacters(in: .whitespaces).hasSuffix("{") ? CodeEditorController.INDENT : ""
            textView.insertText("\n" + lead + deeper, replacementRange: r)
            return true
        }
        if sel == #selector(NSResponder.insertTab(_:)) {
            if selectedLines().count > 1 { indentLines(true) } else { textView.insertText(CodeEditorController.INDENT, replacementRange: textView.selectedRange()) }
            return true
        }
        if sel == #selector(NSResponder.insertBacktab(_:)) {
            indentLines(false)
            return true
        }
        return false
    }

    // MARK: the delegate: colours, parse, caret

    func textDidChange(_ notification: Notification) { changed() }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateCaret()
        tv?.needsDisplay = true
        ruler?.needsDisplay = true
    }

    private func updateCaret() {
        let n = liveCaretLine()
        if n != caretLine { caretLine = n }
    }

    private func changed() {
        text = view.string
        revision += 1
        updateCaret()
        highlight()
        let digits = String(lineCount).count
        ruler?.ruleThickness = CGFloat(max(2, digits)) * 8 + 30
        ruler?.needsDisplay = true
        tv?.needsDisplay = true
        parseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.checkSyntax() }
        parseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func checkSyntax() {
        switch Script.parse(view.string) {
        case .success:
            if errorLine != nil { errorLine = nil; errorMessage = "" }
        case .failure(let e):
            errorLine = e.line
            errorMessage = e.msg
        }
        highlight()
        ruler?.needsDisplay = true
    }

    /// colours the whole text again (attributes only: the text, the undo and the caret are not touched)
    func highlight() {
        guard let st = view.textStorage else { return }
        let s = st.string as NSString
        let all = NSRange(location: 0, length: s.length)
        st.beginEditing()
        st.setAttributes([.font: CodeColor.MONO12, .foregroundColor: CodeColor.color(.plain)], range: all)
        s.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = s.substring(with: lineRange)
            var pos = lineRange.location
            for tok in CodeColor.pieces(line) {
                let len = (tok.text as NSString).length
                let r = NSRange(location: pos, length: len)
                st.addAttribute(.foregroundColor, value: CodeColor.color(tok.kind), range: r)
                if tok.kind == .command || tok.kind == .keyword { st.addAttribute(.font, value: CodeColor.BOLD12, range: r) }
                if tok.kind == .comment { st.addAttribute(.obliqueness, value: 0.15, range: r) }
                pos += len
            }
        }
        if let bad = errorLine, bad >= 1, bad <= lineCount {
            var r = lineRange(bad)
            if r.length > 0 && s.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
            if r.length > 0 {
                st.addAttribute(.underlineStyle, value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue, range: r)
                st.addAttribute(.underlineColor, value: ns(0xEF, 0x44, 0x44), range: r)
            }
        }
        st.endEditing()
    }
}

/// the code editor in the SwiftUI window
struct CodeEditorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView { CodeEditorController.shared.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
