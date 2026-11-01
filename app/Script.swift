// Script.swift
//
// MANTRA SCRIPT: AutoHotkey v2 syntax on the Mac, the port of script.lua (30.10.2026). Foundation only.
// Marko's request, 5.9.2026: "a script editor so the user can edit the macros himself. Copy the syntax from
// AutoHotkey, so the user also learns how to code with AutoHotkey. If statements, loop statements, and all the
// other features." And: "load screenshots of the buttons, so the app can click by optical recognition of the
// patterns on my screen."
//
// WHAT THIS FILE IS. A lexer, a parser to a small tree, and an interpreter that walks the tree. It knows nothing
// about the screen: every click, key, sleep and image search goes through a HOST the caller gives it, so the whole
// language is tested with a fake host (tests/ScriptTests.swift) and the app only supplies the real one.
//
// THE INTERPRETER RUNS ON A BACKGROUND THREAD. Where the Lua yielded from a coroutine, the host's sleep simply
// blocks that thread, and the stop key makes the host throw ScriptStopped, which passes through everything here.
// Every 400 steps the interpreter calls sleep(0), so a tight loop with no Sleep can still be stopped.
//
// ALSO HERE: fromEvents, which turns a recording into a script, and parseSend, which reads AutoHotkey Send
// strings: ^c, !{Tab}, +{Enter}, #v, {Ctrl down}, {WheelDown 3}.
//
// The language is documented in docs/SCRIPT.md.

import Foundation

// MARK: the host

struct ScriptStopped: Error {}                    // thrown by the host when the stop key is pressed; passes through untouched
struct ImageHit { var x: Double; var y: Double; var w: Double; var h: Double; var score: Double }   // top-left, global points
protocol ScriptHost: AnyObject {
    func now() -> Double
    func sleep(_ seconds: Double) throws          // the host divides by speed itself; sleep(0) is the yield point
    func mouseMove(_ x: Double, _ y: Double) throws
    func click(_ button: String, _ x: Double?, _ y: Double?, _ times: Int, _ mods: [String]) throws
    func buttonDownUp(_ button: String, _ down: Bool, _ x: Double?, _ y: Double?, _ mods: [String]) throws
    func drag(_ button: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ mods: [String]) throws
    func mousePos() -> (Int, Int)
    func key(_ mods: [String], _ name: String) throws
    func keyDownUp(_ name: String, _ down: Bool, _ mods: [String]) throws
    func type(_ text: String) throws
    func wheel(_ dir: String, _ times: Int, _ mods: [String]) throws
    func imageSearch(_ file: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) throws -> ImageHit?
    func searchHold(_ on: Bool)
    func pixel(_ x: Double, _ y: Double) -> String
    func say(_ text: String, _ long: Bool)
    func run(_ what: String)
    func activate(_ title: String) -> Bool
    func winExists(_ title: String) -> Bool
    func menuSelect(_ title: String, _ path: [String]) -> Bool
    func winGetPos(_ title: String) -> (Double, Double, Double, Double)?
    func recalibrate(_ name: String) -> (Bool, String)
    func clipboard() -> String
    func setClipboard(_ v: String)
    func screen() -> (Double, Double)
    func fileExist(_ p: String) -> Bool
    func fileRead(_ p: String) -> String
    func fileAppend(_ text: String, _ p: String)
}

// MARK: errors

struct ScriptError: Error {
    let line: Int?
    let msg: String
    var text: String { line.map { "line \($0): \(msg)" } ?? msg }
}
private func fail(_ line: Int?, _ msg: String) -> ScriptError { ScriptError(line: line, msg: msg) }

typealias Program = Script.Node

// A recorded event, as the recorder writes it into ~/.mantra_macro/recordings/*.json
struct RecEvent: Codable {
    var kind: String; var t: Double
    var x: Double?; var y: Double?; var code: Int?; var mods: [String]?; var button: Int?; var dx: Double?; var dy: Double?
    init(kind: String, t: Double, x: Double? = nil, y: Double? = nil, code: Int? = nil, mods: [String]? = [],
         button: Int? = nil, dx: Double? = nil, dy: Double? = nil) {
        self.kind = kind; self.t = t; self.x = x; self.y = y; self.code = code; self.mods = mods
        self.button = button; self.dx = dx; self.dy = dy
    }
    // tolerant: a Lua JSON encoder may write an empty mods as {} and a code as 8.0
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        t = (try? c.decode(Double.self, forKey: .t)) ?? 0
        x = try? c.decode(Double.self, forKey: .x); y = try? c.decode(Double.self, forKey: .y)
        code = (try? c.decode(Int.self, forKey: .code)) ?? (try? c.decode(Double.self, forKey: .code)).map { Int($0) }
        mods = (try? c.decode([String].self, forKey: .mods)) ?? []
        button = (try? c.decode(Int.self, forKey: .button)) ?? (try? c.decode(Double.self, forKey: .button)).map { Int($0) }
        dx = try? c.decode(Double.self, forKey: .dx); dy = try? c.decode(Double.self, forKey: .dy)
    }
}

enum Script {

    // MARK: values

    final class ArrBox { var items: [Value?]; init(_ i: [Value?]) { items = i } ; var n: Int { items.count } }
    final class MapBox { var keys: [String] = []; var data: [String: Value] = [:] }
    final class Ref { let name: String; let get: () -> Value?; let set: (Value?) -> Void
        init(_ n: String, _ g: @escaping () -> Value?, _ s: @escaping (Value?) -> Void) { name = n; get = g; set = s } }

    enum Value {
        case num(Double), str(String), arr(ArrBox), map(MapBox), ref(Ref)
    }

    static func fmtNum(_ v: Double) -> String {
        if !v.isFinite { return v.isNaN ? "nan" : (v > 0 ? "inf" : "-inf") }
        if v == v.rounded(.down) && abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func toStr(_ v: Value?) -> String {
        switch v {
        case nil: return ""
        case .num(let d)?: return fmtNum(d)
        case .str(let s)?: return s
        case .arr(let a)?: return "[" + a.items.map { toStr($0) }.joined(separator: ", ") + "]"
        case .map(let m)?: return "Map(\(m.keys.count))"
        case .ref(let r)?: return "&" + r.name
        }
    }

    // Lua's tonumber for text: spaces around, decimal, exponent, 0x hex; nothing else
    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        var body = Substring(t), neg = false
        if body.first == "-" || body.first == "+" { neg = body.first == "-"; body = body.dropFirst() }
        if body.lowercased().hasPrefix("0x") {
            guard let v = UInt64(body.dropFirst(2), radix: 16) else { return nil }
            return neg ? -Double(v) : Double(v)
        }
        guard body.range(of: #"^(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil,
              let v = Double(body) else { return nil }
        return neg ? -v : v
    }

    static func toNum(_ v: Value?, _ line: Int?, _ what: String? = nil) throws -> Double {
        switch v {
        case nil: return 0
        case .num(let d)?: return d
        case .str(let s)?:
            if let n = number(s) { return n }
            if s.isEmpty { return 0 }
        default: break
        }
        throw fail(line, (what ?? "this") + " needs a number, not \"" + toStr(v) + "\"")
    }

    static func truthy(_ v: Value?) -> Bool {
        switch v {
        case nil: return false
        case .num(let d)?: return d != 0
        case .str(let s)?: return !(s.isEmpty || s == "0")
        default: return true
        }
    }

    static func isNumeric(_ v: Value?) -> Bool {
        switch v {
        case .num?: return true
        case .str(let s)?: return number(s) != nil
        default: return false
        }
    }
    static func numOf(_ v: Value?) -> Double? {
        switch v { case .num(let d)?: return d; case .str(let s)?: return number(s); default: return nil }
    }

    static func compare(_ op: String, _ a: Value?, _ b: Value?, _ line: Int) throws -> Bool {
        if let x = numOf(a), let y = numOf(b) {
            switch op {
            case "=", "==": return x == y
            case "!=", "<>": return x != y
            case "<": return x < y
            case ">": return x > y
            case "<=": return x <= y
            case ">=": return x >= y
            default: break
            }
        }
        let x = toStr(a), y = toStr(b)
        switch op {
        case "=": return x.lowercased() == y.lowercased()
        case "==": return x == y
        case "!=", "<>": return x.lowercased() != y.lowercased()
        case "<": return x < y
        case ">": return x > y
        case "<=": return x <= y
        case ">=": return x >= y
        default: throw fail(line, "unknown comparison " + op)
        }
    }

    // MARK: lexer

    enum TT { case nl, eof, str, num, id, kw, op, directive }
    struct Tok { var type: TT; var value: String?; var num: Double = 0; var line: Int; var raw: String? = nil; var spaced = false }

    static let KEYWORDS: Set<String> = ["if", "else", "while", "loop", "for", "in", "break", "continue", "return", "and",
                                        "or", "not", "true", "false", "global", "local", "static", "until"]
    static let OPS: [String] = [":=", "+=", "-=", "*=", "/=", ".=", "//=", "++", "--", "**", "//", "==",
                                "!=", "<>", "<=", ">=", "&&", "||", "::", "<", ">", "=", "+", "-", "*",
                                "/", ".", ",", "(", ")", "[", "]", "{", "}", "!", "?", ":", "&", "%"]
        .sorted { $0.count > $1.count }
    static let ESC: [Character: String] = ["n": "\n", "t": "\t", "r": "\r", "`": "`", "\"": "\"", "'": "'", "b": "\u{8}", "s": " "]

    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    static func isAlpha(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    static func isHex(_ c: Character) -> Bool { c.isASCII && c.isHexDigit }

    static func lex(_ source: String) throws -> [Tok] {
        let text = Array(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        let n = text.count
        var toks: [Tok] = [], i = 0, line = 1, atLineStart = true
        func ch(_ k: Int) -> Character? { k >= 0 && k < n ? text[k] : nil }
        func push(_ t: TT, _ v: String? = nil) { toks.append(Tok(type: t, value: v, line: line)) }
        while i < n {
            let c = text[i]
            if atLineStart && c != "\n" {
                // a hotkey label: `^r::` at the start of a line (the Lua ^[^%s"';]+:: : a run of such
                // characters with "::" somewhere after its first one)
                var j = i
                while j < n, !text[j].isWhitespace, !"\"';".contains(text[j]) { j += 1 }
                let word = String(text[i..<j])
                if let r = word.range(of: "::"), r.lowerBound != word.startIndex {
                    throw fail(line, "hotkeys belong to the slots on the settings page, not inside a macro")
                }
            }
            if c == "\n" {
                push(.nl); line += 1; i += 1; atLineStart = true
            } else if c == " " || c == "\t" {
                i += 1
            } else if c == ";" && (atLineStart || ch(i - 1) == " " || ch(i - 1) == "\t") {
                while i < n && text[i] != "\n" { i += 1 }
            } else if atLineStart && c == "/" && ch(i + 1) == "*" {
                var j = i + 2
                while j + 1 < n && !(text[j] == "*" && text[j + 1] == "/") { j += 1 }
                if j + 1 >= n { throw fail(line, "a /* comment that never closes") }
                for k in i...j where text[k] == "\n" { line += 1 }
                i = j + 2
            } else if c == "\"" || c == "'" {
                let q = c; var j = i + 1, buf = ""
                while true {
                    guard let d = ch(j), d != "\n" else { throw fail(line, "a string that never closes") }
                    if d == "`" {
                        if let e = ch(j + 1) { buf += ESC[e] ?? String(e) }
                        j += 2
                    } else if d == q {
                        if ch(j + 1) == q { buf.append(q); j += 2 }        // "" is one "
                        else { j += 1; break }
                    } else { buf.append(d); j += 1 }
                }
                push(.str, buf)
                i = j; atLineStart = false
            } else if isDigit(c) || (c == "." && ch(i + 1).map(isDigit) == true) {
                var j = i
                var value: Double
                if c == "0", let x = ch(i + 1), x == "x" || x == "X", ch(i + 2).map(isHex) == true {
                    j = i + 2
                    while j < n && isHex(text[j]) { j += 1 }
                    value = Double(UInt64(String(text[(i + 2)..<j]), radix: 16) ?? 0)
                } else {
                    // %d*%.?%d+ with an optional exponent, as the Lua patterns read it
                    while j < n && isDigit(text[j]) { j += 1 }
                    if j < n && text[j] == "." && ch(j + 1).map(isDigit) == true {
                        j += 1
                        while j < n && isDigit(text[j]) { j += 1 }
                    }
                    if j < n && (text[j] == "e" || text[j] == "E") {
                        var k = j + 1
                        if k < n && (text[k] == "+" || text[k] == "-") { k += 1 }
                        if k < n && isDigit(text[k]) {
                            while k < n && isDigit(text[k]) { k += 1 }
                            j = k
                        }
                    }
                    value = Double(String(text[i..<j])) ?? 0
                }
                var t = Tok(type: .num, value: fmtNum(value), line: line); t.num = value
                toks.append(t)
                i = j; atLineStart = false
            } else if isAlpha(c) || "_#@$".contains(c) {
                var j = i + 1
                while j < n && (isAlpha(text[j]) || isDigit(text[j]) || text[j] == "_") { j += 1 }
                let s = String(text[i..<j])
                if s.hasPrefix("#") { push(.directive, s) }
                else if KEYWORDS.contains(s.lowercased()) {
                    var t = Tok(type: .kw, value: s.lowercased(), line: line); t.raw = s; toks.append(t)
                } else { push(.id, s) }
                i = j; atLineStart = false
            } else {
                var hit: String?
                for op in OPS {
                    let oc = Array(op)
                    if i + oc.count <= n && Array(text[i..<(i + oc.count)]) == oc { hit = op; break }
                }
                guard let op = hit else { throw fail(line, "unexpected character '\(c)'") }
                let before = i == 0 || ch(i - 1) == " " || ch(i - 1) == "\t"
                let a = ch(i + op.count)
                let after = a == nil || a == " " || a == "\t" || a == "\n"
                var t = Tok(type: .op, value: op, line: line); t.spaced = before && after
                toks.append(t)
                i += op.count; atLineStart = false
            }
        }
        push(.nl); push(.eof)
        return toks
    }

    // MARK: the tree

    struct Param { var name: String; var byref: Bool; var def: Node? }
    final class Node {
        let type: String; let line: Int
        var value: Value? = nil; var name = ""; var op = ""
        var args: [Node] = []; var items: [Node] = []; var pairs: [(String, Node)] = []
        var l: Node?, r: Node?, e: Node?, c: Node?, a: Node?, b: Node?, obj: Node?, idx: Node?
        var body: [Node] = []; var cond: Node?, thenb: Node?, elseb: Node?, count: Node?, until: Node?
        var k = "", v: String?, iter: Node?, expr: Node?, target: Node?
        var scope = "", names: [String] = [], inits: [String: Node] = [:], params: [Param] = []
        var bodyBlock: Node?
        init(_ type: String, _ line: Int) { self.type = type; self.line = line }
    }

    static let ASSIGN_OPS: Set<String> = [":=", "+=", "-=", "*=", "/=", ".=", "//="]
    // precedence climbing. Levels: 1 ?: · 2 || or · 3 && and · 4 ! not · 5 comparison · 6 concat · 7 + - · 8 * / // · 9 ** · 12 unary
    static let BIN: [String: Int] = ["||": 2, "or": 2, "&&": 3, "and": 3,
                                     "=": 5, "==": 5, "!=": 5, "<>": 5, "<": 5, ">": 5, "<=": 5, ">=": 5,
                                     ".": 6, "+": 7, "-": 7, "*": 8, "/": 8, "//": 8, "**": 9]

    // MARK: parser

    // every builtin may be written `Name arg, arg` on its own line, the AutoHotkey way
    static func parse(_ text: String) -> Result<Program, ScriptError> {
        do {
            let p = Parser(try lex(text))
            return .success(try p.program())
        } catch let e as ScriptError { return .failure(e) }
        catch { return .failure(ScriptError(line: 0, msg: "\(error)")) }
    }

    final class Parser {
        let toks: [Tok]; var p = 0
        init(_ t: [Tok]) { toks = t }
        func peek(_ k: Int = 0) -> Tok { toks[min(p + k, toks.count - 1)] }
        @discardableResult func nextTok() -> Tok { let t = peek(); p += 1; return t }
        func isOp(_ t: Tok, _ v: String) -> Bool { t.type == .op && t.value == v }
        func isKw(_ t: Tok, _ v: String) -> Bool { t.type == .kw && t.value == v }
        func skipNl() { while peek().type == .nl { p += 1 } }
        @discardableResult func expectOp(_ v: String) throws -> Tok {
            let t = nextTok()
            if !isOp(t, v) { throw fail(t.line, "expected '\(v)'" + (t.value.map { " near '\($0)'" } ?? "")) }
            return t
        }
        func endOfStatement() throws {
            let t = peek()
            if t.type == .nl || t.type == .eof || isOp(t, "}") { return }
            throw fail(t.line, "unexpected '\(t.value ?? "nil")'")
        }

        // comma separated expressions; &name is a reference. Inside brackets newlines are nothing; in command
        // style the line is the statement.
        func parseArgs(_ closer: String?) throws -> [Node] {
            var args: [Node] = []
            func nl() { if closer != nil { skipNl() } }
            nl()
            if let c = closer, isOp(peek(), c) { return args }
            while true {
                nl()
                let t = peek()
                if isOp(t, "&") && peek(1).type == .id {
                    nextTok(); let id = nextTok()
                    let a = Node("ref", id.line); a.name = id.value!; args.append(a)
                } else if isOp(t, ",") {
                    args.append(Node("empty", t.line))                  // a left-out argument
                } else {
                    args.append(try parseExpr())
                }
                nl()
                if isOp(peek(), ",") { nextTok() } else { break }
            }
            return args
        }

        func parsePrimary() throws -> Node {
            let t = nextTok()
            if t.type == .num { let e = Node("num", t.line); e.value = .num(t.num); return e }
            if t.type == .str { let e = Node("str", t.line); e.value = .str(t.value!); return e }
            if t.type == .kw && (t.value == "true" || t.value == "false") {
                let e = Node("num", t.line); e.value = .num(t.value == "true" ? 1 : 0); return e
            }
            if t.type == .kw && t.value == "not" { let e = Node("un", t.line); e.op = "!"; e.e = try parseExpr(4); return e }
            if t.type == .id {
                if isOp(peek(), "(") {
                    nextTok()
                    let args = try parseArgs(")")
                    skipNl(); try expectOp(")")
                    let e = Node("call", t.line); e.name = t.value!; e.args = args; return e
                }
                let e = Node("var", t.line); e.name = t.value!; return e
            }
            if isOp(t, "(") {
                skipNl()
                let e = try parseExpr()
                skipNl(); try expectOp(")")
                return e
            }
            if isOp(t, "[") {
                let items = try parseArgs("]")
                skipNl(); try expectOp("]")
                let e = Node("array", t.line); e.items = items; return e
            }
            if isOp(t, "{") {
                // an object literal {a: 1, b: 2} becomes a Map
                let e = Node("object", t.line)
                skipNl()
                while !isOp(peek(), "}") {
                    let k = nextTok()
                    if k.type != .id && k.type != .str && k.type != .kw { throw fail(k.line, "expected a name in {}") }
                    try expectOp(":")
                    e.pairs.append((k.raw ?? k.value ?? "", try parseExpr()))
                    skipNl()
                    if isOp(peek(), ",") { nextTok(); skipNl() }
                }
                try expectOp("}")
                return e
            }
            if isOp(t, "-") { let e = Node("un", t.line); e.op = "-"; e.e = try parseExpr(12); return e }
            if isOp(t, "+") { return try parseExpr(12) }
            if isOp(t, "!") { let e = Node("un", t.line); e.op = "!"; e.e = try parseExpr(12); return e }
            if isOp(t, "&") && peek().type == .id {
                let id = nextTok(); let e = Node("ref", id.line); e.name = id.value!; return e
            }
            if isOp(t, "++") || isOp(t, "--") {
                let id = nextTok()
                if id.type != .id { throw fail(t.line, "expected a variable after " + t.value!) }
                let e = Node("preinc", t.line); e.name = id.value!; e.op = t.value!; return e
            }
            if t.type == .eof || t.type == .nl {
                var k = p - 2
                while k > 0 && toks[k].type == .nl { k -= 1 }
                let line = k >= 0 ? toks[k].line : t.line
                throw fail(line, "the line ends too soon; something is missing after the last operator")
            }
            throw fail(t.line, "unexpected '\(t.value ?? "nil")'")
        }

        func parsePostfix() throws -> Node {
            var e = try parsePrimary()
            while true {
                let t = peek()
                if isOp(t, "[") {
                    nextTok(); skipNl()
                    let idx = try parseExpr()
                    skipNl(); try expectOp("]")
                    let n = Node("index", t.line); n.obj = e; n.idx = idx; e = n
                } else if isOp(t, ".") && !t.spaced && peek(1).type == .id {
                    nextTok(); let name = nextTok()
                    if isOp(peek(), "(") {
                        nextTok()
                        let args = try parseArgs(")")
                        skipNl(); try expectOp(")")
                        let n = Node("mcall", t.line); n.obj = e; n.name = name.value!; n.args = args; e = n
                    } else {
                        let n = Node("member", t.line); n.obj = e; n.name = name.value!; e = n
                    }
                } else if (isOp(t, "++") || isOp(t, "--")) && e.type == "var" {
                    nextTok()
                    let n = Node("postinc", t.line); n.name = e.name; n.op = t.value!; e = n
                } else { return e }
            }
        }

        func binOp(_ t: Tok) -> String? {
            if t.type == .op, let v = t.value, BIN[v] != nil {
                if v == "." && !t.spaced { return nil }               // a.b is a member, handled above
                return v
            }
            if t.type == .kw && (t.value == "and" || t.value == "or") { return t.value }
            return nil
        }
        // juxtaposition: `"a" b` is a concat in AutoHotkey. Two values with nothing between them, on one line, join.
        func juxtaposes(_ t: Tok) -> Bool { t.type == .str || t.type == .num || t.type == .id }

        func parseExpr(_ minPrec: Int = 1) throws -> Node {
            var left = try parsePostfix()
            while true {
                let t = peek()
                if var op = binOp(t) {
                    let prec = BIN[op]!
                    if prec < minPrec { break }
                    nextTok(); skipNl()
                    let right = try parseExpr(op == "**" ? prec : prec + 1)
                    if op == "and" { op = "&&" } else if op == "or" { op = "||" }
                    let n = Node("bin", t.line); n.op = op; n.l = left; n.r = right; left = n
                } else if isOp(t, "?") && minPrec <= 1 {
                    nextTok(); skipNl()
                    let a = try parseExpr(1)
                    skipNl(); try expectOp(":"); skipNl()
                    let b = try parseExpr(1)
                    let n = Node("tern", t.line); n.c = left; n.a = a; n.b = b; left = n
                } else if juxtaposes(t) && minPrec <= 6 &&
                            !(t.type == .id && ASSIGN_OPS.contains(peek(1).type == .op ? peek(1).value ?? "" : "")) {
                    // `x y` joins, unless y starts an assignment
                    let right = try parseExpr(7)
                    let n = Node("bin", t.line); n.op = "."; n.l = left; n.r = right; left = n
                } else { break }
            }
            return left
        }

        func parseBlock() throws -> Node {
            let open = try expectOp("{")
            let b = Node("block", open.line)
            while true {
                skipNl()
                let t = peek()
                if isOp(t, "}") { nextTok(); break }
                if t.type == .eof { throw fail(open.line, "a { that never closes") }
                b.body.append(try parseStatement())
            }
            return b
        }

        func parseBlockOrStatement() throws -> Node {
            skipNl()
            if isOp(peek(), "{") { return try parseBlock() }
            let st = try parseStatement()
            let b = Node("block", st.line); b.body = [st]; return b
        }

        // is this `Name(a, b) {` a function definition?
        func looksLikeFuncDef() -> Bool {
            if peek().type != .id || !isOp(peek(1), "(") { return false }
            var k = 2
            while true {
                let t = peek(k)
                if t.type == .eof || t.type == .nl { return false }
                if isOp(t, ")") { break }
                if !(t.type == .id || isOp(t, ",") || isOp(t, "&") || isOp(t, ":=") || t.type == .num || t.type == .str) { return false }
                k += 1
            }
            k += 1
            while peek(k).type == .nl { k += 1 }
            return isOp(peek(k), "{")
        }

        func parseStatement() throws -> Node {
            skipNl()
            let t = peek()
            if t.type == .directive {
                // #Requires, #SingleInstance and friends are accepted and ignored
                while peek().type != .nl && peek().type != .eof { nextTok() }
                return Node("nop", t.line)
            }
            if isOp(t, "{") { return try parseBlock() }
            if t.type == .kw {
                switch t.value! {
                case "if":
                    nextTok()
                    let n = Node("if", t.line)
                    n.cond = try parseExpr()
                    n.thenb = try parseBlockOrStatement()
                    let save = p
                    skipNl()
                    if isKw(peek(), "else") {
                        nextTok(); skipNl()
                        if isKw(peek(), "if") {
                            let st = try parseStatement()
                            let b = Node("block", st.line); b.body = [st]; n.elseb = b
                        } else { n.elseb = try parseBlockOrStatement() }
                    } else { p = save }
                    return n
                case "while":
                    nextTok()
                    let n = Node("while", t.line)
                    n.cond = try parseExpr()
                    n.bodyBlock = try parseBlockOrStatement()
                    return n
                case "loop":
                    nextTok()
                    let n = Node("loop", t.line)
                    let nt = peek()
                    if nt.type == .id, ["parse", "files", "read", "reg"].contains(nt.value!.lowercased()) {
                        throw fail(t.line, "Loop \(nt.value!) is not available here; use Loop n, While, or For")
                    }
                    if !(nt.type == .nl || isOp(nt, "{")) { n.count = try parseExpr() }
                    n.bodyBlock = try parseBlockOrStatement()
                    let save = p
                    skipNl()
                    if isKw(peek(), "until") { nextTok(); n.until = try parseExpr() } else { p = save }
                    return n
                case "for":
                    nextTok()
                    let k = nextTok()
                    if k.type != .id { throw fail(t.line, "expected a variable after For") }
                    let n = Node("for", t.line); n.k = k.value!
                    if isOp(peek(), ",") {
                        nextTok(); let v = nextTok()
                        if v.type != .id { throw fail(t.line, "expected a second variable") }
                        n.v = v.value
                    }
                    if !isKw(nextTok(), "in") { throw fail(t.line, "expected 'in'") }
                    n.iter = try parseExpr()
                    n.bodyBlock = try parseBlockOrStatement()
                    return n
                case "break", "continue":
                    nextTok(); try endOfStatement()
                    return Node(t.value!, t.line)
                case "return":
                    nextTok()
                    let n = Node("return", t.line)
                    if !(peek().type == .nl || peek().type == .eof || isOp(peek(), "}")) { n.expr = try parseExpr() }
                    try endOfStatement()
                    return n
                case "global", "local", "static":
                    nextTok()
                    let n = Node("decl", t.line); n.scope = t.value!
                    while peek().type == .id {
                        let id = nextTok()
                        n.names.append(id.value!)
                        if isOp(peek(), ":=") { nextTok(); n.inits[id.value!] = try parseExpr() }
                        if isOp(peek(), ",") { nextTok() } else { break }
                    }
                    try endOfStatement()
                    return n
                case "else": throw fail(t.line, "'else' without an 'if'")
                case "until": throw fail(t.line, "'until' without a 'Loop'")
                default: break
                }
            }
            if t.type == .id {
                if looksLikeFuncDef() {
                    nextTok(); try expectOp("(")
                    let n = Node("func", t.line); n.name = t.value!
                    skipNl()
                    while !isOp(peek(), ")") {
                        var byref = false
                        if isOp(peek(), "&") { nextTok(); byref = true }
                        let id = nextTok()
                        if id.type != .id { throw fail(id.line, "expected a parameter name") }
                        var def: Node? = nil
                        if isOp(peek(), ":=") { nextTok(); def = try parseExpr() }
                        n.params.append(Param(name: id.value!, byref: byref, def: def))
                        if isOp(peek(), ",") { nextTok() }
                        skipNl()
                    }
                    try expectOp(")")
                    skipNl()
                    n.bodyBlock = try parseBlock()
                    return n
                }
                let n1 = peek(1)
                if n1.type == .op, let v = n1.value, ASSIGN_OPS.contains(v) {
                    nextTok(); nextTok()
                    skipNl()
                    let n = Node("assign", t.line)
                    let target = Node("var", t.line); target.name = t.value!
                    n.target = target; n.op = v; n.expr = try parseExpr()
                    try endOfStatement()
                    return n
                }
                if isOp(n1, "::") { throw fail(t.line, "hotkeys belong to the slots on the settings page, not inside a macro") }
                if isOp(n1, "(") || isOp(n1, "[") || (isOp(n1, ".") && !n1.spaced) || isOp(n1, "++") || isOp(n1, "--") {
                    let e = try parsePostfix()
                    let n2 = peek()
                    if n2.type == .op, let v = n2.value, ASSIGN_OPS.contains(v), e.type == "index" || e.type == "member" {
                        nextTok(); skipNl()
                        let n = Node("assign", t.line); n.target = e; n.op = v; n.expr = try parseExpr()
                        try endOfStatement()
                        return n
                    }
                    try endOfStatement()
                    let n = Node("expr", t.line); n.expr = e; return n
                }
                // command style: Name arg, arg, ...
                nextTok()
                var args: [Node] = []
                if !(peek().type == .nl || peek().type == .eof || isOp(peek(), "}")) { args = try parseArgs(nil) }
                try endOfStatement()
                let call = Node("call", t.line); call.name = t.value!; call.args = args
                let n = Node("expr", t.line); n.expr = call; return n
            }
            if isOp(t, "++") || isOp(t, "--") {
                let e = try parsePrimary()
                try endOfStatement()
                let n = Node("expr", t.line); n.expr = e; return n
            }
            throw fail(t.line, "unexpected " + (t.type == .eof ? "end of script" : "'\(t.value ?? "nil")'"))
        }

        func program() throws -> Node {
            let b = Node("block", 1)
            while true {
                skipNl()
                if peek().type == .eof { break }
                b.body.append(try parseStatement())
            }
            return b
        }
    }

    // MARK: Send strings

    // AutoHotkey key names to the names Hammerspoon knows (the host's key names).
    static let AHK_KEYS: [String: String] = {
        var m: [String: String] = [
            "enter": "return", "return": "return", "esc": "escape", "escape": "escape",
            "bs": "delete", "backspace": "delete", "del": "forwarddelete", "delete": "forwarddelete",
            "tab": "tab", "space": "space", "up": "up", "down": "down", "left": "left", "right": "right",
            "home": "home", "end": "end", "pgup": "pageup", "pgdn": "pagedown", "ins": "help", "insert": "help",
            "capslock": "capslock", "ctrl": "ctrl", "control": "ctrl", "alt": "alt", "shift": "shift",
            "lwin": "cmd", "rwin": "cmd", "win": "cmd", "cmd": "cmd", "command": "cmd", "lctrl": "ctrl",
            "rctrl": "ctrl", "lalt": "alt", "ralt": "alt", "lshift": "shift", "rshift": "shift",
            "option": "alt", "numpadenter": "padenter", "appskey": "cmd"]
        for i in 1...20 { m["f\(i)"] = "f\(i)" }
        return m
    }()
    static let MOD_PREFIX: [Character: String] = ["^": "ctrl", "!": "alt", "+": "shift", "#": "cmd"]
    static let MODNAMES: Set<String> = ["ctrl", "alt", "shift", "cmd"]

    // A character on the US keyboard that is a plain key, and whether shift is held to get it.
    static let SHIFTED: [Character: String] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
                                               "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
                                               "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",",
                                               ">": ".", "?": "/", "~": "`"]
    static let PLAIN: [Character: String] = {
        var m: [Character: String] = [:]
        for c in "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`" { m[c] = String(c) }
        m[" "] = "space"; m["\n"] = "return"; m["\t"] = "tab"
        return m
    }()

    static func charKey(_ c: Character) -> (String, Bool)? {
        if let k = PLAIN[c] { return (k, false) }
        if c.isASCII && c.isUppercase, let k = PLAIN[Character(c.lowercased())] { return (k, true) }
        if let k = SHIFTED[c] { return (k, true) }
        return nil
    }

    struct SendAction {
        var kind: String                    // key text down up wheel click
        var mods: [String] = []; var key = ""; var times = 1; var text = ""; var dir = ""
        var x: Double? = nil; var y: Double? = nil; var button = "left"
    }

    static func parseSend(_ str: String, raw rawIn: Bool = false) throws -> [SendAction] {
        var out: [SendAction] = [], pending: [String] = [], held = Set<String>(), raw = rawIn
        let s = Array(str), n = s.count
        var i = 0
        func addMods() -> [String] {
            var mods = Array(held)
            for m in pending where !mods.contains(m) { mods.append(m) }
            pending = []
            return mods.sorted()
        }
        func key(_ name: String, _ times: Int) { out.append(SendAction(kind: "key", mods: addMods(), key: name, times: times)) }
        func text(_ c: String) {
            if pending.isEmpty && held.isEmpty {
                if let last = out.last, last.kind == "text" { out[out.count - 1].text += c }
                else { out.append(SendAction(kind: "text", text: c)) }
            } else if let ch = c.first, c.count == 1, let (k, shift) = charKey(ch) {
                if shift { pending.append("shift") }
                key(k, 1)
            } else {
                pending = []
                out.append(SendAction(kind: "text", text: c))
            }
        }
        while i < n {
            let c = s[i]
            if raw {
                text(String(c)); i += 1
            } else if let m = MOD_PREFIX[c] {
                pending.append(m); i += 1
            } else if c == "{" {
                var j = i + 1
                while j < n && s[j] != "}" { j += 1 }
                if j == i + 1 { j = i + 2; while j < n && s[j] != "}" { j += 1 } }       // {}} is a literal }
                if j >= n { throw fail(0, "a { in Send that never closes") }
                let inner = String(s[(i + 1)..<j])
                i = j + 1
                var name = inner, arg: String? = nil
                if let sp = inner.firstIndex(where: { $0.isWhitespace }), sp != inner.startIndex {
                    let rest = inner[sp...].drop(while: { $0.isWhitespace })
                    if !rest.isEmpty { name = String(inner[..<sp]); arg = String(rest) }
                }
                let lname = name.lowercased()
                if name.count == 1 && arg == nil {
                    text(name)                                               // {!} {^} {{} {}} literals
                } else if lname == "raw" || lname == "text" {
                    raw = true
                } else if lname == "click" {
                    let a = arg ?? "", la = a.lowercased()
                    let nums = a.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
                    let button = la.contains("right") ? "right" : (la.contains("middle") ? "middle" : "left")
                    var act = SendAction(kind: "click", times: 1, button: button)
                    // {Click x y [n]}: a third number is the count; {Click n} alone is the count
                    if nums.count >= 2 { act.x = Double(nums[0]); act.y = Double(nums[1]); act.times = nums.count >= 3 ? nums[2] : 1 }
                    else if nums.count == 1 { act.times = nums[0] }
                    act.mods = addMods()
                    out.append(act)
                } else if lname.hasPrefix("wheel") {
                    out.append(SendAction(kind: "wheel", mods: addMods(), times: arg.flatMap { number($0) }.map { Int($0) } ?? 1,
                                          dir: String(lname.dropFirst(5))))
                } else {
                    let hsname = AHK_KEYS[lname] ?? (name.count == 1 ? charKey(name.first!)?.0 : nil) ?? lname
                    let larg = arg?.lowercased()
                    if larg == "down" || larg == "up" {
                        if MODNAMES.contains(hsname) { if larg == "down" { held.insert(hsname) } else { held.remove(hsname) } }
                        out.append(SendAction(kind: larg!, mods: addMods(), key: hsname))
                    } else {
                        let times = arg.flatMap { number($0) }.map { Int($0) } ?? 1
                        if name.count == 1 && AHK_KEYS[lname] == nil {
                            let ck = charKey(name.first!)
                            if ck?.1 == true { pending.append("shift") }
                            key(ck?.0 ?? name, times)
                        } else { key(hsname, times) }
                    }
                }
            } else {
                if !pending.isEmpty {
                    if let (k, shift) = charKey(c) {
                        if shift { pending.append("shift") }
                        key(k, 1)
                    } else { pending = []; text(String(c)) }
                } else { text(String(c)) }
                i += 1
            }
        }
        return out
    }

    // MARK: the command list, for the editor's suggestions and the documentation

    static let commands: [(name: String, shape: String, help: String)] = [
        ("Click",          "Click x, y [, \"Right\" | \"Middle\", count]", "Move the mouse to x, y and click there. Click alone clicks where the mouse is."),
        ("MouseMove",      "MouseMove x, y",                          "Move the mouse to x, y."),
        ("MouseClick",     "MouseClick \"Left\", x, y [, count]",       "Click a button at x, y."),
        ("MouseClickDrag", "MouseClickDrag \"Left\", x1, y1, x2, y2",  "Press at x1, y1, drag to x2, y2, release."),
        ("MouseGetPos",    "MouseGetPos &x, &y",                      "Put the mouse position into x and y."),
        ("Send",           "Send \"text or ^c or {Enter}\"",            "Type text and keys. ^ Ctrl, ! Option, + Shift, # Command; {Enter} {Tab} {Esc} {F5} {Up}; {Ctrl down} holds."),
        ("SendText",       "SendText \"text\"",                         "Type the text exactly, with no special meaning for ^ ! + # { }."),
        ("Sleep",          "Sleep milliseconds",                      "Wait. Sleep 500 is half a second."),
        ("ImageSearch",    "ImageSearch &x, &y, 0, 0, 0, 0, \"button.png\"", "Look for the picture on the screen. Returns 1 and sets x, y to its top left corner, or 0."),
        ("ClickImage",     "ClickImage \"button.png\" [, seconds to wait]", "Find the picture on the screen and click its centre. Waits up to the seconds given. Returns 1 or 0."),
        ("WaitImage",      "WaitImage \"button.png\", seconds",         "Wait until the picture is on the screen. Returns 1, or 0 when the time runs out."),
        ("FindImage",      "FindImage(\"button.png\")",                 "The centre of the picture as [x, y], or 0 when it is not on screen."),
        ("ImageExist",     "ImageExist(\"button.png\")",                "1 when the picture is on the screen now, else 0."),
        ("PixelGetColor",  "PixelGetColor(x, y)",                     "The colour at x, y as \"0xRRGGBB\"."),
        ("WinActivate",    "WinActivate \"Google Chrome\"",             "Bring the app with that name to the front."),
        ("WinExist",       "WinExist(\"Google Chrome\")",               "1 when an app or window with that name is open."),
        ("MenuSelect",     "MenuSelect \"DaVinci Resolve\", , \"Fairlight\", \"Presets Library\"", "Press a menu item of that app by its names (… or ... both match)."),
        ("WinGetPos",      "WinGetPos &x, &y, &w, &h, \"DaVinci Resolve\"", "The window's top left corner and size: click relative to it."),
        ("Recalibrate",    "Recalibrate \"macro name\"",              "Move that macro's clicks to where its window is now (compares the stored view with a new picture)."),
        ("WinWaitActive",  "WinWaitActive \"Google Chrome\", , seconds", "Bring the app forward and wait for it."),
        ("Run",            "Run \"https://example.com\" or Run \"Safari\"", "Open an address, a file or an app."),
        ("MsgBox",         "MsgBox \"text\"",                           "Show a line at the bottom of the screen, for a moment."),
        ("ToolTip",        "ToolTip \"text\"",                          "Show a line at the bottom of the screen."),
        ("ExitApp",        "ExitApp",                                 "Stop the macro here."),
        ("Loop",           "Loop 5 {  }",                             "Repeat the block 5 times. A_Index counts from 1. Loop alone repeats until Break."),
        ("While",          "While x < 10 {  }",                       "Repeat while the condition holds."),
        ("For",            "For i, v in [1, 2, 3] {  }",              "Walk an array or a Map."),
        ("If",             "If x = 1 {  } Else {  }",                 "Do the block when the condition holds."),
        ("Break",          "Break",                                   "Leave the loop."),
        ("Continue",       "Continue",                                "Next turn of the loop."),
        ("Return",         "Return value",                            "Leave the function with a value."),
        ("Global",         "Global name",                             "Inside a function: write to the script-wide variable."),
        ("StrLen",         "StrLen(text)",                            "How many characters."),
        ("SubStr",         "SubStr(text, start, length)",             "Part of the text. Start counts from 1; negative counts from the end."),
        ("InStr",          "InStr(haystack, needle)",                 "Where needle is in haystack, or 0."),
        ("StrReplace",     "StrReplace(text, from, to)",              "Replace every from with to."),
        ("StrSplit",       "StrSplit(text, \",\")",                     "Cut the text into an array."),
        ("StrUpper",       "StrUpper(text)",                          "UPPER CASE."),
        ("StrLower",       "StrLower(text)",                          "lower case."),
        ("Trim",           "Trim(text)",                              "Without the spaces at both ends."),
        ("Format",         "Format(\"{1} and {2}\", a, b)",             "Fill the braces with the values."),
        ("Round",          "Round(number, decimals)",                 "Round the number."),
        ("Floor",          "Floor(number)",                           "Round down."),
        ("Ceil",           "Ceil(number)",                            "Round up."),
        ("Abs",            "Abs(number)",                             "Without the sign."),
        ("Mod",            "Mod(a, b)",                               "The remainder of a / b."),
        ("Min",            "Min(a, b, ...)",                          "The smallest."),
        ("Max",            "Max(a, b, ...)",                          "The largest."),
        ("Random",         "Random(min, max)",                        "A random number between the two."),
        ("Sqrt",           "Sqrt(number)",                            "Square root."),
        ("IsNumber",       "IsNumber(value)",                         "1 when the value is a number."),
        ("Type",           "Type(value)",                             "\"Integer\", \"Float\", \"String\", \"Array\" or \"Map\"."),
        ("Chr",            "Chr(65)",                                 "The character with that code."),
        ("Ord",            "Ord(\"A\")",                                "The code of the first character."),
        ("Array",          "Array(1, 2, 3) or [1, 2, 3]",             "A list. arr.Length, arr.Push(v), arr.Pop(), arr[1]."),
        ("Map",            "Map(\"key\", value)",                       "A dictionary. m[\"key\"], m.Has(\"key\"), m.Count, m.Delete(\"key\")."),
        ("FileExist",      "FileExist(\"/path/file\")",                 "1 when the file is there."),
        ("FileRead",       "FileRead(\"/path/file\")",                  "The whole file as text."),
        ("FileAppend",     "FileAppend \"text\", \"/path/file\"",         "Add text to the end of a file."),
    ]
    // the A_ variables the language knows, for the editor's suggestions; variableHelp says what each one is
    static var variables: [String] { variableHelp.map { $0.name } }
    static let variableHelp: [(name: String, help: String)] = [
        ("A_Index",        "The turn of the current loop, from 1."),
        ("A_ScreenWidth",  "Width of the main screen in points."),
        ("A_ScreenHeight", "Height of the main screen in points."),
        ("A_Clipboard",    "The clipboard. Read it or assign to it."),
        ("A_TickCount",    "Milliseconds since the macro started."),
        ("A_Now",          "The time as YYYYMMDDHH24MISS."),
        ("A_MouseX",       "Where the mouse is, x."),
        ("A_MouseY",       "Where the mouse is, y."),
        ("A_Speed",        "The speed setting of the player."),
    ]
    static let keyNames: [String] = ["Enter", "Tab", "Esc", "Space", "BS", "Del", "Up", "Down", "Left", "Right", "Home", "End",
                                     "PgUp", "PgDn", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
                                     "Ctrl down", "Ctrl up", "Alt down", "Alt up", "Shift down", "Shift up", "Cmd down", "Cmd up",
                                     "WheelDown 3", "WheelUp 3", "Click 100 200", "Text"]

    // MARK: run

    // RUN a parsed script against a host. Returns ok, or not and "line N: msg" with the line.
    static func run(_ prog: Program, host: ScriptHost, speed: Double) -> (ok: Bool, message: String?, line: Int?) {
        let I = Interp(host: host, speed: speed)
        // functions are known before the first line runs, wherever they are written
        for st in prog.body where st.type == "func" { I.funcs[st.name.lowercased()] = st }
        do {
            try I.execBlock(prog, I.newScope(nil, false))
            return (true, nil, nil)
        } catch Flow.ret { return (true, nil, nil) }
        catch Flow.brk { return (false, "Break or Continue outside a loop", nil) }
        catch Flow.cont { return (false, "Break or Continue outside a loop", nil) }
        catch let e as ScriptError { return (false, e.text, e.line) }
        catch is ScriptStopped { return (false, "stopped", nil) }
        catch { return (false, "\(error)", nil) }
    }

    enum Flow: Error { case brk, cont, ret }

    final class Scope {
        var vars: [String: Value] = [:]
        let parent: Scope?; let isFunc: Bool
        var globalsDeclared = Set<String>()
        var loopIndex: Int
        var returnValue: Value?
        init(_ parent: Scope?, _ isFunc: Bool) { self.parent = parent; self.isFunc = isFunc; loopIndex = parent?.loopIndex ?? 0 }
    }

    // MARK: the interpreter

    final class Interp {
        let host: ScriptHost; let speed: Double
        var globals: [String: Value] = [:]
        var funcs: [String: Node] = [:]
        var held = Set<String>()
        var steps = 0
        let startAt: Double
        init(host: ScriptHost, speed: Double) { self.host = host; self.speed = speed; startAt = host.now() }

        func heldMods() -> [String] { held.sorted() }
        func mergeMods(_ mods: [String]) -> [String] { held.union(mods).sorted() }

        func newScope(_ parent: Scope?, _ isFunc: Bool) -> Scope { Scope(parent, isFunc) }

        func builtinVar(_ name: String) -> Value? {
            switch name.lowercased() {
            case "a_screenwidth": return .num(host.screen().0)
            case "a_screenheight": return .num(host.screen().1)
            case "a_clipboard": return .str(host.clipboard())
            case "a_tickcount": return .num(((host.now() - startAt) * 1000).rounded(.down))
            case "a_now":
                let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
                return .str(f.string(from: Date()))
            case "a_mousex": return .num(Double(host.mousePos().0))
            case "a_mousey": return .num(Double(host.mousePos().1))
            case "a_speed": return .num(speed)
            case "a_space": return .str(" ")
            case "a_tab": return .str("\t")
            default: return nil
            }
        }

        // every 400 steps the host gets a chance to stop us
        func tick() throws {
            steps += 1
            if steps % 400 == 0 { try host.sleep(0) }
        }

        func lookup(_ scope: Scope, _ name: String) -> Value? {
            let l = name.lowercased()
            var s: Scope? = scope
            while let c = s {
                if let v = c.vars[l] { return v }
                if c.isFunc { break }
                s = c.parent
            }
            return globals[l]
        }

        func assign(_ scope: Scope, _ name: String, _ value: Value?) {
            let l = name.lowercased()
            if l == "a_clipboard" { host.setClipboard(toStr(value)); return }
            // find the function scope we are in
            var s: Scope? = scope, fscope: Scope? = nil
            while let c = s { if c.isFunc { fscope = c; break }; s = c.parent }
            guard let fs = fscope else { globals[l] = value; return }
            if fs.globalsDeclared.contains(l) { globals[l] = value; return }
            // an existing local in this function (any block) is updated in place
            s = scope
            while let c = s {
                if c.vars[l] != nil { c.vars[l] = value; return }
                if c.isFunc { break }
                s = c.parent
            }
            fs.vars[l] = value
        }

        func makeRef(_ scope: Scope, _ name: String) -> Ref {
            Ref(name, { [unowned self] in
                let v = self.lookup(scope, name)
                if case .ref(let r)? = v { return r.get() }
                return v
            }, { [unowned self] v in self.assign(scope, name, v) })
        }

        func callFunction(_ name: String, _ args: [Value?], _ line: Int, _ scope: Scope) throws -> Value {
            let l = name.lowercased()
            if let f = funcs[l] {
                let fs = newScope(nil, true)
                fs.loopIndex = 0
                for (i, prm) in f.params.enumerated() {
                    var v: Value? = i < args.count ? args[i] : nil
                    if prm.byref {
                        guard case .ref? = v else { throw fail(line, name + ": parameter " + prm.name + " needs &variable") }
                        fs.vars[prm.name.lowercased()] = v      // a ref stays a ref; reads and writes go through it
                    } else {
                        if case .ref(let r)? = v { v = r.get() }
                        if v == nil, let d = prm.def { v = try evalExpr(d, fs) }
                        fs.vars[prm.name.lowercased()] = v ?? .str("")
                    }
                }
                do { try execBlock(f.bodyBlock!, fs); return .str("") }
                catch Flow.ret { return fs.returnValue ?? .str("") }
            }
            if let pf = Interp.PURE[l] {
                let plain: [Value?] = args.map { if case .ref(let r)? = $0 { return r.get() }; return $0 }
                return try pf(plain, line)
            }
            if let hf = Interp.HOSTFN[l] {
                return try hf(self, args, line) ?? .str("")
            }
            throw fail(line, "no command or function called " + name)
        }

        func evalArgs(_ args: [Node], _ scope: Scope) throws -> [Value?] {
            try args.map { a in
                if a.type == "ref" { return .ref(makeRef(scope, a.name)) }
                if a.type == "empty" { return nil }
                return try evalExpr(a, scope)
            }
        }

        func memberOf(_ obj: Value, _ name: String, _ line: Int) throws -> Value {
            let l = name.lowercased()
            switch obj {
            case .arr(let a): if l == "length" { return .num(Double(a.n)) }; throw fail(line, "arrays have no ." + name)
            case .map(let m): if l == "count" { return .num(Double(m.keys.count)) }; throw fail(line, "maps have no ." + name)
            case .str(let s): if l == "length" { return .num(Double(s.count)) }
            default: break
            }
            throw fail(line, "no ." + name + " on " + toStr(obj))
        }

        func methodOf(_ obj: Value, _ name: String, _ args: [Value?], _ line: Int) throws -> Value {
            let l = name.lowercased()
            if case .arr(let a) = obj {
                switch l {
                case "push": for v in args { a.items.append(v) }; return .num(Double(a.n))
                case "pop": let v = a.items.popLast() ?? nil; return v ?? .str("")
                case "has": let i = try toNum(args.first ?? nil, line); return .num(i >= 1 && i <= Double(a.n) ? 1 : 0)
                case "insertat":
                    let i = Int(try toNum(args.first ?? nil, line))
                    a.items.insert(args.count > 1 ? args[1] : nil, at: max(0, min(a.n, i - 1))); return .str("")
                case "removeat":
                    let i = Int(try toNum(args.first ?? nil, line))
                    guard i >= 1 && i <= a.n else { return .str("") }
                    return a.items.remove(at: i - 1) ?? .str("")
                case "clone": return .arr(ArrBox(a.items))
                default: throw fail(line, "arrays have no ." + name + "()")
                }
            }
            if case .map(let m) = obj {
                switch l {
                case "has": return .num(m.data[toStr(args.first ?? nil)] != nil ? 1 : 0)
                case "delete":
                    let k = toStr(args.first ?? nil); let v = m.data.removeValue(forKey: k)
                    m.keys.removeAll { $0 == k }
                    return v ?? .str("")
                case "get":
                    if let v = m.data[toStr(args.first ?? nil)] { return v }
                    return (args.count > 1 ? args[1] : nil) ?? .str("")
                case "set":
                    var i = 0
                    while i + 1 < args.count {
                        let k = toStr(args[i])
                        if m.data[k] == nil { m.keys.append(k) }
                        m.data[k] = args[i + 1] ?? .str("")
                        i += 2
                    }
                    return obj
                case "clear": m.data = [:]; m.keys = []; return .str("")
                default: throw fail(line, "maps have no ." + name + "()")
                }
            }
            throw fail(line, "no ." + name + "() on " + toStr(obj))
        }

        func indexGet(_ obj: Value, _ idx: Value, _ line: Int) throws -> Value {
            switch obj {
            case .arr(let a):
                var i = Int(try toNum(idx, line, "the index"))
                if i < 0 { i = a.n + i + 1 }
                if i < 1 || i > a.n { throw fail(line, "index \(toStr(idx)) is outside the array (it has \(a.n))") }
                return a.items[i - 1] ?? .str("")
            case .map(let m):
                guard let v = m.data[toStr(idx)] else { throw fail(line, "the map has no key \"\(toStr(idx))\"") }
                return v
            case .str(let s):
                let i = Int(try toNum(idx, line))
                return .str(luaSub(s, i, i))
            default: throw fail(line, "cannot index " + toStr(obj))
            }
        }

        func indexSet(_ obj: Value, _ idx: Value, _ value: Value, _ line: Int) throws {
            switch obj {
            case .arr(let a):
                var i = Int(try toNum(idx, line, "the index"))
                if i < 0 { i = a.n + i + 1 }
                if i < 1 || i > a.n + 1 { throw fail(line, "index \(toStr(idx)) is outside the array") }
                if i > a.n { a.items.append(value) } else { a.items[i - 1] = value }
            case .map(let m):
                let k = toStr(idx)
                if m.data[k] == nil { m.keys.append(k) }
                m.data[k] = value
            default: throw fail(line, "cannot assign into " + toStr(obj))
            }
        }

        func arith(_ op: String, _ a: Value?, _ b: Value?, _ line: Int) throws -> Value {
            let x = try toNum(a, line, "'\(op)'"), y = try toNum(b, line, "'\(op)'")
            switch op {
            case "+": return .num(x + y)
            case "-": return .num(x - y)
            case "*": return .num(x * y)
            case "/": if y == 0 { throw fail(line, "division by zero") }; return .num(x / y)
            case "//": if y == 0 { throw fail(line, "division by zero") }; return .num((x / y).rounded(.down))
            case "**": return .num(pow(x, y))
            default: throw fail(line, "unknown operator " + op)
            }
        }

        func evalExpr(_ e: Node, _ scope: Scope) throws -> Value {
            try tick()
            switch e.type {
            case "num", "str": return e.value!
            case "var":
                let v = lookup(scope, e.name)
                if case .ref(let r)? = v { return r.get() ?? .str("") }
                if let v = v { return v }
                if let b = builtinVar(e.name) { return b }
                let l = e.name.lowercased()
                if l == "a_index" { return .num(Double(scope.loopIndex)) }
                if funcs[l] != nil || Interp.HOSTFN[l] != nil {
                    // a bare name that is a command: call it with no arguments
                    return try callFunction(e.name, [], e.line, scope)
                }
                return .str("")      // an unset variable is empty, the AutoHotkey way
            case "ref": return .ref(makeRef(scope, e.name))
            case "bin":
                let op = e.op
                if op == "&&" { return .num(try truthy(evalExpr(e.l!, scope)) && truthy(evalExpr(e.r!, scope)) ? 1 : 0) }
                if op == "||" { return .num(try truthy(evalExpr(e.l!, scope)) || truthy(evalExpr(e.r!, scope)) ? 1 : 0) }
                let a = try evalExpr(e.l!, scope), b = try evalExpr(e.r!, scope)
                if op == "." { return .str(toStr(a) + toStr(b)) }
                if ["=", "==", "!=", "<>", "<", ">", "<=", ">="].contains(op) { return .num(try compare(op, a, b, e.line) ? 1 : 0) }
                return try arith(op, a, b, e.line)
            case "un":
                let v = try evalExpr(e.e!, scope)
                if e.op == "-" { return .num(-(try toNum(v, e.line, "'-'"))) }
                return .num(truthy(v) ? 0 : 1)
            case "tern":
                return try truthy(evalExpr(e.c!, scope)) ? evalExpr(e.a!, scope) : evalExpr(e.b!, scope)
            case "call":
                return try callFunction(e.name, evalArgs(e.args, scope), e.line, scope)
            case "index": return try indexGet(evalExpr(e.obj!, scope), evalExpr(e.idx!, scope), e.line)
            case "member": return try memberOf(evalExpr(e.obj!, scope), e.name, e.line)
            case "mcall":
                let obj = try evalExpr(e.obj!, scope)
                return try methodOf(obj, e.name, evalArgs(e.args, scope), e.line)
            case "array": return .arr(ArrBox(try e.items.map { try evalExpr($0, scope) }))
            case "object":
                let m = MapBox()
                for (k, v) in e.pairs { m.keys.append(k); m.data[k] = try evalExpr(v, scope) }
                return .map(m)
            case "postinc", "preinc":
                var cur0 = lookup(scope, e.name)
                var ref: Ref? = nil
                if case .ref(let r)? = cur0 { ref = r; cur0 = r.get() }
                let cur = try toNum(cur0 ?? .num(0), e.line, e.name)
                let new = e.op == "++" ? cur + 1 : cur - 1
                if let r = ref { r.set(.num(new)) } else { assign(scope, e.name, .num(new)) }
                return .num(e.type == "postinc" ? cur : new)
            default: throw fail(e.line, "cannot evaluate " + e.type)
            }
        }

        // a loop body: Break leaves, Continue goes on, anything else passes up
        func loopBody(_ body: Node, _ inner: Scope) throws -> Bool {
            do { try execBlock(body, inner) }
            catch Flow.brk { return false }
            catch Flow.cont {}
            return true
        }

        func execStatement(_ st: Node, _ scope: Scope) throws {
            try tick()
            switch st.type {
            case "nop": return
            case "block": try execBlock(st, newScope(scope, false))
            case "expr": _ = try evalExpr(st.expr!, scope)
            case "assign":
                var value = try evalExpr(st.expr!, scope)
                let target = st.target!
                if st.op != ":=" {
                    var cur: Value?
                    if target.type == "var" {
                        cur = lookup(scope, target.name)
                        if case .ref(let r)? = cur { cur = r.get() }
                    } else { cur = try evalExpr(target, scope) }
                    if st.op == ".=" { value = .str(toStr(cur) + toStr(value)) }
                    else { value = try arith(String(st.op.dropLast()), cur ?? .str(""), value, st.line) }
                }
                if target.type == "var" {
                    if case .ref(let r)? = lookup(scope, target.name) { r.set(value) } else { assign(scope, target.name, value) }
                } else if target.type == "index" {
                    try indexSet(evalExpr(target.obj!, scope), evalExpr(target.idx!, scope), value, st.line)
                } else if target.type == "member" {
                    let obj = try evalExpr(target.obj!, scope)
                    if case .map = obj { try indexSet(obj, .str(target.name), value, st.line) }
                    else { throw fail(st.line, "cannot assign ." + target.name) }
                }
            case "decl":
                var fs: Scope? = scope
                while let c = fs, !c.isFunc { fs = c.parent }
                for name in st.names {
                    let l = name.lowercased()
                    if st.scope == "global", let f = fs { f.globalsDeclared.insert(l) }
                    if let initE = st.inits[name] {
                        let v = try evalExpr(initE, scope)
                        if st.scope == "global" { globals[l] = v } else { scope.vars[l] = v }
                    } else if st.scope != "global" && scope.vars[l] == nil {
                        scope.vars[l] = .str("")
                    }
                }
            case "if":
                if try truthy(evalExpr(st.cond!, scope)) { try execBlock(st.thenb!, newScope(scope, false)) }
                else if let e = st.elseb { try execBlock(e, newScope(scope, false)) }
            case "while":
                var i = 0
                while try truthy(evalExpr(st.cond!, scope)) {
                    i += 1
                    let inner = newScope(scope, false); inner.loopIndex = i
                    if try !loopBody(st.bodyBlock!, inner) { break }
                }
            case "loop":
                let count: Double? = try st.count.map { try toNum(evalExpr($0, scope), st.line, "Loop") }
                var i = 0
                while count == nil || Double(i) < count! {
                    i += 1
                    let inner = newScope(scope, false); inner.loopIndex = i
                    if try !loopBody(st.bodyBlock!, inner) { break }
                    if let u = st.until, try truthy(evalExpr(u, inner)) { break }
                }
            case "for":
                let coll = try evalExpr(st.iter!, scope)
                var list: [(Value, Value?)] = []
                switch coll {
                case .arr(let a): for (i, v) in a.items.enumerated() { list.append((.num(Double(i + 1)), v)) }
                case .map(let m): for k in m.keys { list.append((.str(k), m.data[k])) }
                case .str(let s): for (i, c) in s.enumerated() { list.append((.num(Double(i + 1)), .str(String(c)))) }
                default: throw fail(st.line, "For needs an array, a map or a string")
                }
                for (i, pr) in list.enumerated() {
                    let inner = newScope(scope, false); inner.loopIndex = i + 1
                    if let v = st.v {
                        inner.vars[st.k.lowercased()] = pr.0; inner.vars[v.lowercased()] = pr.1
                    } else {
                        // For v in array gives values; For k in map gives keys; For i in "text" gives the index (as the Lua did)
                        if case .arr = coll { inner.vars[st.k.lowercased()] = pr.1 } else { inner.vars[st.k.lowercased()] = pr.0 }
                    }
                    if try !loopBody(st.bodyBlock!, inner) { break }
                }
            case "break": throw Flow.brk
            case "continue": throw Flow.cont
            case "return":
                var fs: Scope? = scope
                while let c = fs, !c.isFunc { fs = c.parent }
                let v = try st.expr.map { try evalExpr($0, scope) } ?? .str("")
                fs?.returnValue = v
                throw Flow.ret
            case "func": funcs[st.name.lowercased()] = st
            default: throw fail(st.line, "cannot run " + st.type)
            }
        }

        func execBlock(_ block: Node, _ scope: Scope) throws {
            for st in block.body { try execStatement(st, scope) }
        }

        // MARK: built-in functions that need no host: strings and numbers

        typealias Pure = ([Value?], Int) throws -> Value
        static func arg(_ a: [Value?], _ i: Int) -> Value? { i < a.count ? a[i] : nil }

        static let PURE: [String: Pure] = {
            var P: [String: Pure] = [:]
            P["strlen"] = { a, _ in .num(Double(toStr(arg(a, 0)).count)) }
            P["substr"] = { a, line in
                let s = toStr(arg(a, 0)), n = s.count
                var start = Int(try toNum(arg(a, 1), line, "SubStr start"))
                if start < 0 { start = n + start + 1 } else if start == 0 { start = 1 }
                guard let lenV = arg(a, 2) else { return .str(luaSub(s, start, n)) }
                let len = Int(try toNum(lenV, line))
                if len < 0 { return .str(luaSub(s, start, n + len)) }
                return .str(luaSub(s, start, start + len - 1))
            }
            P["instr"] = { a, _ in
                var h = toStr(arg(a, 0)), nd = toStr(arg(a, 1))
                if !truthy(arg(a, 2)) { h = h.lowercased(); nd = nd.lowercased() }
                var start = arg(a, 3).flatMap(numOf).map { Int($0) } ?? 1
                let hc = Array(h), nc = Array(nd)
                if start < 0 { start = max(1, hc.count + start + 1) }
                if start < 1 { start = 1 }
                if nc.isEmpty { return .num(Double(start <= hc.count + 1 ? start : 0)) }
                var i = start - 1
                while i + nc.count <= hc.count {
                    if Array(hc[i..<(i + nc.count)]) == nc { return .num(Double(i + 1)) }
                    i += 1
                }
                return .num(0)
            }
            P["strreplace"] = { a, _ in
                let s = toStr(arg(a, 0)), from = toStr(arg(a, 1)), to = toStr(arg(a, 2))
                if from.isEmpty { return .str(s) }
                return .str(s.replacingOccurrences(of: from, with: to))
            }
            P["strupper"] = { a, _ in .str(toStr(arg(a, 0)).uppercased()) }
            P["strlower"] = { a, _ in .str(toStr(arg(a, 0)).lowercased()) }
            P["trim"] = { a, _ in .str(toStr(arg(a, 0)).trimmingCharacters(in: .whitespacesAndNewlines)) }
            P["ltrim"] = { a, _ in .str(String(toStr(arg(a, 0)).drop(while: { $0.isWhitespace }))) }
            P["rtrim"] = { a, _ in
                var s = toStr(arg(a, 0)); while s.last?.isWhitespace == true { s.removeLast() }; return .str(s)
            }
            P["strsplit"] = { a, _ in
                let s = toStr(arg(a, 0)), sep = arg(a, 1).map { toStr($0) } ?? ""
                if sep.isEmpty { return .arr(ArrBox(s.map { .str(String($0)) })) }
                return .arr(ArrBox(s.components(separatedBy: sep).map { .str($0) }))
            }
            P["format"] = { a, _ in
                let fmt = toStr(arg(a, 0))
                var out = "", idx = 1
                var rest = Substring(fmt)
                while let open = rest.firstIndex(of: "{") {
                    out += rest[..<open]
                    guard let close = rest[open...].firstIndex(of: "}") else { out += rest[open...]; rest = ""; break }
                    let inner = rest[rest.index(after: open)..<close]
                    let digits = inner.prefix(while: { $0.isASCII && $0.isNumber })
                    let spec = String(inner.dropFirst(digits.count))
                    let i = Int(digits) ?? idx
                    idx = i + 1
                    let v = arg(a, i)
                    out += formatOne(v, spec)
                    rest = rest[rest.index(after: close)...]
                }
                out += rest
                return .str(out)
            }
            P["abs"] = { a, line in .num(abs(try toNum(arg(a, 0), line))) }
            P["round"] = { a, line in
                let x = try toNum(arg(a, 0), line), n = try arg(a, 1).map { try toNum($0, line) } ?? 0
                let m = pow(10, n)
                return .num((x * m + 0.5).rounded(.down) / m)
            }
            P["floor"] = { a, line in .num(try toNum(arg(a, 0), line).rounded(.down)) }
            P["ceil"] = { a, line in .num(try toNum(arg(a, 0), line).rounded(.up)) }
            P["integer"] = { a, line in .num(try toNum(arg(a, 0), line).rounded(.down)) }
            P["number"] = { a, line in .num(try toNum(arg(a, 0), line)) }
            P["string"] = { a, _ in .str(toStr(arg(a, 0))) }
            P["mod"] = { a, line in .num(fmod(try toNum(arg(a, 0), line), try toNum(arg(a, 1), line))) }
            P["min"] = { a, line in var m = try toNum(arg(a, 0), line); for v in a.dropFirst() { m = min(m, try toNum(v, line)) }; return .num(m) }
            P["max"] = { a, line in var m = try toNum(arg(a, 0), line); for v in a.dropFirst() { m = max(m, try toNum(v, line)) }; return .num(m) }
            P["sqrt"] = { a, line in .num(sqrt(try toNum(arg(a, 0), line))) }
            P["random"] = { a, line in
                let lo = try arg(a, 0).map { try toNum($0, line) } ?? 0, hi = try arg(a, 1).map { try toNum($0, line) } ?? 1
                if lo == lo.rounded(.down) && hi == hi.rounded(.down) && arg(a, 0) != nil && arg(a, 1) != nil && lo <= hi {
                    return .num(Double(Int.random(in: Int(lo)...Int(hi))))
                }
                return .num(lo + Double.random(in: 0..<1) * (hi - lo))
            }
            P["isnumber"] = { a, _ in .num(isNumeric(arg(a, 0)) ? 1 : 0) }
            P["isinteger"] = { a, _ in
                guard let d = numOf(arg(a, 0)) else { return .num(0) }
                return .num(d == d.rounded(.down) ? 1 : 0)
            }
            P["type"] = { a, _ in
                switch arg(a, 0) {
                case .num(let d)?: return .str(d == d.rounded(.down) ? "Integer" : "Float")
                case .arr?: return .str("Array")
                case .map?: return .str("Map")
                default: return .str("String")
                }
            }
            P["chr"] = { a, line in
                let c = Int(try toNum(arg(a, 0), line).rounded(.down))
                return .str(UnicodeScalar(UInt32(max(0, c))).map { String(Character($0)) } ?? "")
            }
            P["ord"] = { a, _ in .num(Double(toStr(arg(a, 0)).unicodeScalars.first?.value ?? 0)) }
            P["array"] = { a, _ in .arr(ArrBox(a)) }
            P["map"] = { a, _ in
                let m = MapBox()
                var i = 0
                while i + 1 < a.count {
                    let k = toStr(a[i])
                    if m.data[k] == nil { m.keys.append(k) }
                    m.data[k] = a[i + 1] ?? .str("")
                    i += 2
                }
                return .map(m)
            }
            return P
        }()

        // MARK: host commands: what the interpreter asks the host for

        typealias HostFn = (Interp, [Value?], Int) throws -> Value?

        func setRef(_ r: Value?, _ v: Value, _ line: Int) throws {
            guard case .ref(let ref)? = r else { throw fail(line, "expected &variable") }
            ref.set(v)
        }
        static func optNum(_ v: Value?, _ line: Int, _ def: Double?) throws -> Double? {
            if v == nil { return def }
            if case .str("")? = v { return def }
            return try toNum(v, line)
        }
        static func buttonName(_ v: Value?) -> String {
            let b = v.map { toStr($0).lowercased() } ?? "left"
            switch b { case "r": return "right"; case "m": return "middle"; case "l", "": return "left"; default: return b }
        }

        // Click x, y  ·  Click x, y, "Right"  ·  Click "100 200 Right 2"  ·  Click "Right"
        struct ClickOpts { var button = "left"; var times = 1; var updown: String?; var x: Double?; var y: Double? }
        static func clickOptions(_ args: [Value?], _ line: Int) throws -> ClickOpts {
            var words: [String] = []
            for v in args {
                if case .str(let s)? = v { words += s.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                else if let v = v { words.append(toStr(v)) }
            }
            var o = ClickOpts(), nums: [Double] = []
            for w in words {
                switch w.lowercased() {
                case "right", "r": o.button = "right"
                case "middle", "m": o.button = "middle"
                case "left", "l": o.button = "left"
                case "down", "d": o.updown = "down"
                case "up", "u": o.updown = "up"
                case "rel", "relative": break
                default:
                    guard let n = number(w) else { throw fail(line, "Click does not understand '\(w)'") }
                    nums.append(n)
                }
            }
            if nums.count >= 2 { o.x = nums[0]; o.y = nums[1]; o.times = nums.count > 2 ? Int(nums[2]) : 1 }
            else if nums.count == 1 { o.times = Int(nums[0]) }
            return o
        }

        func doSend(_ str: String, _ line: Int, raw: Bool) throws {
            let actions: [SendAction]
            do { actions = try parseSend(str, raw: raw) }
            catch let e as ScriptError { throw ScriptError(line: e.line == 0 ? line : e.line, msg: e.msg) }
            for act in actions {
                switch act.kind {
                case "key":
                    let mods = mergeMods(act.mods)
                    for _ in 0..<max(0, act.times) { try host.key(mods, act.key) }
                case "text":
                    if !held.isEmpty {
                        for c in act.text {
                            if let (k, shift) = charKey(c) { try host.key(mergeMods(shift ? ["shift"] : []), k) }
                            else { try host.type(String(c)) }
                        }
                    } else { try host.type(act.text) }
                case "down", "up":
                    if MODNAMES.contains(act.key) {
                        if act.kind == "down" { held.insert(act.key) } else { held.remove(act.key) }
                    } else { try host.keyDownUp(act.key, act.kind == "down", heldMods()) }
                case "wheel": try host.wheel(act.dir, act.times, mergeMods(act.mods))
                case "click": try host.click(act.button, act.x, act.y, act.times, mergeMods(act.mods))
                default: break
                }
            }
        }

        // one steady spinner across a retry loop
        static func findLoop(_ I: Interp, _ file: String, _ secs: Double, _ pause: Double, _ found: (ImageHit) throws -> Void) throws -> Bool {
            let deadline = I.host.now() + secs
            I.host.searchHold(true)
            defer { I.host.searchHold(false) }
            while true {
                if let r = try I.host.imageSearch(file, 0, 0, 0, 0) { try found(r); return true }
                if I.host.now() >= deadline { return false }
                try I.host.sleep(pause)
            }
        }

        static let HOSTFN: [String: HostFn] = {
            var H: [String: HostFn] = [:]
            let a = arg
            H["sleep"] = { I, v, line in try I.host.sleep(try toNum(a(v, 0), line, "Sleep") / 1000); return nil }
            H["mousemove"] = { I, v, line in
                try I.host.mouseMove(try toNum(a(v, 0), line, "MouseMove x"), try toNum(a(v, 1), line, "MouseMove y")); return nil
            }
            H["click"] = { I, v, line in
                let o = try clickOptions(v, line)
                if let ud = o.updown { try I.host.buttonDownUp(o.button, ud == "down", o.x, o.y, I.heldMods()) }
                else { try I.host.click(o.button, o.x, o.y, o.times, I.heldMods()) }
                return nil
            }
            H["mouseclick"] = { I, v, line in
                let button = buttonName(a(v, 0))
                let x = try optNum(a(v, 1), line, nil), y = try optNum(a(v, 2), line, nil)
                let times = Int(try optNum(a(v, 3), line, 1)!)
                var ud = a(v, 5).map { toStr($0).lowercased() }
                if ud == "d" { ud = "down" } else if ud == "u" { ud = "up" }
                if let u = ud, !u.isEmpty { try I.host.buttonDownUp(button, u == "down", x, y, I.heldMods()) }
                else { try I.host.click(button, x, y, times, I.heldMods()) }
                return nil
            }
            H["mouseclickdrag"] = { I, v, line in
                try I.host.drag(buttonName(a(v, 0)), try toNum(a(v, 1), line), try toNum(a(v, 2), line),
                                try toNum(a(v, 3), line), try toNum(a(v, 4), line), I.heldMods())
                return nil
            }
            H["mousegetpos"] = { I, v, line in
                let (x, y) = I.host.mousePos()
                if a(v, 0) != nil { try I.setRef(a(v, 0), .num(Double(x)), line) }
                if a(v, 1) != nil { try I.setRef(a(v, 1), .num(Double(y)), line) }
                return nil
            }
            let send: HostFn = { I, v, line in try I.doSend(toStr(a(v, 0)), line, raw: false); return nil }
            H["send"] = send; H["sendinput"] = send; H["sendevent"] = send; H["sendplay"] = send
            H["sendtext"] = { I, v, line in try I.doSend(toStr(a(v, 0)), line, raw: true); return nil }
            H["imagesearch"] = { I, v, line in
                // ImageSearch &x, &y, x1, y1, x2, y2, "file.png"  -> 1 found, 0 not
                let file = toStr(a(v, 6))
                let r = try I.host.imageSearch(file, try optNum(a(v, 2), line, 0)!, try optNum(a(v, 3), line, 0)!,
                                               try optNum(a(v, 4), line, 0)!, try optNum(a(v, 5), line, 0)!)
                guard let hit = r else { return .num(0) }
                if a(v, 0) != nil { try I.setRef(a(v, 0), .num(hit.x), line) }
                if a(v, 1) != nil { try I.setRef(a(v, 1), .num(hit.y), line) }
                return .num(1)
            }
            H["imageexist"] = { I, v, _ in .num(try I.host.imageSearch(toStr(a(v, 0)), 0, 0, 0, 0) != nil ? 1 : 0) }
            H["findimage"] = { I, v, _ in
                // FindImage("file.png") -> [centreX, centreY] or 0
                guard let r = try I.host.imageSearch(toStr(a(v, 0)), 0, 0, 0, 0) else { return .num(0) }
                return .arr(ArrBox([.num(r.x + (r.w / 2).rounded(.down)), .num(r.y + (r.h / 2).rounded(.down))]))
            }
            H["waitimage"] = { I, v, line in
                // WaitImage "file.png", seconds  -> 1 when it appeared, 0 on time out
                .num(try findLoop(I, toStr(a(v, 0)), try optNum(a(v, 1), line, 10)!, 0.4) { _ in } ? 1 : 0)
            }
            H["clickimage"] = { I, v, line in
                // ClickImage "file.png" [, seconds to wait] [, "Right"]  -> 1 clicked, 0 not found
                let button = a(v, 2).map { toStr($0).lowercased() } ?? "left"
                return .num(try findLoop(I, toStr(a(v, 0)), try optNum(a(v, 1), line, 0)!, 0.4) { r in
                    try I.host.click(button, r.x + (r.w / 2).rounded(.down), r.y + (r.h / 2).rounded(.down), 1, I.heldMods())
                } ? 1 : 0)
            }
            H["pixelgetcolor"] = { I, v, line in .str(I.host.pixel(try toNum(a(v, 0), line), try toNum(a(v, 1), line))) }
            H["msgbox"] = { I, v, _ in I.host.say(toStr(a(v, 0)), true); return nil }
            H["tooltip"] = { I, v, _ in I.host.say(toStr(a(v, 0)), false); return nil }
            H["run"] = { I, v, _ in I.host.run(toStr(a(v, 0))); return nil }
            H["winactivate"] = { I, v, _ in .num(I.host.activate(toStr(a(v, 0))) ? 1 : 0) }
            H["menuselect"] = { I, v, line in
                // MenuSelect WinTitle, WinText, "Menu", "Sub1", ... (AutoHotkey v2; WinText is ignored) -> 1 pressed, 0 not found
                var path: [String] = []; var i = 2
                while let x = a(v, i) { path.append(toStr(x)); i += 1 }
                if path.isEmpty { throw ScriptError(line: line, msg: "MenuSelect needs a menu name") }
                if !I.host.menuSelect(toStr(a(v, 0)), path) { throw ScriptError(line: line, msg: "no menu item " + path.joined(separator: " > ")) }
                return nil
            }
            H["wingetpos"] = { I, v, line in
                // WinGetPos &x, &y, &w, &h, WinTitle (AutoHotkey v2): the window's top left and size, in screen points
                guard let r = I.host.winGetPos(toStr(a(v, 4))) else { throw ScriptError(line: line, msg: "no window " + toStr(a(v, 4))) }
                let vals = [r.0, r.1, r.2, r.3]
                for k in 0..<4 where a(v, k) != nil { try I.setRef(a(v, k), .num(vals[k]), line) }
                return nil
            }
            H["recalibrate"] = { I, v, line in
                // Recalibrate "name" (v8): that macro's clicks follow its window to where it is now; returns the summary
                let r = I.host.recalibrate(a(v, 0).map { toStr($0) } ?? "")
                if !r.0 { throw ScriptError(line: line, msg: r.1) }
                return .str(r.1)
            }
            H["winexist"] = { I, v, _ in .num(I.host.winExists(toStr(a(v, 0))) ? 1 : 0) }
            H["winwaitactive"] = { I, v, line in
                let title = toStr(a(v, 0)), deadline = I.host.now() + (try optNum(a(v, 2), line, 10)!)
                while true {
                    if I.host.activate(title) { return .num(1) }
                    if I.host.now() >= deadline { return .num(0) }
                    try I.host.sleep(0.3)
                }
            }
            H["exitapp"] = { _, _, _ in throw Flow.ret }
            H["exit"] = H["exitapp"]
            H["fileexist"] = { I, v, _ in .num(I.host.fileExist(toStr(a(v, 0))) ? 1 : 0) }
            H["fileread"] = { I, v, _ in .str(I.host.fileRead(toStr(a(v, 0)))) }
            H["fileappend"] = { I, v, _ in I.host.fileAppend(toStr(a(v, 0)), toStr(a(v, 1))); return nil }
            for k in ["setdefaultmousespeed", "setmousedelay", "setkeydelay", "coordmode", "sendmode", "setworkingdir",
                      "settitlematchmode", "blockinput"] { H[k] = { _, _, _ in nil } }
            H["keywait"] = { I, _, _ in try I.host.sleep(0.05); return nil }
            return H
        }()
    }

    // Lua's s:sub(i, j) on characters
    static func luaSub(_ s: String, _ i0: Int, _ j0: Int) -> String {
        let c = Array(s), n = c.count
        var i = i0, j = j0
        if i < 0 { i = max(n + i + 1, 1) } else if i == 0 { i = 1 }
        if j < 0 { j = n + j + 1 } else if j > n { j = n }
        if i > j { return "" }
        return String(c[(i - 1)..<j])
    }

    // Format's {n:spec}: the spec is a printf spec after the colon; anything it cannot do falls back to the text
    static func formatOne(_ v: Value?, _ spec: String) -> String {
        guard spec.hasPrefix(":"), spec.count > 1, let conv = spec.last else { return toStr(v) }
        let f = "%" + spec.dropFirst()
        if "dioxXc".contains(conv) {
            guard let d = numOf(v), d == d.rounded(.down), abs(d) < 9e18 else { return toStr(v) }
            return String(format: String(f.dropLast()) + "ll" + String(conv), Int64(d))
        }
        if "feEgGaA".contains(conv) {
            guard let d = numOf(v) else { return toStr(v) }
            return String(format: f, d)
        }
        if conv == "s" { return String(format: String(f.dropLast()) + "@", toStr(v) as NSString) }
        return toStr(v)
    }

    // MARK: a recording as a script

    // Hammerspoon key names to AutoHotkey names for Send.
    static let HS_TO_AHK: [String: String] = {
        var m = ["return": "Enter", "escape": "Esc", "delete": "BS", "forwarddelete": "Del",
                 "tab": "Tab", "space": "Space", "up": "Up", "down": "Down", "left": "Left", "right": "Right",
                 "home": "Home", "end": "End", "pageup": "PgUp", "pagedown": "PgDn", "help": "Ins",
                 "padenter": "NumpadEnter", "capslock": "CapsLock"]
        for i in 1...20 { m["f\(i)"] = "F\(i)" }
        return m
    }()
    static let SEND_SPECIAL: Set<String> = ["^", "!", "+", "#", "{", "}"]
    static let SHIFT_CHAR: [String: Character] = Dictionary(uniqueKeysWithValues: SHIFTED.map { ($0.value, $0.key) })

    // inside Send, the five special characters go in braces; the string quote and backtick are escaped
    static func sendEscape(_ text: String) -> String {
        var out = ""
        for c in text {
            if "^!+#{}".contains(c) { out += "{\(c)}" }
            else if c == "`" { out += "``" }
            else if c == "\"" { out += "`\"" }
            else { out.append(c) }
        }
        return out
    }
    static func strEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "``").replacingOccurrences(of: "\"", with: "`\"")
            .replacingOccurrences(of: "\n", with: "`n").replacingOccurrences(of: "\t", with: "`t")
    }

    static func modPrefix(_ mods: [String]?) -> (String, Set<String>) {
        let has = Set(mods ?? [])
        var s = ""
        if has.contains("ctrl") { s += "^" }
        if has.contains("alt") { s += "!" }
        if has.contains("shift") { s += "+" }
        if has.contains("cmd") { s += "#" }
        return (s, has)
    }

    private static func r(_ v: Double?) -> Int { Int(((v ?? 0) + 0.5).rounded(.down)) }

    // events (as the recorder writes them) -> script text. keyNames maps a key code to its Hammerspoon name.
    static func fromEvents(_ events: [RecEvent], keyNames: [Int: String], header: [String]) -> String {
        enum Piece { case ch(String), raw(String) }
        var lines = header.map { "; " + $0 }
        var lastT = 0.0
        var textRun: [Piece]? = nil
        func flushText() {
            if let run = textRun, !run.isEmpty {
                let out = run.map { p -> String in if case .raw(let s) = p { return s }; if case .ch(let c) = p { return sendEscape(c) }; return "" }
                lines.append("Send \"" + out.joined() + "\"")
            }
            textRun = nil
        }
        let JOINS = ["return": "{Enter}", "tab": "{Tab}", "delete": "{BS}", "forwarddelete": "{Del}"]
        func gap(_ t: Double) {
            var ms = Int((t - lastT) * 1000 + 0.5)
            if ms >= 20 {
                ms = Int((Double(ms) / 10 + 0.5).rounded(.down)) * 10
                lines.append("Sleep \(ms)")
            }
            lastT = t
        }
        let n = events.count
        var i = 0
        var pending = Set<Int>()          // up events already used
        while i < n {
            let ev = events[i], kind = ev.kind
            if pending.contains(i) || kind == "mouseMoved" || kind == "keyUp" {
                i += 1
            } else if kind == "keyDown" {
                let name = keyNames[ev.code ?? -1] ?? "vk\(ev.code ?? 0)"
                var (prefix, has) = modPrefix(ev.mods)
                let special = HS_TO_AHK[name]
                let plainChar: String? = name.count == 1 ? name : (name == "space" ? " " : nil)
                let onlyShift = prefix == "" || prefix == "+"
                let joiner = prefix == "" ? JOINS[name] : nil
                if (plainChar != nil && onlyShift) || joiner != nil {
                    // text: letters with shift are capitals, shifted symbols their symbol; Enter, Tab and the
                    // deletes ride along inside the same Send
                    let c: Piece
                    if let j = joiner { c = .raw(j) }
                    else {
                        var s = plainChar!
                        if has.contains("shift") {
                            if s.count == 1, s.first!.isLowercase { s = s.uppercased() }
                            else if let sc = SHIFT_CHAR[s] { s = String(sc) }
                        }
                        c = .ch(s)
                    }
                    if textRun != nil && (ev.t - lastT) < 1.5 {
                        textRun!.append(c); lastT = ev.t
                    } else {
                        flushText(); gap(ev.t); textRun = [c]
                    }
                } else {
                    flushText(); gap(ev.t)
                    var keyText: String
                    if let sp = special { keyText = "{" + sp + "}" }
                    else if name.count == 1 {
                        keyText = name
                        if has.contains("shift") && name.first!.isLowercase { keyText = name.uppercased(); prefix = prefix.replacingOccurrences(of: "+", with: "") }
                        if SEND_SPECIAL.contains(keyText) { keyText = "{" + keyText + "}" }
                    } else { keyText = "{" + name + "}" }
                    lines.append("Send \"" + prefix + keyText + "\"")
                }
                i += 1
            } else if kind == "leftMouseDown" || kind == "rightMouseDown" || kind == "otherMouseDown" {
                flushText(); gap(ev.t)
                let upKind = kind.replacingOccurrences(of: "Down", with: "Up")
                let dragKind = kind.replacingOccurrences(of: "Down", with: "Dragged")
                var j = i + 1, dragged = false
                var upEv: RecEvent? = nil
                while j < n {
                    let e2 = events[j]
                    if e2.kind == upKind { upEv = e2; break }
                    if e2.kind == dragKind { dragged = true }
                    j += 1
                }
                let button = kind == "leftMouseDown" ? "Left" : (kind == "rightMouseDown" ? "Right" : (ev.button == 2 ? "Middle" : "Right"))
                let (_, has) = modPrefix(ev.mods)
                let AHKMOD = ["ctrl": "Ctrl", "alt": "Alt", "shift": "Shift", "cmd": "Cmd"]
                let holds = ["ctrl", "alt", "shift", "cmd"].filter { has.contains($0) }
                for m in holds { lines.append("Send \"{\(AHKMOD[m]!) down}\"") }
                let x = r(ev.x), y = r(ev.y)
                if let up = upEv, dragged, abs((up.x ?? 0) - (ev.x ?? 0)) > 3 || abs((up.y ?? 0) - (ev.y ?? 0)) > 3 {
                    lines.append("MouseClickDrag \"\(button)\", \(x), \(y), \(r(up.x)), \(r(up.y))")
                    pending.insert(j); lastT = up.t
                } else {
                    // double and triple clicks: the next down within 0.4 s at the same spot
                    var count = 1
                    var k = (upEv != nil ? j : i) + 1
                    var lastUp = upEv
                    while k < n {
                        let e3 = events[k]
                        if e3.kind == kind && (e3.t - (lastUp?.t ?? ev.t)) < 0.4 && abs((e3.x ?? 0) - (ev.x ?? 0)) <= 3 && abs((e3.y ?? 0) - (ev.y ?? 0)) <= 3 {
                            count += 1
                            pending.insert(k)
                            var m = k + 1
                            while m < n && events[m].kind != upKind {
                                if events[m].kind == "mouseMoved" || events[m].kind == dragKind { pending.insert(m) }
                                m += 1
                            }
                            if m < n { pending.insert(m); lastUp = events[m]; k = m + 1 } else { break }
                        } else if e3.kind == "mouseMoved" {
                            k += 1
                        } else { break }
                    }
                    if upEv != nil { pending.insert(j) }
                    if button == "Left" {
                        lines.append(count > 1 ? "Click \(x), \(y), \(count)" : "Click \(x), \(y)")
                    } else {
                        lines.append(count > 1 ? "Click \(x), \(y), \"\(button)\", \(count)" : "Click \(x), \(y), \"\(button)\"")
                    }
                    lastT = lastUp?.t ?? ev.t
                }
                for m in holds.reversed() { lines.append("Send \"{\(AHKMOD[m]!) up}\"") }
                i += 1
            } else if kind == "scrollWheel" {
                flushText(); gap(ev.t)
                var dy = ev.dy ?? 0, dx = ev.dx ?? 0
                var j = i + 1
                while j < n && events[j].kind == "scrollWheel" && (events[j].t - events[j - 1].t) < 0.3 {
                    dy += events[j].dy ?? 0; dx += events[j].dx ?? 0
                    pending.insert(j); lastT = events[j].t
                    j += 1
                }
                lines.append("MouseMove \(r(ev.x)), \(r(ev.y))")
                if abs(dy) >= abs(dx) && dy != 0 {
                    let notches = max(1, Int((abs(dy) / 30 + 0.5).rounded(.down)))
                    lines.append("Send \"{Wheel\(dy > 0 ? "Up" : "Down") \(notches)}\"")
                } else if dx != 0 {
                    let notches = max(1, Int((abs(dx) / 30 + 0.5).rounded(.down)))
                    lines.append("Send \"{Wheel\(dx > 0 ? "Left" : "Right") \(notches)}\"")
                }
                i += 1
            } else {
                i += 1       // dragged, up: consumed above
            }
        }
        flushText()
        return lines.joined(separator: "\n") + "\n"
    }
}
