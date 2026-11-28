import SwiftUI
import AppKit

struct ActionRow: Identifiable {
    let id: Int
    var source: String
    var action: String
    var value: String
    var label: String
    var comment: String

    var rendered: String {
        if action.caseInsensitiveCompare("Comment") == .orderedSame {
            return "; " + value
        }
        let joiner = value.hasPrefix("(") ? "" : " "
        let line = action.isEmpty ? source : action + (value.isEmpty ? "" : joiner + value)
        let notes = [label.isEmpty ? "" : "; label: " + label, comment.isEmpty ? "" : "; " + comment]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line + (notes.isEmpty ? "" : " " + notes)
    }
}

enum RecorderRows {
    /// the code of a line and its trailing comment. As in the language's own lexer (Script.swift): a ; starts a comment only at the
    /// start of the line or after a space, never inside a "string" or 'string', and ` escapes the next character inside a string
    /// (v43: it read a backslash as the escape, and 'a;b' was cut in two and written back as 'a ; b').
    static func splitComment(_ line: String) -> (code: String, notes: String?) {
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
            if char == ";", before == " " || before == "\t" {
                let p = line.index(line.startIndex, offsetBy: index)
                return (String(line[..<p]).trimmingCharacters(in: .whitespaces),
                        String(line[line.index(after: p)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (line, nil)
    }

    static func parse(_ text: String) -> [ActionRow] {
        var out: [ActionRow] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(";") {
                let value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                out.append(ActionRow(id: index, source: line, action: "Comment", value: value, label: "", comment: ""))
                continue
            }
            let splitLine = splitComment(line)
            let code = splitLine.code
            var label = "", comment = ""
            if let note = splitLine.notes {
                if note.lowercased().hasPrefix("label:") {
                    label = String(note.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else {
                    comment += (comment.isEmpty ? "" : " · ") + note
                }
            }
            let split = code.firstIndex(where: { $0 == " " || $0 == "(" })
            let action = split.map { String(code[..<$0]) } ?? code
            let value = split.map { String(code[$0...]).trimmingCharacters(in: .whitespaces) } ?? ""
            out.append(ActionRow(id: index, source: code, action: action, value: value, label: label, comment: comment))
        }
        return out
    }

    static func render(_ rows: [ActionRow]) -> String {
        rows.map(\.rendered).joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }
}

extension String {
    var trimmedWS: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// How a command line reads as a dialog: each form returns nil when the line is not exactly that shape, and then the generic
/// editor (Action and Value as text) is used, so opening a line never rewrites what the dialog cannot hold (v43).
enum ActionForms {
    static func isNum(_ s: String) -> Bool { Double(s.trimmedWS) != nil }

    static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        var out: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            out.append(r.location == NSNotFound ? "" : (s as NSString).substring(with: r))
        }
        return out
    }

    /// "Left" / "Right" / "Middle" from a quoted argument
    static func button(_ arg: String) -> String? {
        guard ArgList.isString(arg) else { return nil }
        switch ArgList.unquote(arg).lowercased() {
        case "left", "l": return "Left"
        case "right", "r": return "Right"
        case "middle", "m": return "Middle"
        default: return nil
        }
    }

    /// the text of a value that is exactly one string literal
    static func single(_ value: String) -> String? {
        let a = ArgList.split(value)
        guard !a.paren, a.args.count == 1, ArgList.isString(a.args[0]) else { return nil }
        return ArgList.unquote(a.args[0])
    }

    /// Click x, y [, "Right"] [, count]   ·   MouseClick "Left", x, y [, count]
    static func click(_ action: String, _ value: String) -> (x: String, y: String, button: String, count: String)? {
        let a = ArgList.split(value)
        guard !a.paren else { return nil }
        let v = a.args
        switch action.lowercased() {
        case "click":
            guard v.count >= 2, v.count <= 4, isNum(v[0]), isNum(v[1]) else { return nil }
            var b = "Left", c = "1"
            if v.count == 3 {
                if isNum(v[2]) { c = v[2] } else if let n = button(v[2]) { b = n } else { return nil }
            } else if v.count == 4 {
                guard let n = button(v[2]), isNum(v[3]) else { return nil }
                b = n; c = v[3]
            }
            return (v[0], v[1], b, c)
        case "mouseclick":
            guard v.count >= 3, v.count <= 4, let b = button(v[0]), isNum(v[1]), isNum(v[2]) else { return nil }
            if v.count == 4 && !isNum(v[3]) { return nil }
            return (v[1], v[2], b, v.count == 4 ? v[3] : "1")
        default:
            return nil
        }
    }

    /// MouseMove x, y   ·   MouseMove x, y, endX, endY, ms [, relative]
    static func move(_ value: String) -> (sx: String, sy: String, ex: String, ey: String, dur: String, rel: Bool)? {
        let a = ArgList.split(value)
        guard !a.paren else { return nil }
        let v = a.args
        if v.count == 2, isNum(v[0]), isNum(v[1]) { return (v[0], v[1], v[0], v[1], "0", false) }
        guard v.count == 5 || v.count == 6, v.allSatisfy({ isNum($0) }) else { return nil }
        let rel = v.count == 6 && (Double(v[5]) ?? 0) != 0
        return (v[0], v[1], v[2], v[3], v[4], rel)
    }

    /// MouseClickDrag "Left", x1, y1, x2, y2
    static func drag(_ value: String) -> (button: String, x1: String, y1: String, x2: String, y2: String)? {
        let a = ArgList.split(value)
        guard !a.paren, a.args.count == 5, let b = button(a.args[0]),
              isNum(a.args[1]), isNum(a.args[2]), isNum(a.args[3]), isNum(a.args[4]) else { return nil }
        return (b, a.args[1], a.args[2], a.args[3], a.args[4])
    }

    /// Send "{WheelDown 3}"
    static func wheel(_ value: String) -> (dir: String, amount: String)? {
        guard let inner = single(value), let g = groups(#"^\{Wheel(Up|Down|Left|Right)(?: (\d+))?\}$"#, inner) else { return nil }
        return (g[1].prefix(1).uppercased() + g[1].dropFirst().lowercased(), g[2].isEmpty ? "1" : g[2])
    }

    /// Send "{Enter}" · "{F5 2}" · "{Ctrl down}" · "a" · "^c" · "^{Enter}": exactly one key, with or without modifiers
    static func key(_ value: String) -> (name: String, option: String, count: String)? {
        guard let inner = single(value) else { return nil }
        if groups(#"^\{Wheel(Up|Down|Left|Right)(?: \d+)?\}$"#, inner) != nil { return nil }
        if let g = groups(#"^\{([^{}\s]+)(?: (\d+|down|up))?\}$"#, inner) {
            let arg = g[2].lowercased()
            if arg == "down" { return (g[1], "Key down", "1") }
            if arg == "up" { return (g[1], "Key up", "1") }
            return (g[1], "Press & release", arg.isEmpty ? "1" : arg)
        }
        if groups(#"^[\^!+#]*(?:\{[^{}\s]+(?: (?:\d+|down|up))?\}|[^{}\^!+#])$"#, inner) != nil { return (inner, "Press & release", "1") }
        return nil
    }

    /// SendText "text"
    static func text(_ value: String) -> String? { single(value) }
}

/// holds the one key monitor of the script view, so the window can be built again without a second one
final class KeyMonitorBox {
    var token: Any?
    deinit { if let t = token { NSEvent.removeMonitor(t) } }
}

private enum ActionEditorKind: Equatable {
    case mouseMove, mouseClick, mouseDrag, wheel, keyPress, text, generic

    static func from(_ row: ActionRow) -> ActionEditorKind {
        switch row.action.lowercased() {
        case "mousemove": return ActionForms.move(row.value) != nil ? .mouseMove : .generic
        case "click", "mouseclick": return ActionForms.click(row.action, row.value) != nil ? .mouseClick : .generic
        case "mouseclickdrag": return ActionForms.drag(row.value) != nil ? .mouseDrag : .generic
        case "send":
            if ActionForms.wheel(row.value) != nil { return .wheel }
            return ActionForms.key(row.value) != nil ? .keyPress : .generic
        case "sendtext": return ActionForms.text(row.value) != nil ? .text : .generic
        default: return .generic
        }
    }

    var title: String {
        switch self {
        case .mouseMove: return "Mouse move"
        case .mouseClick: return "Mouse click"
        case .mouseDrag: return "Mouse drag"
        case .wheel: return "Mouse wheel"
        case .keyPress: return "Key press"
        case .text: return "Text"
        case .generic: return "Action"
        }
    }
}

struct MainView: View {
    @ObservedObject var e = Engine.shared
    @ObservedObject private var bridge = UIBridge.shared
    var close: () -> Void
    var quit: () -> Void
    var edit: (String) -> Void
    var docs: () -> Void

    @State private var rows: [ActionRow] = []
    @State private var selected: Int?
    @State private var search = ""
    @State private var replace = ""
    @State private var showReplace = false
    @State private var macroName = ""
    @State private var showMacroBrowser = false
    @State private var showMacroPicker = false
    @FocusState private var macroFieldFocused: Bool
    @State private var keyMonitor: KeyMonitorBox?
    @State private var dirty = false
    @State private var previewing = false
    @State private var previewAt = Date()
    @State private var actionEditorOpen = false
    @State private var editingAction: Int?
    @State private var insertAfter: Int?
    @State private var editBaseline = ""
    @State private var lastInserted: Int?
    @State private var captureNote = ""
    @State private var editorKind: ActionEditorKind = .generic
    @State private var editAction = ""
    @State private var editValue = ""
    @State private var editLabel = ""
    @State private var editComment = ""
    @State private var clickStyle = "MouseClick"
    @State private var clickX = ""
    @State private var clickY = ""
    @State private var mouseRelative = false
    @State private var mouseStartX = "0"
    @State private var mouseStartY = "0"
    @State private var mouseEndX = "0"
    @State private var mouseEndY = "0"
    @State private var mouseDuration = "50"
    @State private var mouseButton = "Left"
    @State private var mouseCount = "1"
    @State private var wheelDir = "Down"
    @State private var wheelAmount = "3"
    @State private var keyOption = "Press & release"
    @State private var keyName = "A"
    @State private var keyCount = "1"
    @State private var actionText = ""

    private var selectedName: String {
        e.current ?? Macros.list().first ?? "New Macro"
    }

    private func matchesSearch(_ row: ActionRow) -> Bool {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || (row.action + " " + row.value + " " + row.label + " " + row.comment).localizedCaseInsensitiveContains(q)
    }

    private var displayed: [ActionRow] {
        rows.filter { matchesSearch($0) }
    }

    private var duration: String {
        var ms = 0.0
        for row in rows where row.action.lowercased() == "sleep" {
            ms += Double(row.value.filter { $0.isNumber }) ?? 0
        }
        let sec = Int(ms / 1000)
        return String(format: "%02d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60)
    }

    var body: some View {
        ZStack {
            Color.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                titleBar
                macroNameBar
                toolbar
                table
                statusBar
            }
        }
        .foregroundColor(.sand)
        .onAppear {
            reload()
            installKeys()
        }
        .onChange(of: e.tick) { _ in if !dirty && !actionEditorOpen { reload() } }
        .onChange(of: e.current) { _ in
            if actionEditorOpen { applyEdit() }          // v43: what is typed in the editor is not lost when another macro comes into the player
            if !dirty { reload() }
        }
        .onChange(of: bridge.seq) { _ in runBridge(bridge.command) }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text("MACRO RECORDER (MANTRA)").font(.system(size: 12, weight: .bold, design: .monospaced))
            Menu("File") {
                Button("New macro…") { newMacro() }
                Button("Open…") { NSWorkspace.shared.open(URL(fileURLWithPath: MAC_DIR)) }
                Button("Save") { save() }
                Divider()
                Button("Quit") { quit() }
            }
            Menu("Record and Edit") {
                Button("Start recording") { e.toggleRecording() }
                Button("Edit selected action") { editCurrent() }
                Button("Add action") { beginNewAction("Send \"\"") }
                Button("Move line up (⌥↑)") { moveSelected(-1) }
                Button("Move line down (⌥↓)") { moveSelected(1) }
                Divider()
                Button("Define hotkey…") { e.captureKey("record") }
            }
            Menu("Playback") {
                Button(e.playing ? "Stop" : "Play") { playShown() }
                Button("Play from selected action") { playFromSelection() }
                Button("Stop all") { e.stopAll() }
                Divider()
                Button("Define hotkey…") { e.captureKey("play") }
            }
            Menu("View") {
                Button("Browse macros") { showMacroBrowser = true; macroFieldFocused = true }
                Button("Macros folder") { mkdirs(MAC_DIR); NSWorkspace.shared.open(URL(fileURLWithPath: MAC_DIR)) }
                Button("The language") { docs() }
            }
            Menu("Help") {
                Button("Settings") { RecorderSettingsWindow.show() }
                Button("The macro language") { docs() }
                Button("Website") { NSWorkspace.shared.open(URL(string: RELEASES)!) }
            }
            Spacer()
            if !Permissions.state().all {
                toolbarButton("Permissions") { Permissions.openMissing() }.foregroundColor(.amber)
            }
            toolbarButton(e.settings.onTop ? "Top on" : "Top") {
                e.settings.onTop.toggle(); e.settings.save()
                NSApp.windows.first { $0.title == APP_NAME }?.level = e.settings.onTop ? .floating : .normal
                e.changed()
            }
            Button(action: { InputCapture.shared.cancel(); close() }) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundColor(.off).frame(width: 24, height: 24)
        }
        .padding(.horizontal, 12).frame(height: 42)
        .background(Color.card)
    }

    private var macroNameBar: some View {
        HStack(spacing: 8) {
            Text("MACRO").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.off)
            HStack(spacing: 0) {
                TextField("Name or search a macro", text: $macroName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .focused($macroFieldFocused)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .onSubmit { submitMacroName() }
                    .onChange(of: macroName) { _ in
                        if macroFieldFocused { showMacroBrowser = true }
                    }
                if !macroName.isEmpty {
                    Button(action: { macroName = ""; showMacroBrowser = true; macroFieldFocused = true }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.off)
                    }.buttonStyle(.plain).padding(.trailing, 5)
                }
                Button(action: { showMacroPicker = true; showMacroBrowser = true; macroFieldFocused = false }) {
                    Image(systemName: "chevron.down").frame(width: 32, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMacroPicker, arrowEdge: .bottom) {
                    macroPicker
                }
            }
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.slate))
            .frame(minWidth: 360, maxWidth: .infinity)
            Button(action: saveNamedMacro) {
                Label("Save macro", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.card.opacity(0.9))
    }

    private var macroPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STORED MACROS").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.off).padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Macros.list(), id: \.self) { name in
                        Button(action: { chooseMacro(name); showMacroPicker = false }) {
                            HStack {
                                Text(name).lineLimit(1).truncationMode(.tail)
                                Spacer()
                                if e.current == name { Image(systemName: "checkmark").foregroundColor(.on) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if Macros.list().isEmpty {
                        Text("No saved macros yet.").foregroundColor(.off).padding(12)
                    }
                }
            }
        }
        .frame(width: 360, height: 320)
        .foregroundColor(.sand)
        .background(Color.ground)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            transportButton("Play", e.playing ? "stop.fill" : "play.fill", .on) { playShown() }
            transportButton(e.recording ? "Stop recording" : "Record", "record.circle.fill", .rec) { e.toggleRecording() }
            transportButton("Stop", "stop.fill", .sand) { e.stopAll() }
            categoryMenu("Mouse", "cursorarrow.motionlines") {
                Button("Click") { beginNewAction("MouseClick \"Left\", 100, 100", blank: true) }
                Button("Double click") { beginNewAction("MouseClick \"Left\", 100, 100, 2", blank: true) }
                Button("Right click") { beginNewAction("MouseClick \"Right\", 100, 100", blank: true) }
                Button("Move mouse") { beginNewAction("MouseMove 0, 0, 0, 0, 50, 0", blank: true) }
                Button("Drag mouse") { beginNewAction("MouseClickDrag \"Left\", 100, 100, 300, 300", blank: true) }
                Button("Mouse wheel") { beginNewAction("Send \"{WheelDown 3}\"") }
            }
            categoryMenu("Text/key", "keyboard") {
                Button("Type text") { beginNewAction("SendText \"text\"", blank: true) }
                Button("Key press") { beginNewAction("Send \"A\"", blank: true) }
                Button("Shortcut") { beginNewAction("Send \"^c\"", blank: true) }
                Button("Set clipboard") { beginNewAction("A_Clipboard := \"text\"") }
            }
            categoryMenu("Wait", "clock") {
                Button("Wait") { beginNewAction("Sleep 1000") }
                Button("Wait for image") { beginNewAction("WaitImage \"button.png\", 10") }
                Button("Wait for text") { beginNewAction("WaitText \"text\", 10") }
                Button("Wait for window") { beginNewAction("WinWaitActive \"App\", , 10") }
            }
            categoryMenu("Image/OCR", "viewfinder") {
                Button("Click image") { beginNewAction("ClickImage \"button.png\"") }
                Button("Click text") { beginNewAction("ClickText \"text\", 10") }
                Button("Find text") { beginNewAction("FindText(\"text\")") }
                Button("Snap button") { e.snap("") { file in if let file { beginNewAction("ClickImage \"\(file)\"") } } }
            }
            categoryMenu("Misc", "ellipsis.circle") {
                Button("Activate window") { beginNewAction("WinActivate \"App\"") }
                Button("Run app or command") { beginNewAction("Run \"open -a App\"") }
                Button("Comment") { beginNewAction("; comment") }
                Button("Recalibrate") { if let current = e.current { e.recalibrate(current) } }
            }
            Spacer()
            toolbarButton("Edit") { editCurrent() }
            toolbarButton("Delete ⌫") { deleteSelection() }
            toolbarButton("Search & replace") { showReplace = true }
        }
        .padding(.horizontal, 12).frame(height: 62)
        .background(Color.card.opacity(0.7))
    }

    @ViewBuilder
    private var table: some View {
        if showMacroBrowser {
            macroBrowser
        } else {
            actionTable
        }
    }

    private var macroBrowser: some View {
        let all = Macros.list()
        let q = macroName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
        return VStack(spacing: 0) {
            HStack {
                Text("MACROS").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.off)
                Spacer()
                Button("Back to actions") { showMacroBrowser = false; macroFieldFocused = false }
            }
            .padding(.horizontal, 10).frame(height: 30).background(Color.slate.opacity(0.7))
            List(list, id: \.self) { name in
                let info = Macros.info(name)
                Button(action: { chooseMacro(name) }) {
                    HStack(spacing: 10) {
                        Image(systemName: e.current == name ? "circle.fill" : "doc.text")
                            .foregroundColor(e.current == name ? .on : .off)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.system(size: 13, weight: .medium, design: .monospaced))
                            Text(info.bad ? "cannot read" : (info.kind + " · "
                                + (info.kind == "script" ? "\(info.lines) lines" : "\(info.events) events")))
                                .font(.system(size: 10)).foregroundColor(.off)
                        }
                        Spacer()
                        Text(keyLabel(e.settings.triggers[name].map {
                            Binding(mods: $0.mods, key: $0.key)
                        })).font(.system(size: 10)).foregroundColor(.off)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .overlay {
                if list.isEmpty {
                    Text(q.isEmpty ? "No saved macros yet." : "No macros match “\(macroName)”.")
                        .foregroundColor(.off)
                }
            }
        }
    }

    // MARK: the script view, drawn as a code editor (ScriptView.swift): line numbers, colours, indentation

    private var actionTable: some View {
        VStack(spacing: 0) {
            scriptList
            if actionEditorOpen {
                actionEditor
            }
            if showReplace || !search.isEmpty || dirty {
                HStack {
                    TextField("Find", text: $search).frame(width: 180)
                    TextField("Replace", text: $replace).frame(width: 180)
                    Button("Replace in values/comments") { replaceAll() }
                    Spacer()
                    if dirty { Button("Save changes") { save() } }
                }
                .padding(8).background(Color.card)
            }
        }
    }

    private var scriptList: some View {
        let depths = RecorderRows.depths(rows)
        let gutter = CGFloat(max(2, String(rows.count).count)) * 8 + 26
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { pair in
                        scriptLine(pair.element, pair.offset + 1, depths[pair.offset], gutter)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(alignment: .leading) {
                HStack(spacing: 0) {
                    Color.black.opacity(0.28).frame(width: gutter)
                    Color.slate.frame(width: 1)
                }
            }
            .background(Color.ground)
            .overlay {
                if displayed.isEmpty && !e.recording {
                    VStack(spacing: 8) {
                        Image(systemName: "record.circle").font(.system(size: 38)).foregroundColor(.off)
                        Text(rows.isEmpty ? "Record a new macro or add an action." : "No matching actions.")
                            .foregroundColor(.off)
                    }
                }
            }
            .onChange(of: selected) { value in
                if let value { proxy.scrollTo(value) }
                selectionChanged(value)
            }
            .onChange(of: actionEditorOpen) { _ in
                // the editor takes room from the list: the selected line stays in view
                DispatchQueue.main.async { if let id = selected { proxy.scrollTo(id) } }
            }
        }
    }

    @ViewBuilder
    private func scriptLine(_ row: ActionRow, _ number: Int, _ depth: Int, _ gutter: CGFloat) -> some View {
        if matchesSearch(row) {
            CodeLineView(number: number, gutter: gutter, row: row, depth: depth, selected: selected == row.id,
                         editing: actionEditorOpen && editingAction == row.id)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.keyWindow?.makeFirstResponder(nil)      // the arrow keys belong to the list again, not to a field of the editor
                    selected = row.id
                })
                .highPriorityGesture(TapGesture(count: 2).onEnded {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    selected = row.id
                    beginActionEdit(row)
                })
        }
    }

    private var statusBar: some View {
        HStack {
            let actionCount = rows.filter { $0.action.caseInsensitiveCompare("Comment") != .orderedSame }.count
            if showMacroBrowser {
                Text("\(Macros.list().filter { macroName.isEmpty || $0.lowercased().contains(macroName.lowercased()) }.count) saved macros")
            } else {
                Text("\(actionCount) action\(actionCount == 1 ? "" : "s")")
            }
            if dirty && !showMacroBrowser { Text("· unsaved").foregroundColor(.amber) }
            if e.recording { Text("· recording \(e.pending ?? "")").foregroundColor(.rec) }
            if e.playing { Text("· playing \(e.playName)").foregroundColor(.on) }
            Spacer()
            if showMacroBrowser {
                Text("Type above to filter · pick a macro to load").font(.system(size: 11))
            } else {
                TextField("Search actions", text: $search).frame(width: 210)
                Text(duration).font(.system(size: 11, design: .monospaced))
            }
        }
        .font(.system(size: 11)).foregroundColor(.off)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.card)
    }

    // MARK: the action editor: ONE dialog for insert and edit, with CAPTURE on every action that has something to capture

    private var editorHeading: String {
        let what = editorKind.title.uppercased()
        if editingAction == nil { return "INSERT " + what }
        let n = (rows.firstIndex(where: { $0.id == editingAction }) ?? -1) + 1
        return "EDIT " + what + (n > 0 ? " · LINE \(n)" : "")
    }

    private var actionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editorHeading).font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                if editingAction != nil {
                    Text("click another line to edit it · what you changed here is applied as you leave the line")
                        .font(.system(size: 10)).foregroundColor(.off)
                }
            }
            actionEditorFields
            if !captureNote.isEmpty {
                Text(captureNote).font(.system(size: 11, design: .monospaced)).foregroundColor(.on)
            }
            HStack(spacing: 8) {
                editorField("Label") { TextField("Optional label", text: $editLabel).frame(width: 150) }
                editorField("Comment") { TextField("Optional comment", text: $editComment) }
                Spacer()
                Button("Cancel") { closeEditor() }.keyboardShortcut(.cancelAction)
                Button("OK") { commitActionEdit() }.keyboardShortcut(.defaultAction).disabled(!editorValid)
                Button("Help") { docs() }
            }
        }
        .padding(14)
        .background(Color.card)
    }

    @ViewBuilder
    private var actionEditorFields: some View {
        switch editorKind {
        case .mouseMove:
            Text("The mouse jumps to the start, then moves to the end over the duration. Leave the start empty to move straight to the end.")
                .font(.system(size: 11)).foregroundColor(.off)
            Toggle("Relative to the current mouse position", isOn: $mouseRelative)
            HStack(alignment: .bottom, spacing: 10) {
                coordinateField("Start X", $mouseStartX)
                coordinateField("Start Y", $mouseStartY)
                coordinateField("End X", $mouseEndX)
                coordinateField("End Y", $mouseEndY)
                coordinateField("Duration", $mouseDuration, suffix: "ms", width: 110)
            }
            HStack(spacing: 8) {
                CaptureButton(slot: "mstart", title: "CAPTURE START", help: "Then click where the move starts") { captureMovePoint(start: true) }
                CaptureButton(slot: "mend", title: "CAPTURE END", help: "Then click where the move ends") { captureMovePoint(start: false) }
                CaptureButton(slot: "mdrag", title: "CAPTURE START → END", help: "Then press at the start, drag, release at the end") { captureMoveDrag() }
                Spacer()
            }
        case .mouseClick:
            HStack(alignment: .bottom, spacing: 10) {
                editorField("Button") {
                    Picker("", selection: $mouseButton) {
                        Text("Left").tag("Left")
                        Text("Right").tag("Right")
                        Text("Middle").tag("Middle")
                    }.labelsHidden().frame(width: 120)
                }
                coordinateField("X", $clickX, width: 90)
                coordinateField("Y", $clickY, width: 90)
                coordinateField("Count", $mouseCount, width: 70)
                CaptureButton(slot: "click", title: "CAPTURE CLICK", help: "Then click anywhere on the screen: position, button and click count are filled in") { captureClick() }
                Spacer()
            }
            Text("CAPTURE CLICK hides this window; click where you want it. The click is only registered, the app under it does not get it.")
                .font(.system(size: 11)).foregroundColor(.off)
        case .mouseDrag:
            HStack(alignment: .bottom, spacing: 10) {
                editorField("Button") {
                    Picker("", selection: $mouseButton) {
                        Text("Left").tag("Left")
                        Text("Right").tag("Right")
                        Text("Middle").tag("Middle")
                    }.labelsHidden().frame(width: 120)
                }
                coordinateField("Start X", $mouseStartX, width: 90)
                coordinateField("Start Y", $mouseStartY, width: 90)
                coordinateField("End X", $mouseEndX, width: 90)
                coordinateField("End Y", $mouseEndY, width: 90)
                CaptureButton(slot: "drag", title: "CAPTURE DRAG", help: "Then press at the start, drag, release at the end") { captureDrag() }
                Spacer()
            }
        case .wheel:
            Text("Scroll the wheel by notches: up, down, left or right.")
                .font(.system(size: 11)).foregroundColor(.off)
            HStack(alignment: .bottom, spacing: 10) {
                editorField("Direction") {
                    Picker("", selection: $wheelDir) {
                        Text("Up").tag("Up")
                        Text("Down").tag("Down")
                        Text("Left").tag("Left")
                        Text("Right").tag("Right")
                    }.labelsHidden().frame(width: 110)
                }
                coordinateField("Notches", $wheelAmount, width: 90)
                CaptureButton(slot: "scroll", title: "CAPTURE SCROLL", help: "Then scroll: direction and amount are filled in") { captureScroll() }
                Spacer()
            }
        case .keyPress:
            Text("Press CAPTURE KEY, then press the key: Enter, Esc, Tab, the arrows, F keys, or a shortcut with ⌘ ⌥ ⌃ ⇧. Typing its name works too.")
                .font(.system(size: 11)).foregroundColor(.off)
            HStack(alignment: .bottom, spacing: 10) {
                editorField("Key press option") {
                    Picker("", selection: $keyOption) {
                        Text("Press & release").tag("Press & release")
                        Text("Key down").tag("Key down")
                        Text("Key up").tag("Key up")
                    }.labelsHidden().frame(width: 150)
                }
                editorField("Key") { TextField("Enter, F5, ^c, a", text: $keyName).frame(width: 150) }
                coordinateField("Count", $keyCount, width: 70)
                CaptureButton(slot: "key", title: "CAPTURE KEY", help: "Then press the key or the shortcut: it is written here instead of acting on this window") { captureKey() }
                Spacer()
            }
            if keyOption != "Press & release" {
                Text("Key down and Key up take the last key of a shortcut only: hold the modifiers with their own Key down lines.")
                    .font(.system(size: 11)).foregroundColor(.off)
            }
        case .text:
            Text("Type exactly this text, including spaces and line breaks. Nothing to capture here: type or paste it.")
                .font(.system(size: 11)).foregroundColor(.off)
            TextEditor(text: $actionText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .background(Color.ground)
        case .generic:
            HStack(spacing: 8) {
                editorField("Action") { TextField("Action", text: $editAction).frame(width: 150) }
                editorField("Value") { TextField("Value", text: $editValue) }
            }
            genericCaptures
        }
    }

    private var lowerAction: String { editAction.trimmedWS.lowercased() }

    /// which argument of the command is a picture, a search area, a window name
    private var pictureIndex: Int? {
        switch lowerAction {
        case "clickimage", "waitimage", "findimage", "imageexist": return 0
        case "imagesearch": return 6
        default: return nil
        }
    }
    private var areaIndex: Int? {
        switch lowerAction {
        case "clicktext", "waittext": return 2
        case "findtext": return 1
        case "ocrtext": return 0
        default: return nil
        }
    }
    private var windowIndex: Int? {
        switch lowerAction {
        case "winactivate", "winwaitactive", "winexist", "winactive", "winminimize", "winmaximize", "winrestore",
             "winmovetop", "winmovebottom", "winsnap", "axclick", "menuselect": return 0
        case "wingetpos", "winmove": return 4
        default: return nil
        }
    }

    @ViewBuilder
    private var genericCaptures: some View {
        let picture = pictureIndex, area = areaIndex, win = windowIndex
        if picture != nil || area != nil || win != nil || lowerAction == "pixelgetcolor" {
            HStack(spacing: 8) {
                if let p = picture {
                    CaptureButton(slot: "picture", title: "CAPTURE PICTURE", help: "Then drag over the button or the part of the screen to look for") { capturePicture(p) }
                    Menu("Stored pictures") {
                        ForEach(Pictures.list(), id: \.self) { f in
                            Button(f) { patchArg(p, f, quoted: true); captureNote = "picture " + f }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                if let a = area {
                    CaptureButton(slot: "region", title: "CAPTURE REGION", help: "Then press at one corner, drag, release at the other: the search is limited to that rectangle") { captureRegion(a) }
                }
                if let w = win {
                    CaptureButton(slot: "window", title: lowerAction == "winmove" ? "CAPTURE WINDOW + PLACE" : "CAPTURE WINDOW",
                                  help: "Then click the window: its app name is filled in") { captureWindow(w) }
                }
                if lowerAction == "pixelgetcolor" {
                    CaptureButton(slot: "pixel", title: "CAPTURE POINT + COLOUR", help: "Then click the pixel: x and y are filled in and its colour is shown") { capturePixel() }
                }
                Spacer()
            }
        }
    }

    private func coordinateField(_ title: String, _ text: SwiftUI.Binding<String>, suffix: String = "", width: CGFloat = 120) -> some View {
        editorField(title) {
            HStack {
                TextField(title, text: text)
                if !suffix.isEmpty { Text(suffix).foregroundColor(.off) }
            }.frame(width: width)
        }
    }

    private func editorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundColor(.off)
            content()
        }
    }

    private func transportButton(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                .foregroundColor(color).frame(minWidth: 66, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.slate))
        }.buttonStyle(.plain)
    }

    private func categoryMenu<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                .foregroundColor(.sand).frame(minWidth: 76, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.slate))
        }.menuStyle(.borderlessButton)
    }

    private func toolbarButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .foregroundColor(.sand).padding(.horizontal, 7).padding(.vertical, 5).contentShape(Rectangle())
    }

    // MARK: CAPTURE: each one fills the fields of the dialog it is pressed in (InputCapture.swift)

    private func whole(_ v: CGFloat) -> String { String(Int(v.rounded())) }

    private func captureKey() {
        InputCapture.shared.key("key") { mods, name in
            keyName = ScriptKeys.field(mods, name)
            captureNote = "captured key: " + keyName
        }
    }

    private func captureClick() {
        InputCapture.shared.click("click", count: true) { p, button, count, _ in
            clickX = whole(p.x); clickY = whole(p.y); mouseButton = button; mouseCount = String(count)
            captureNote = "captured \(button) click at \(whole(p.x)), \(whole(p.y))" + (count > 1 ? " × \(count)" : "")
        }
    }

    private func captureMovePoint(start: Bool) {
        InputCapture.shared.click(start ? "mstart" : "mend") { p, _, _, _ in
            if start { mouseStartX = whole(p.x); mouseStartY = whole(p.y) } else { mouseEndX = whole(p.x); mouseEndY = whole(p.y) }
            captureNote = "captured the \(start ? "start" : "end") at \(whole(p.x)), \(whole(p.y))"
        }
    }

    private func captureMoveDrag() {
        InputCapture.shared.drag("mdrag") { a, b, _ in
            mouseStartX = whole(a.x); mouseStartY = whole(a.y); mouseEndX = whole(b.x); mouseEndY = whole(b.y)
            captureNote = "captured the move from \(whole(a.x)), \(whole(a.y)) to \(whole(b.x)), \(whole(b.y))"
        }
    }

    private func captureDrag() {
        InputCapture.shared.drag("drag") { a, b, button in
            mouseButton = button
            mouseStartX = whole(a.x); mouseStartY = whole(a.y); mouseEndX = whole(b.x); mouseEndY = whole(b.y)
            captureNote = "captured the drag from \(whole(a.x)), \(whole(a.y)) to \(whole(b.x)), \(whole(b.y))"
        }
    }

    private func captureScroll() {
        InputCapture.shared.scroll("scroll") { direction, amount in
            wheelDir = direction; wheelAmount = String(amount)
            captureNote = "captured scroll \(direction) × \(amount)"
        }
    }

    private func capturePicture(_ index: Int) {
        InputCapture.shared.picture("picture") { file in
            guard let file else { captureNote = "no picture taken"; return }
            patchArg(index, file, quoted: true)
            captureNote = "captured picture " + file
        }
    }

    private func captureRegion(_ index: Int) {
        InputCapture.shared.drag("region") { a, b, _ in
            let x = min(a.x, b.x), y = min(a.y, b.y), w = abs(a.x - b.x), h = abs(a.y - b.y)
            guard w >= 2, h >= 2 else { captureNote = "drag a rectangle, not a click"; return }
            patchArg(index, "rect:\(whole(x)),\(whole(y)),\(whole(w)),\(whole(h))", quoted: true, pad: index == 2 ? [1: "10"] : [:])
            captureNote = "captured the region \(whole(x)), \(whole(y)), \(whole(w)) × \(whole(h))"
        }
    }

    private func captureWindow(_ index: Int) {
        InputCapture.shared.window("window") { w in
            guard let w else { captureNote = "no window under that click"; return }
            if lowerAction == "winmove" {
                patchArg(0, whole(w.frame.minX), quoted: false); patchArg(1, whole(w.frame.minY), quoted: false)
                patchArg(2, whole(w.frame.width), quoted: false); patchArg(3, whole(w.frame.height), quoted: false)
            }
            patchArg(index, w.app, quoted: true)
            captureNote = "captured window " + w.app + (w.title.isEmpty ? "" : " · " + w.title)
        }
    }

    private func capturePixel() {
        InputCapture.shared.click("pixel", colour: true) { p, _, _, colour in
            patchArg(0, whole(p.x), quoted: false); patchArg(1, whole(p.y), quoted: false)
            captureNote = "captured the point \(whole(p.x)), \(whole(p.y)) · colour " + (colour ?? "unknown (Screen Recording?)")
        }
    }

    /// writes one argument of the Value field (a command with arguments split at the commas), keeping the rest
    private func patchArg(_ index: Int, _ text: String, quoted: Bool, pad: [Int: String] = [:]) {
        var split = ArgList.split(editValue)
        while split.args.count <= index { split.args.append("") }
        for (i, d) in pad where i < index && split.args[i].isEmpty { split.args[i] = d }
        split.args[index] = quoted ? ArgList.quote(text) : text
        editValue = ArgList.join(split)
    }

    // MARK: what the dialog says, as a line of script

    private func composed() -> (action: String, value: String) {
        switch editorKind {
        case .mouseMove:
            let sx = mouseStartX.trimmedWS, sy = mouseStartY.trimmedWS, ex = mouseEndX.trimmedWS, ey = mouseEndY.trimmedWS
            let dur = mouseDuration.trimmedWS.isEmpty ? "0" : mouseDuration.trimmedWS
            if !mouseRelative && sx.isEmpty && sy.isEmpty { return ("MouseMove", "\(ex), \(ey)") }
            if !mouseRelative && sx == ex && sy == ey && dur == "0" { return ("MouseMove", "\(ex), \(ey)") }
            return ("MouseMove", [sx, sy, ex, ey, dur, mouseRelative ? "1" : "0"].joined(separator: ", "))
        case .mouseClick:
            let x = clickX.trimmedWS, y = clickY.trimmedWS, count = max(1, Int(mouseCount.trimmedWS) ?? 1)
            if clickStyle == "Click" {
                var v = "\(x), \(y)"
                if mouseButton != "Left" { v += ", " + ArgList.quote(mouseButton) }
                if count > 1 { v += ", \(count)" }
                return ("Click", v)
            }
            return ("MouseClick", ArgList.quote(mouseButton) + ", \(x), \(y)" + (count > 1 ? ", \(count)" : ""))
        case .mouseDrag:
            return ("MouseClickDrag", [ArgList.quote(mouseButton), mouseStartX.trimmedWS, mouseStartY.trimmedWS,
                                       mouseEndX.trimmedWS, mouseEndY.trimmedWS].joined(separator: ", "))
        case .wheel:
            let n = max(1, Int(wheelAmount.trimmedWS) ?? 1)
            return ("Send", ArgList.quote(n == 1 ? "{Wheel\(wheelDir)}" : "{Wheel\(wheelDir) \(n)}"))
        case .keyPress:
            let name = keyName.trimmedWS
            let count = max(1, Int(keyCount.trimmedWS) ?? 1)
            let isExpression = name.contains("{") || (name.count > 1 && "^!+#".contains(name.first!))
            var bare = name
            while let f = bare.first, "^!+#".contains(f), bare.count > 1 { bare.removeFirst() }
            bare = bare.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            if keyOption == "Key down" { return ("Send", ArgList.quote("{\(bare) down}")) }
            if keyOption == "Key up" { return ("Send", ArgList.quote("{\(bare) up}")) }
            if isExpression { return ("Send", ArgList.quote(String(repeating: name, count: count))) }
            return ("Send", ArgList.quote(count > 1 ? "{\(name) \(count)}" : "{\(name)}"))
        case .text:
            return ("SendText", ArgList.quote(actionText))
        case .generic:
            return (editAction.trimmedWS, editValue)
        }
    }

    private func signature() -> String {
        let c = composed()
        return [c.action, c.value, editLabel, editComment].joined(separator: "\u{1}")
    }

    private var editorValid: Bool {
        func n(_ s: String) -> Bool { ActionForms.isNum(s) }
        switch editorKind {
        case .mouseMove:
            let startBlank = mouseStartX.trimmedWS.isEmpty && mouseStartY.trimmedWS.isEmpty
            let startOK = startBlank ? !mouseRelative : (n(mouseStartX) && n(mouseStartY))
            return startOK && n(mouseEndX) && n(mouseEndY) && n(mouseDuration)
        case .mouseClick: return n(clickX) && n(clickY) && (Int(mouseCount.trimmedWS) ?? 0) > 0
        case .mouseDrag: return n(mouseStartX) && n(mouseStartY) && n(mouseEndX) && n(mouseEndY)
        case .wheel: return (Int(wheelAmount.trimmedWS) ?? 0) > 0
        case .keyPress: return !keyName.trimmedWS.isEmpty
        case .text: return editingAction != nil || !actionText.isEmpty
        case .generic: return !editAction.trimmedWS.isEmpty
        }
    }

    // MARK: opening, switching and closing the editor

    private func closeEditor() {
        InputCapture.shared.cancel()                 // a capture left armed would outlive its dialog
        actionEditorOpen = false
        editingAction = nil
        insertAfter = nil
        captureNote = ""
    }

    /// Writes what the dialog says into the script (in memory; the file is saved by Save). Returns false when nothing was changed.
    /// This is what happens to the changes of a line you leave: they are applied, never silently dropped. A NEW action that was not
    /// touched since it was opened is dropped instead (it would only be the template).
    @discardableResult
    private func applyEdit() -> Bool {
        guard actionEditorOpen, signature() != editBaseline else { return false }
        guard editorValid else {
            e.say("the changes to the line you left were not applied: a field is empty or is not a number", ORANGEC, 3)
            return false
        }
        let c = composed()
        if let id = editingAction {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
            rows[index].action = c.action
            rows[index].value = c.value
            rows[index].source = (c.action + " " + c.value).trimmedWS
            rows[index].label = editLabel
            rows[index].comment = editComment
        } else {
            let id = (rows.map(\.id).max() ?? -1) + 1
            let row = ActionRow(id: id, source: (c.action + " " + c.value).trimmedWS, action: c.action, value: c.value,
                                label: editLabel, comment: editComment)
            if let after = insertAfter, let index = rows.firstIndex(where: { $0.id == after }) { rows.insert(row, at: index + 1) }
            else { rows.append(row) }
            lastInserted = id
        }
        editBaseline = signature()
        dirty = true
        return true
    }

    private func commitActionEdit() {
        lastInserted = nil
        let isNew = editingAction == nil
        applyEdit()
        let added = lastInserted
        closeEditor()
        if isNew, let added { selected = added }
    }

    private func selectionChanged(_ value: Int?) {
        guard actionEditorOpen, let value, value != editingAction, let row = rows.first(where: { $0.id == value }) else { return }
        beginActionEdit(row)                         // applies the line it leaves, then shows this one
    }

    private func beginActionEdit(_ given: ActionRow) {
        applyEdit()
        InputCapture.shared.cancel()
        let row = rows.first(where: { $0.id == given.id }) ?? given
        showMacroBrowser = false
        editingAction = row.id
        insertAfter = nil
        actionEditorOpen = true
        captureNote = ""
        editAction = row.action
        editValue = row.value
        editLabel = row.label
        editComment = row.comment
        editorKind = ActionEditorKind.from(row)
        loadFields(row)
        editBaseline = signature()
    }

    private func beginNewAction(_ source: String, blank: Bool = false) {
        guard let row = RecorderRows.parse(source + "\n").first else { return }
        applyEdit()
        let after = selected
        showMacroBrowser = false
        InputCapture.shared.cancel()
        editingAction = nil
        insertAfter = after
        actionEditorOpen = true
        captureNote = ""
        editAction = row.action
        editValue = row.value
        editLabel = ""
        editComment = ""
        editorKind = ActionEditorKind.from(row)
        loadFields(row)
        if blank { blankFields() }
        editBaseline = signature()
    }

    private func loadFields(_ row: ActionRow) {
        switch editorKind {
        case .mouseMove:
            if let m = ActionForms.move(row.value) {
                mouseStartX = m.sx; mouseStartY = m.sy; mouseEndX = m.ex; mouseEndY = m.ey; mouseDuration = m.dur; mouseRelative = m.rel
            }
        case .mouseClick:
            if let c = ActionForms.click(row.action, row.value) {
                clickStyle = row.action.lowercased() == "click" ? "Click" : "MouseClick"
                clickX = c.x; clickY = c.y; mouseButton = c.button; mouseCount = c.count
            }
        case .mouseDrag:
            if let d = ActionForms.drag(row.value) {
                mouseButton = d.button; mouseStartX = d.x1; mouseStartY = d.y1; mouseEndX = d.x2; mouseEndY = d.y2
            }
        case .wheel:
            if let w = ActionForms.wheel(row.value) { wheelDir = w.dir; wheelAmount = w.amount }
        case .keyPress:
            if let k = ActionForms.key(row.value) { keyName = k.name; keyOption = k.option; keyCount = k.count }
        case .text:
            actionText = ActionForms.text(row.value) ?? ""
        case .generic:
            break
        }
    }

    /// a new action starts empty where a default would be dangerous (a click at 100, 100 or a typed "A" nobody asked for)
    private func blankFields() {
        switch editorKind {
        case .mouseMove:
            mouseStartX = ""; mouseStartY = ""; mouseEndX = ""; mouseEndY = ""; mouseDuration = "0"; mouseRelative = false
        case .mouseClick:
            clickX = ""; clickY = ""
        case .mouseDrag:
            mouseStartX = ""; mouseStartY = ""; mouseEndX = ""; mouseEndY = ""
        case .keyPress:
            keyName = ""; keyOption = "Press & release"; keyCount = "1"
        case .text:
            actionText = ""
        default:
            break
        }
    }

    // MARK: the keys of the script view (↑ ↓ move the selection, ⌥↑ ⌥↓ move the line, Return edits, Delete removes): one monitor,
    // only while the recorder window is the key window and no text field has the keyboard, and never while a CAPTURE waits

    private func installKeys() {
        guard keyMonitor == nil else { return }
        let box = KeyMonitorBox()
        box.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !InputCapture.shared.armed, !showMacroBrowser, let win = NSApp.keyWindow, win.title == APP_NAME,
                  !(win.firstResponder is NSText), !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return event }
            let option = event.modifierFlags.contains(.option)
            switch event.keyCode {
            case 126: if option { moveSelected(-1) } else { moveSelection(-1) }
            case 125: if option { moveSelected(1) } else { moveSelection(1) }
            case 36, 76: guard selected != nil, !actionEditorOpen else { return event }; editCurrent()     // with the editor open Return is its OK
            case 51, 117: guard selected != nil else { return event }; deleteSelection()
            default: return event
            }
            return nil
        }
        keyMonitor = box
    }

    // MARK: the script

    private func reload() {
        if previewing && Date().timeIntervalSince(previewAt) < 300 { return }      // a picture of another macro is on show (UIApi)
        previewing = false
        closeEditor()
        let before = selected.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
        let text = e.text ?? e.current.flatMap { Macros.read($0).text } ?? (readText(LAST_AHK) ?? "")
        rows = RecorderRows.parse(text)
        // the line numbers of the saved text are the new ids: the selection stays on the same line number
        selected = before.flatMap { $0 < rows.count ? rows[$0].id : nil }
        if !macroFieldFocused {
            macroName = e.current ?? e.pending ?? ""
            showMacroBrowser = false
        }
        dirty = false
    }

    /// unsaved changes to the script: ask before they are replaced (another macro, a new macro)
    private func confirmLeave(_ what: String) -> Bool {
        applyEdit()
        guard dirty, !previewing else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Save the changes to " + (macroName.isEmpty ? "this macro" : macroName) + "?"
        a.informativeText = "You changed the script and did not save it. " + what
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don't save")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            saveNamedMacro()
            return !dirty
        case .alertSecondButtonReturn:
            dirty = false
            return true
        default:
            return false
        }
    }

    private func chooseMacro(_ name: String) {
        guard confirmLeave("Opening " + name + " replaces it.") else { return }
        guard e.loadMacro(name, quiet: true) else { return }
        macroName = name
        macroFieldFocused = false
        showMacroBrowser = false
        showMacroPicker = false
        selected = nil
        dirty = false
        previewing = false
        reload()
    }

    private func submitMacroName() {
        let name = Macros.clean(macroName)
        if Macros.exists(name) {
            chooseMacro(name)
        } else {
            macroName = name
            macroFieldFocused = false
            showMacroBrowser = false
            saveNamedMacro()
        }
    }

    private func deleteSelection() {
        guard let selected, let index = rows.firstIndex(where: { $0.id == selected }) else { return }
        if editingAction == selected { closeEditor() }
        rows.remove(at: index)
        // the line below (or the last one) takes the selection, so the arrow keys and Delete can go on
        self.selected = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
        dirty = true
    }

    private func moveSelection(_ step: Int) {
        let list = displayed
        guard !list.isEmpty else { return }
        let at = list.firstIndex(where: { $0.id == selected })
        let next = at.map { min(max($0 + step, 0), list.count - 1) } ?? (step > 0 ? 0 : list.count - 1)
        selected = list[next].id
    }

    /// the line moves up or down (⌥↑ ⌥↓, as in a code editor)
    private func moveSelected(_ step: Int) {
        guard search.isEmpty, let selected, let index = rows.firstIndex(where: { $0.id == selected }) else { return }
        let to = index + step
        guard to >= 0, to < rows.count else { return }
        rows.swapAt(index, to)
        dirty = true
    }

    private func replaceAll() {
        guard !search.isEmpty else { return }
        applyEdit()
        closeEditor()
        for index in rows.indices {
            rows[index].source = rows[index].source.replacingOccurrences(of: search, with: replace)
            rows[index].value = rows[index].value.replacingOccurrences(of: search, with: replace)
            rows[index].label = rows[index].label.replacingOccurrences(of: search, with: replace)
            rows[index].comment = rows[index].comment.replacingOccurrences(of: search, with: replace)
        }
        dirty = true
    }

    private func save() {
        saveNamedMacro()
    }

    private func saveNamedMacro() {
        applyEdit()                                  // what is typed in the editor is part of what is saved
        if e.recording {
            _ = e.stopRecording()
            if !dirty, let text = e.text { rows = RecorderRows.parse(text) }
        }
        let name = Macros.clean(macroName)
        guard !name.isEmpty else {
            e.say("name the macro before saving", ORANGEC, 3)
            macroFieldFocused = true
            return
        }
        if let current = e.current, current != name {
            if Macros.exists(name) {
                e.say("a macro called \(name) already exists", ORANGEC, 3)
                return
            }
            e.rename(current, name)
            guard e.current == name else { return }
        } else if e.current == nil && Macros.exists(name) {
            e.say("choose that saved macro to edit it, or use a new name", ORANGEC, 3)
            return
        }
        let result = e.saveScript(name, RecorderRows.render(rows))
        if let warning = result.warn {
            e.say(warning, REDC, 4)
        } else {
            e.current = name
            e.text = RecorderRows.render(rows)
            e.settings.current = name
            _ = Slots.autoPlace(&e.settings.slots, name)
            e.settings.save()
            macroName = name
            macroFieldFocused = false
            showMacroBrowser = false
            dirty = false
            previewing = false
            e.say("saved " + name, GREENC, 1.6)
        }
        e.changed()
    }

    private func newMacro() {
        guard confirmLeave("A new macro replaces it.") else { return }
        if e.recording { _ = e.stopRecording() }
        closeEditor()
        e.current = nil
        e.text = nil
        e.settings.current = nil
        e.settings.save()
        rows = []
        selected = nil
        previewing = false
        dirty = true
        macroName = Macros.croName()
        showMacroBrowser = false
        macroFieldFocused = true
        e.changed()
    }

    private func editCurrent() {
        if let selected, let row = rows.first(where: { $0.id == selected }) {
            beginActionEdit(row)
        } else if let first = rows.first {
            selected = first.id
            beginActionEdit(first)
        } else {
            macroFieldFocused = true
        }
    }

    /// PLAY plays what the window shows: with unsaved changes the changed script runs (nothing is written to the file)
    private func playShown() {
        if e.playing || e.recording { e.togglePlay(); return }
        applyEdit()
        if dirty && !rows.isEmpty {
            e.runScript(RecorderRows.render(rows), selectedName)
        } else {
            e.togglePlay()
        }
    }

    private func playFromSelection() {
        applyEdit()
        guard let selected, let index = rows.firstIndex(where: { $0.id == selected }) else { return playShown() }
        e.runScript(RecorderRows.render(Array(rows[index...])), selectedName + " · from selected action")
    }

    // MARK: the window's own API (UIApi.swift): open, show another macro, open a dialog, for screenshots and tests

    private func runBridge(_ c: [String: Any]) {
        switch c["op"] as? String ?? "" {
        case "preview":
            let name = c["macro"] as? String ?? ""
            guard let text = Macros.read(name).text else { return }
            closeEditor()
            rows = RecorderRows.parse(text)
            macroName = name
            selected = nil
            dirty = false
            showMacroBrowser = false
            previewing = true
            previewAt = Date()
        case "reset":
            closeEditor()
            previewing = false
            dirty = false
            reload()
        case "dialog":
            previewAt = Date()
            switch c["kind"] as? String ?? "" {
            case "key", "shortcut": beginNewAction("Send \"A\"", blank: true)
            case "click": beginNewAction("MouseClick \"Left\", 100, 100", blank: true)
            case "move": beginNewAction("MouseMove 0, 0, 0, 0, 50, 0", blank: true)
            case "drag": beginNewAction("MouseClickDrag \"Left\", 100, 100, 300, 300", blank: true)
            case "wheel": beginNewAction("Send \"{WheelDown 3}\"")
            case "text": beginNewAction("SendText \"text\"", blank: true)
            case "image": beginNewAction("ClickImage \"button.png\"")
            case "waittext": beginNewAction("WaitText \"text\", 10")
            case "window": beginNewAction("WinActivate \"App\"")
            default: break
            }
        case "select", "edit":
            if previewing { previewAt = Date() }
            let line = (c["line"] as? Int) ?? 0
            guard line >= 1, line <= rows.count else { return }
            let row = rows[line - 1]
            selected = row.id
            if (c["op"] as? String) == "edit" { beginActionEdit(row) }
        case "close-dialog":
            closeEditor()
        default:
            break
        }
    }
}
