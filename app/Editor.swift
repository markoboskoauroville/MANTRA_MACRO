// Editor.swift: the script editor (what editor_page was) and the language (docs/SCRIPT.md, what /docs was).
// A plain text view in a monospace face, coloured by a small highlighter; as you type at the start of a line the
// commands are suggested, the likely next one first (after a Click comes a Sleep, after a Sleep a Send or a Click,
// after a WaitImage a Click); inside { the key names; inside the quotes of a picture command the pictures in the
// folder; elsewhere the functions, the A_ variables and the names the script has assigned. A panel on the right lists
// every command with its shape and one line of what it does; click to insert. ⌘S saves, ⌘↩ saves and runs, Check
// parses without running. An error names its line and lights it.
import AppKit

let NEXT: [String: [String]] = [
    "click": ["Sleep", "Send", "Click", "ClickImage", "WaitImage"],
    "mouseclick": ["Sleep", "Send", "Click"],
    "mouseclickdrag": ["Sleep", "Click", "Send"],
    "mousemove": ["Click", "Sleep", "Send"],
    "sleep": ["Click", "Send", "ClickImage", "WaitImage", "Sleep"],
    "send": ["Sleep", "Send", "Click", "ClickImage"],
    "sendtext": ["Sleep", "Send", "Click"],
    "waitimage": ["ClickImage", "Click", "Send", "Sleep"],
    "clickimage": ["Sleep", "WaitImage", "Send", "Click"],
    "winactivate": ["Sleep", "WinWaitActive", "Click", "Send"],
    "winwaitactive": ["Click", "Send", "Sleep"],
    "run": ["Sleep", "WinWaitActive", "WinActivate"],
    "loop": ["Sleep", "ClickImage", "If", "Break"],
    "while": ["Sleep", "Click", "Send"],
    "if": ["Click", "Send", "MsgBox", "Break", "Return"],
    "msgbox": ["Sleep", "Click", "ExitApp"],
    "": ["Click", "Send", "Sleep", "ClickImage", "WaitImage", "MouseMove", "Loop", "If", "WinActivate", "MsgBox"],
]
let SEND_KEYS = ["Enter", "Esc", "Tab", "Space", "BS", "Del", "Up", "Down", "Left", "Right", "Home", "End", "PgUp", "PgDn",
                 "Ins", "NumpadEnter", "CapsLock", "Ctrl down", "Ctrl up", "Alt down", "Alt up", "Shift down", "Shift up",
                 "Cmd down", "Cmd up", "WheelUp", "WheelDown", "WheelLeft", "WheelRight", "LButton", "RButton", "MButton"]
    + (1...20).map { "F\($0)" }
let PICTURE_CMDS = ["imagesearch", "clickimage", "waitimage", "findimage", "imageexist"]
let KEYWORDS = Set(["if", "else", "while", "loop", "for", "in", "break", "continue", "return", "and", "or", "not", "global", "local", "true", "false"])

let INK = NSColor(srgbRed: 0xF2/255.0, green: 0xDD/255.0, blue: 0xB4/255.0, alpha: 1)
let AMBER = NSColor(srgbRed: 0xE8/255.0, green: 0xA3/255.0, blue: 0x3D/255.0, alpha: 1)
let GROUND = NSColor(srgbRed: 0x0B/255.0, green: 0x0D/255.0, blue: 0x10/255.0, alpha: 1)
let CARD = NSColor(srgbRed: 0x14/255.0, green: 0x1A/255.0, blue: 0x21/255.0, alpha: 1)
let BLUE = NSColor(srgbRed: 0.55, green: 0.75, blue: 1, alpha: 1)
let MONO = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

final class EditorWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static var open: [String: EditorWindow] = [:]
    let name: String
    let window: NSWindow
    let text = NSTextView()
    let lcd = NSTextField(labelWithString: "")
    let search = NSSearchField()
    let table = NSTableView()
    var shown: [(name: String, shape: String, help: String)] = []
    var dirty = false
    var completing = false

    static func show(_ name: String) {
        if let w = open[name] { w.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = EditorWindow(name); open[name] = w
        w.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    init(_ name: String) {
        self.name = name
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = name + " · Macro Recorder (Mantra)"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 560, height: 320); window.backgroundColor = GROUND
        window.setFrameAutosaveName("MacroEditor"); if window.frame.origin == .zero { window.center() }
        build()
        let r = Macros.read(name)
        text.string = r.text ?? ""
        highlight()
        say(r.why == "recording" ? "this is a recording shown as a script. Save keeps it as a script."
                                 : "ready. Start typing: the next command is suggested. ⌘S saves, ⌘↩ saves and runs.")
    }

    func button(_ t: String, _ a: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSButton {
        let b = NSButton(title: t, target: self, action: a); b.bezelStyle = .rounded
        b.keyEquivalent = key; b.keyEquivalentModifierMask = mods
        return b
    }
    func build() {
        let ROW: CGFloat = 40
        let content = NSView(); window.contentView = content
        // the bar: name, Save, Save & Run, Stop, Check, Snap, The language, ✕
        let title = NSTextField(labelWithString: name.uppercased()); title.font = .monospacedSystemFont(ofSize: 12, weight: .bold); title.textColor = INK
        let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!,
                         target: self, action: #selector(closeIt)); x.isBordered = false; x.contentTintColor = GREYC
        x.widthAnchor.constraint(equalToConstant: 30).isActive = true; x.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let gap = NSView(); gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [title, gap, button("Save", #selector(save), "s", .command), button("Save & Run", #selector(saveRun), "\r", .command),
                                      button("Stop", #selector(stopRun)), button("Check", #selector(check)), button("Snap a picture", #selector(snapPic)),
                                      button("The language", #selector(docs)), x])
        bar.orientation = .horizontal; bar.spacing = 6; bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
        // the text
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.removeFromSuperview()
        scroll.documentView = text
        text.minSize = NSSize(width: 0, height: 0); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = MONO; text.textColor = INK; text.backgroundColor = CARD; text.insertionPointColor = AMBER
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false; text.allowsUndo = true; text.delegate = self
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.drawsBackground = true; scroll.backgroundColor = CARD; scroll.hasVerticalScroller = true
        // the panel: every command, its shape and what it does; click to insert
        search.placeholderString = "find a command"; search.target = self; search.action = #selector(filter)
        let col = NSTableColumn(identifier: .init("c")); col.resizingMask = .autoresizingMask; table.addTableColumn(col)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.backgroundColor = GROUND
        table.usesAutomaticRowHeights = true; table.target = self; table.action = #selector(insertPicked)
        let ts = NSScrollView(); ts.documentView = table; ts.hasVerticalScroller = true; ts.drawsBackground = false
        let side = NSStackView(views: [search, ts]); side.orientation = .vertical; side.spacing = 6
        side.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        lcd.font = .monospacedSystemFont(ofSize: 11, weight: .regular); lcd.textColor = AMBER; lcd.lineBreakMode = .byTruncatingTail
        let quit = NSButton(title: "", target: NSApp, action: #selector(NSApplication.terminate(_:))); quit.isBordered = false
        quit.attributedTitle = NSAttributedString(string: "QUIT", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: REDC])
        for v in [bar, scroll, side, lcd, quit] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 4), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: ROW),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: lcd.topAnchor, constant: -6),
            side.topAnchor.constraint(equalTo: scroll.topAnchor), side.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 8), side.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            side.widthAnchor.constraint(equalToConstant: 280),
            lcd.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), lcd.trailingAnchor.constraint(equalTo: quit.leadingAnchor, constant: -10),
            lcd.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            quit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), quit.centerYAnchor.constraint(equalTo: lcd.centerYAnchor),
        ])
        filter()
    }

    func say(_ t: String, _ c: NSColor = AMBER) { lcd.stringValue = t; lcd.textColor = c }

    // MARK: the panel

    @objc func filter() {
        let q = search.stringValue.lowercased()
        shown = Script.commands.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.help.lowercased().contains(q) }
        table.reloadData()
    }
    func numberOfRows(in t: NSTableView) -> Int { shown.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let c = shown[row]
        let f = NSTextField(wrappingLabelWithString: "")
        let s = NSMutableAttributedString(string: c.shape, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: INK])
        s.append(NSAttributedString(string: "\n" + c.help, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: GREYC]))
        f.attributedStringValue = s
        return f
    }
    @objc func insertPicked() {
        guard table.clickedRow >= 0 else { return }
        let c = shown[table.clickedRow]
        text.insertText(c.name + " ", replacementRange: text.selectedRange())
        window.makeFirstResponder(text)
    }

    // MARK: saving, running, checking

    @objc func save() {
        let r = Engine.shared.saveScript(name, text.string)
        dirty = !r.ok
        if let w = r.warn { say(w, REDC); if let l = r.line { light(l) } } else { say("saved " + name, GREENC); light(nil) }
    }
    @objc func saveRun() {
        save()
        if case .failure = Script.parse(text.string) { return }
        Engine.shared.runScript(text.string, name)
        say("running " + name, GREENC)
    }
    @objc func stopRun() { Engine.shared.stopAll(); say("stopped") }
    @objc func check() {
        switch Script.parse(text.string) {
        case .success: say("the script reads well", GREENC); light(nil)
        case .failure(let e): say(e.text, REDC); if let l = e.line { light(l) }
        }
    }
    @objc func snapPic() { Engine.shared.snap("") }
    @objc func docs() { DocsWindow.show() }
    @objc func closeIt() { window.performClose(nil) }
    func windowWillClose(_ n: Notification) {
        if dirty { _ = Engine.shared.saveScript(name, text.string) }   // a half-written script is never lost
        EditorWindow.open[name] = nil
    }

    // light the line with the error
    func light(_ line: Int?) {
        highlight()
        guard let line = line else { return }
        let ns = text.string as NSString
        var n = 1, loc = 0
        while n < line && loc < ns.length { loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0))); n += 1 }
        guard loc <= ns.length else { return }
        let r = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
        text.textStorage?.addAttribute(.backgroundColor, value: REDC.withAlphaComponent(0.25), range: r)
        text.scrollRangeToVisible(r)
    }

    // MARK: colour: comments grey, strings green, numbers amber, keywords blue, commands bold, A_ variables blue

    func highlight() {
        guard let st = text.textStorage else { return }
        let s = st.string as NSString, all = NSRange(location: 0, length: s.length)
        st.beginEditing()
        st.setAttributes([.font: MONO, .foregroundColor: INK], range: all)
        let cmds = Set(Script.commands.map { $0.name.lowercased() })
        func paint(_ pattern: String, _ attrs: [NSAttributedString.Key: Any], _ test: ((String) -> Bool)? = nil) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            for m in re.matches(in: st.string, range: all) where test?(s.substring(with: m.range)) ?? true { st.addAttributes(attrs, range: m.range) }
        }
        paint("\\b[A-Za-z_][A-Za-z0-9_]*\\b", [.foregroundColor: BLUE]) { KEYWORDS.contains($0.lowercased()) }
        paint("\\b[A-Za-z_][A-Za-z0-9_]*\\b", [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)]) { cmds.contains($0.lowercased()) }
        paint("\\bA_[A-Za-z0-9_]+\\b", [.foregroundColor: BLUE])
        paint("\\b(0x[0-9A-Fa-f]+|\\d+(\\.\\d+)?)\\b", [.foregroundColor: AMBER])
        paint("\"(?:``|`\"|[^\"\\n])*\"|'(?:``|`'|[^'\\n])*'", [.foregroundColor: GREENC])
        paint("(^|\\s);.*$", [.foregroundColor: GREYC])
        st.endEditing()
        text.typingAttributes = [.font: MONO, .foregroundColor: INK]
    }

    func textDidChange(_ n: Notification) {
        dirty = true
        highlight()
        guard !completing else { return }
        // suggest as he types: at the start of a line after one letter, inside { or a picture's quotes at once
        let ctx = context()
        if ctx.word.count >= 1 || ctx.mode != .other {
            if !suggestions(ctx).isEmpty {
                completing = true
                DispatchQueue.main.async { self.text.complete(nil); self.completing = false }
            }
        }
    }

    // MARK: suggestions

    enum Mode { case start, brace, picture, other }
    struct Ctx { var mode: Mode; var word: String; var range: NSRange; var line: Int }
    func context() -> Ctx {
        let s = text.string as NSString
        let cur = text.selectedRange().location
        let lr = s.lineRange(for: NSRange(location: min(cur, s.length), length: 0))
        let before = s.substring(with: NSRange(location: lr.location, length: cur - lr.location))
        let lineNo = s.substring(to: lr.location).components(separatedBy: "\n").count
        let quotes = before.filter { $0 == "\"" }.count
        if quotes % 2 == 1, let q = before.range(of: "\"", options: .backwards) {
            let head = before[..<q.lowerBound].lowercased()
            let typed = String(before[q.upperBound...])
            let r = NSRange(location: cur - (typed as NSString).length, length: (typed as NSString).length)
            if PICTURE_CMDS.contains(where: { head.contains($0) }) { return Ctx(mode: .picture, word: typed, range: r, line: lineNo) }
            if let b = typed.range(of: "{", options: .backwards), !typed[b.upperBound...].contains("}") {
                let k = String(typed[b.upperBound...])
                return Ctx(mode: .brace, word: k, range: NSRange(location: cur - (k as NSString).length, length: (k as NSString).length), line: lineNo)
            }
            return Ctx(mode: .other, word: "", range: NSRange(location: cur, length: 0), line: lineNo)
        }
        var w = ""
        for ch in before.reversed() { if ch.isLetter || ch.isNumber || ch == "_" { w.insert(ch, at: w.startIndex) } else { break } }
        let r = NSRange(location: cur - (w as NSString).length, length: (w as NSString).length)
        let atStart = before.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == " " || $0 == "\t" }
            && before.trimmingCharacters(in: .whitespaces) == w
        return Ctx(mode: atStart ? .start : .other, word: w, range: r, line: lineNo)
    }
    func prevCommand(_ line: Int) -> String {
        let lines = text.string.components(separatedBy: "\n")
        var i = line - 2
        while i >= 0 {
            let l = lines[i].trimmingCharacters(in: .whitespaces)
            if l == "}" { return "" }
            if !l.hasPrefix(";"), let m = l.range(of: "^[A-Za-z_][A-Za-z0-9_]*", options: .regularExpression) { return l[m].lowercased() }
            i -= 1
        }
        return ""
    }
    func suggestions(_ c: Ctx) -> [String] {
        let lw = c.word.lowercased()
        switch c.mode {
        case .picture: return Pictures.list().filter { $0.lowercased().hasPrefix(lw) }
        case .brace: return SEND_KEYS.filter { $0.lowercased().hasPrefix(lw) }.map { $0 + "}" }
        case .start:
            let first = NEXT[prevCommand(c.line)] ?? NEXT[""]!
            var out = first.filter { n in Script.commands.contains { $0.name.lowercased() == n.lowercased() } }
            for cmd in Script.commands where !out.contains(cmd.name) { out.append(cmd.name) }
            return out.filter { $0.lowercased().hasPrefix(lw) && $0.lowercased() != lw }
        case .other:
            guard !lw.isEmpty else { return [] }
            var names = Script.commands.map { $0.name } + Script.variables
            if let re = try? NSRegularExpression(pattern: "^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(?::=|\\+=|-=|\\.=|\\+\\+|--|\\([^)]*\\)\\s*\\{)", options: .anchorsMatchLines) {
                let s = text.string as NSString
                for m in re.matches(in: text.string, range: NSRange(location: 0, length: s.length)) { names.append(s.substring(with: m.range(at: 1))) }
            }
            var seen = Set<String>()
            return names.filter { $0.lowercased().hasPrefix(lw) && $0.lowercased() != lw && seen.insert($0).inserted }
        }
    }
    func textView(_ tv: NSTextView, rangeForUserCompletion r: NSRange) -> NSRange { context().range }
    func textView(_ tv: NSTextView, completions words: [String], forPartialWordRange r: NSRange, indexOfSelectedItem i: UnsafeMutablePointer<Int>?) -> [String] {
        i?.pointee = 0
        return suggestions(context())
    }
}

// MARK: the language, docs/SCRIPT.md, drawn as plain readable text

final class DocsWindow {
    static var window: NSWindow?
    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "The language · Macro Recorder (Mantra)"; w.isReleasedWhenClosed = false; w.center()
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false; tv.backgroundColor = GROUND; tv.textContainerInset = NSSize(width: 18, height: 14)
        let md = Bundle.main.path(forResource: "SCRIPT", ofType: "md").flatMap(readText)
            ?? readText(HOME + "/Developer/MANTRA_MACRO/docs/SCRIPT.md") ?? "docs/SCRIPT.md is missing"
        tv.textStorage?.setAttributedString(render(md))
        w.contentView = scroll; window = w
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    // headings big, code in monospace, `inline code` in monospace amber, **bold** bold; the rest as it is
    static func render(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: INK]
        var inCode = false
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.hasPrefix("    ") {
                out.append(NSAttributedString(string: line + "\n", attributes: [.font: MONO, .foregroundColor: GREENC])); continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let t = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                out.append(NSAttributedString(string: "\n" + t + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: level == 1 ? 22 : level == 2 ? 17 : 14), .foregroundColor: AMBER]))
                continue
            }
            let l = NSMutableAttributedString(string: "", attributes: body)
            var rest = Substring(line)
            while !rest.isEmpty {
                if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                    l.append(NSAttributedString(string: String(rest[rest.index(after: rest.startIndex)..<end]), attributes: [.font: MONO, .foregroundColor: AMBER]))
                    rest = rest[rest.index(after: end)...]
                } else if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                    l.append(NSAttributedString(string: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]),
                                                attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: INK]))
                    rest = rest[end.upperBound...]
                } else {
                    l.append(NSAttributedString(string: String(rest.first!), attributes: body)); rest = rest.dropFirst()
                }
            }
            l.append(NSAttributedString(string: "\n", attributes: body))
            out.append(l)
        }
        return out
    }
}
