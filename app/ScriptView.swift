// ScriptView.swift: v43 (28.11.2026). The script view of the recorder window drawn as a code editor.
// Marko, 28.11.2026: "I wanted this user interface with all these actions to look like a programming interface, like I'm writing
// software. In that sense, I'm missing the line numbers, and also I'm missing the color coding, like I'm in some kind of code editor."
//
// One row = one script line: a right-aligned dimmed line number in a gutter (it belongs to its row, so it stays aligned when the
// list scrolls and when a long line wraps over several lines), then the line in a monospaced face, coloured token by token, and
// indented by the block it is in (Loop / If / While / For / function bodies, by the { and } of the lines above it).
//
// The palette is the Mantra ground (#0B0D10) and sand ink (#F2DDB4) with amber for the commands, as in the editor window
// (Editor.swift, MANTRA_MANIFEST mantra-design-language.md §1: dark ground, warm ink, monospace), plus five quiet hues that are
// all above 4.5:1 on the ground so nothing is hard to read:
//   command names      amber, bold            Click  Send  Sleep  ClickImage  WinActivate
//   block words        blue, bold             If  Else  Loop  While  For  Break  Return  and / or / not
//   strings            green                  "text"
//   picture and files  cyan                   "keep-button.png"
//   numbers            salmon                 100  0x1F  2.5
//   keys inside Send   pink                   {Enter}  {Ctrl down}  and the ^ ! + # modifiers
//   A_ variables       lavender               A_Index  A_Clipboard
//   brackets, commas   sand, dimmed
//   comments, labels   grey, italic           ; a comment    ; label: a name
import SwiftUI

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

enum CodeColor {
    static let commands: Set<String> = Set(Script.commands.map { $0.name.lowercased() })
    static let sendLike: Set<String> = ["send", "sendinput", "sendevent", "sendplay"]
    static let picture: [String] = [".png", ".jpg", ".jpeg"]

    /// the tokens of one line: its command, its arguments, its label and its comment
    static func tokens(_ row: ActionRow) -> [SynToken] {
        if row.action.caseInsensitiveCompare("Comment") == .orderedSame { return [SynToken(text: "; " + row.value, kind: .comment)] }
        var out: [SynToken] = []
        let lower = row.action.lowercased()
        var kind = SynKind.plain
        if KEYWORDS.contains(lower) { kind = .keyword }
        else if commands.contains(lower) { kind = .command }
        else if row.action.hasPrefix("A_") { kind = .variable }
        else if row.action.hasPrefix("}") || row.action.hasPrefix("{") { kind = .punct }
        out.append(SynToken(text: row.action, kind: kind))
        if !row.value.isEmpty {
            let joiner = row.value.hasPrefix("(") ? "" : " "
            out.append(contentsOf: scan(joiner + row.value, send: sendLike.contains(lower)))
        }
        if !row.label.isEmpty { out.append(SynToken(text: "   ; label: " + row.label, kind: .label)) }
        if !row.comment.isEmpty { out.append(SynToken(text: "   ; " + row.comment, kind: .comment)) }
        return out
    }

    /// the arguments: strings, numbers, words, brackets
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

    static func piece(_ k: SynToken) -> Text {
        let t = Text(k.text).font(.system(size: 12, design: .monospaced))
        switch k.kind {
        case .command: return t.bold().foregroundColor(Color.synCommand)
        case .keyword: return t.bold().foregroundColor(Color.synKeyword)
        case .string: return t.foregroundColor(Color.synString)
        case .picture: return t.foregroundColor(Color.synPicture)
        case .number: return t.foregroundColor(Color.synNumber)
        case .key: return t.foregroundColor(Color.synKey)
        case .variable: return t.foregroundColor(Color.synVariable)
        case .punct: return t.foregroundColor(Color.synPunct)
        case .comment, .label: return t.italic().foregroundColor(Color.off)
        case .plain: return t.foregroundColor(Color.sand)
        }
    }

    static func text(_ row: ActionRow) -> Text {
        var t = Text("")
        for k in tokens(row) { t = t + piece(k) }
        return t
    }
}

extension RecorderRows {
    /// { opened minus } closed in a line, not counting the ones inside strings
    static func braceDelta(_ s: String) -> Int {
        var d = 0, skip = false
        var quote: Character? = nil
        for ch in s {
            if skip { skip = false; continue }
            if let q = quote {
                if ch == "`" { skip = true } else if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "{" { d += 1 }
            else if ch == "}" { d -= 1 }
        }
        return d
    }

    /// the indentation level of every row: the blocks (Loop, If, While, For, function bodies) the line is inside
    static func depths(_ rows: [ActionRow]) -> [Int] {
        var out: [Int] = []
        var depth = 0
        for r in rows {
            if r.action.caseInsensitiveCompare("Comment") == .orderedSame { out.append(depth); continue }
            out.append(r.action.hasPrefix("}") ? max(0, depth - 1) : depth)
            depth = max(0, depth + braceDelta(r.action + " " + r.value))
        }
        return out
    }
}

/// one line of the script: the gutter with its number, then the coloured line
struct CodeLineView: View {
    let number: Int
    let gutter: CGFloat
    let row: ActionRow
    let depth: Int
    let selected: Bool
    let editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(number))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(selected ? Color.sand : Color.off)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8).padding(.vertical, 2)
            CodeColor.text(row)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12 + CGFloat(depth) * 18).padding(.trailing, 10).padding(.vertical, 2)
        }
        .background(selected ? Color.slate.opacity(0.9) : Color.clear)
        .overlay(alignment: .leading) { Rectangle().fill(Color.slate).frame(width: 1).offset(x: gutter) }
        .overlay(alignment: .leading) { Rectangle().fill(editing ? Color.amber : Color.clear).frame(width: 3).offset(x: gutter + 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("line \(number): \(row.rendered)")
    }
}
