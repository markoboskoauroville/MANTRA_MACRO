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
    static func splitComment(_ line: String) -> (code: String, notes: String?) {
        var quoted = false, escaped = false
        for (index, char) in line.enumerated() {
            if escaped { escaped = false; continue }
            if char == "\\" && quoted { escaped = true; continue }
            if char == "\"" { quoted.toggle(); continue }
            if char == ";", !quoted {
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

private enum ActionEditorKind: Equatable {
    case mouseMove, mouseClick, keyPress, text, generic

    static func from(_ row: ActionRow) -> ActionEditorKind {
        let action = row.action.lowercased()
        if action == "mousemove" { return .mouseMove }
        if ["click", "mouseclick"].contains(action) { return .mouseClick }
        if action == "send" { return .keyPress }
        if action == "sendtext" { return .text }
        return .generic
    }

    var title: String {
        switch self {
        case .mouseMove: return "Mouse move action"
        case .mouseClick: return "Mouse click action"
        case .keyPress: return "Insert key press"
        case .text: return "Insert text"
        case .generic: return "Edit action"
        }
    }
}

struct MainView: View {
    @ObservedObject var e = Engine.shared
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
    @State private var dirty = false
    @State private var actionEditorOpen = false
    @State private var editingAction: Int?
    @State private var editorKind: ActionEditorKind = .generic
    @State private var editAction = ""
    @State private var editValue = ""
    @State private var editLabel = ""
    @State private var editComment = ""
    @State private var mouseRelative = false
    @State private var mouseStartX = "0"
    @State private var mouseStartY = "0"
    @State private var mouseEndX = "0"
    @State private var mouseEndY = "0"
    @State private var mouseDuration = "50"
    @State private var mouseButton = "Left"
    @State private var mouseCount = "1"
    @State private var keyOption = "Press & release"
    @State private var keyName = "A"
    @State private var keyCount = "1"
    @State private var actionText = ""

    private var selectedName: String {
        e.current ?? Macros.list().first ?? "New Macro"
    }

    private var displayed: [ActionRow] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { ($0.action + " " + $0.value + " " + $0.label + " " + $0.comment)
            .localizedCaseInsensitiveContains(q) }
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
        .onAppear(perform: reload)
        .onChange(of: e.tick) { _ in if !dirty { reload() } }
        .onChange(of: e.current) { _ in if !dirty { reload() } }
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
                Button("Add action") { add("Send ", atEnd: true) }
                Divider()
                Button("Define hotkey…") { e.captureKey("record") }
            }
            Menu("Playback") {
                Button(e.playing ? "Stop" : "Play") { e.togglePlay() }
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
            Button(action: close) { Image(systemName: "xmark") }
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
            transportButton("Play", e.playing ? "stop.fill" : "play.fill", .on) { e.togglePlay() }
            transportButton(e.recording ? "Stop recording" : "Record", "record.circle.fill", .rec) { e.toggleRecording() }
            transportButton("Stop", "stop.fill", .sand) { e.stopAll() }
            categoryMenu("Mouse", "cursorarrow.motionlines") {
                Button("Click") { beginNewAction("MouseClick \"Left\", 100, 100") }
                Button("Double click") { beginNewAction("MouseClick \"Left\", 100, 100, 2") }
                Button("Right click") { beginNewAction("MouseClick \"Right\", 100, 100") }
                Button("Move mouse") { beginNewAction("MouseMove 0, 0, 0, 0, 50, 0") }
                Button("Drag mouse") { beginNewAction("MouseClickDrag \"Left\", 100, 100, 300, 300") }
                Button("Mouse wheel") { beginNewAction("Send \"{WheelDown}\"") }
            }
            categoryMenu("Text/key", "keyboard") {
                Button("Type text") { beginNewAction("SendText \"text\"") }
                Button("Key press") { beginNewAction("Send \"A\"") }
                Button("Shortcut") { beginNewAction("Send \"^c\"") }
                Button("Set clipboard") { beginNewAction("A_Clipboard := \"text\"") }
            }
            categoryMenu("Wait", "clock") {
                Button("Wait") { add("Sleep 1000") }
                Button("Wait for image") { add("WaitImage \"button.png\", 10") }
                Button("Wait for text") { add("WaitText \"text\", 10") }
                Button("Wait for window") { add("WinWaitActive \"App\", 10") }
            }
            categoryMenu("Image/OCR", "viewfinder") {
                Button("Click image") { add("ClickImage \"button.png\"") }
                Button("Click text") { add("ClickText \"text\", 10") }
                Button("Find text") { add("FindText(\"text\")") }
                Button("Snap button") { e.snap("") { file in if let file { add("ClickImage \"\(file)\"", atEnd: true) } } }
            }
            categoryMenu("Misc", "ellipsis.circle") {
                Button("Activate window") { add("WinActivate \"App\"") }
                Button("Run app or command") { add("Run \"open -a App\"") }
                Button("Comment") { add("; comment") }
                Button("Recalibrate") { if let current = e.current { e.recalibrate(current) } }
            }
            Spacer()
            toolbarButton("Edit") { editCurrent() }
            toolbarButton("Delete ⌫") { deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
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

    private var actionTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                column("ACTION", 150)
                column("VALUE", nil)
                column("LABEL", 150)
                column("COMMENT", 220)
            }
            .frame(height: 30).background(Color.slate.opacity(0.7))
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    ForEach(displayed) { row in
                        HStack(spacing: 0) {
                            ActionCell(text: row.action, width: 150)
                            ActionCell(text: row.value)
                            ActionCell(text: row.label, width: 150)
                            ActionCell(text: row.comment, width: 220)
                        }
                        .tag(row.id).listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { selected = row.id })
                        .highPriorityGesture(TapGesture(count: 2).onEnded {
                            selected = row.id
                            beginActionEdit(row)
                        })
                    }
                    .onMove { source, destination in
                        rows.move(fromOffsets: source, toOffset: destination)
                        dirty = true
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .onDeleteCommand(perform: deleteSelection)
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
                    if let value { withAnimation { proxy.scrollTo(value, anchor: .center) } }
                }
            }
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

    private var actionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editorKind.title.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                if editingAction == nil { Text("NEW").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.on) }
            }
            actionEditorFields
            HStack(spacing: 8) {
                editorField("Label") { TextField("Optional label", text: $editLabel).frame(width: 150) }
                editorField("Comment") { TextField("Optional comment", text: $editComment) }
                Spacer()
                Button("Cancel") { actionEditorOpen = false; editingAction = nil }
                Button("OK") { commitActionEdit() }.keyboardShortcut(.defaultAction)
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
            Text("Choose the start and end point, then define how long the mouse takes to move.")
                .font(.system(size: 11)).foregroundColor(.off)
            Toggle("Relative to the current mouse position", isOn: $mouseRelative)
            HStack {
                coordinateField("Start X", $mouseStartX)
                coordinateField("Start Y", $mouseStartY)
                coordinateField("End X", $mouseEndX)
                coordinateField("End Y", $mouseEndY)
            }
            coordinateField("Duration", $mouseDuration, suffix: "ms", width: 170)
        case .mouseClick:
            HStack {
                editorField("Button") {
                    Picker("", selection: $mouseButton) {
                        Text("Left").tag("Left")
                        Text("Right").tag("Right")
                        Text("Middle").tag("Middle")
                    }.labelsHidden().frame(width: 120)
                }
                coordinateField("X", $mouseEndX)
                coordinateField("Y", $mouseEndY)
                coordinateField("Count", $mouseCount, width: 100)
            }
        case .keyPress:
            Text("Define the key press to be simulated by Macro Recorder.")
                .font(.system(size: 11)).foregroundColor(.off)
            HStack {
                editorField("Key press option") {
                    Picker("", selection: $keyOption) {
                        Text("Press & release").tag("Press & release")
                        Text("Key down").tag("Key down")
                        Text("Key up").tag("Key up")
                    }.labelsHidden().frame(width: 150)
                }
                editorField("Key") { TextField("A", text: $keyName).frame(width: 130) }
                coordinateField("Count", $keyCount, width: 100)
            }
        case .text:
            Text("Type exactly this text, including spaces and line breaks.")
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

    private func column(_ text: String, _ width: CGFloat?) -> some View {
        Text(text).font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.off).frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
            .padding(.leading, 8)
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

    private func reload() {
        let text = e.text ?? e.current.flatMap { Macros.read($0).text } ?? (readText(LAST_AHK) ?? "")
        rows = RecorderRows.parse(text)
        if !macroFieldFocused {
            macroName = e.current ?? e.pending ?? ""
            showMacroBrowser = false
        }
        dirty = false
    }

    private func chooseMacro(_ name: String) {
        guard e.loadMacro(name, quiet: true) else { return }
        macroName = name
        macroFieldFocused = false
        showMacroBrowser = false
        showMacroPicker = false
        selected = nil
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

    private func add(_ snippet: String, atEnd: Bool = false) {
        showMacroBrowser = false
        var action = "", value = ""
        if let space = snippet.firstIndex(of: " ") { action = String(snippet[..<space]); value = String(snippet[snippet.index(after: space)...]) }
        else { action = snippet }
        let id = (rows.map(\.id).max() ?? -1) + 1
        let row = ActionRow(id: id, source: snippet, action: action, value: value, label: "", comment: "")
        if !atEnd, let selected, let index = rows.firstIndex(where: { $0.id == selected }) { rows.insert(row, at: index + 1) }
        else { rows.append(row) }
        self.selected = id; dirty = true
    }

    private func deleteSelection() {
        guard let selected else { return }
        rows.removeAll { $0.id == selected }; self.selected = nil; dirty = true
    }

    private func replaceAll() {
        guard !search.isEmpty else { return }
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
            e.say("saved " + name, GREENC, 1.6)
        }
        e.changed()
    }

    private func newMacro() {
        if e.recording { _ = e.stopRecording() }
        e.current = nil
        e.text = nil
        e.settings.current = nil
        e.settings.save()
        rows = []
        selected = nil
        editingAction = nil
        actionEditorOpen = false
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
            beginActionEdit(first)
        } else {
            macroFieldFocused = true
        }
    }

    private func beginActionEdit(_ row: ActionRow) {
        showMacroBrowser = false
        editingAction = row.id
        actionEditorOpen = true
        editorKind = ActionEditorKind.from(row)
        editAction = row.action
        editValue = row.value
        editLabel = row.label
        editComment = row.comment
        let parts = row.value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch editorKind {
        case .mouseMove:
            mouseStartX = parts.count > 2 ? parts[0] : "0"
            mouseStartY = parts.count > 2 ? parts[1] : "0"
            mouseEndX = parts.count > 2 ? parts[2] : (parts.first ?? "0")
            mouseEndY = parts.count > 2 ? parts[3] : (parts.count > 1 ? parts[1] : "0")
            mouseDuration = parts.count > 4 ? parts[4] : "50"
            mouseRelative = parts.count > 5 && (parts[5] == "1" || parts[5].lowercased() == "true")
        case .mouseClick:
            if row.action.lowercased() == "mouseclick" || row.action.lowercased() == "mouseclickdrag" {
                mouseButton = parts.first.map { $0.replacingOccurrences(of: "\"", with: "") } ?? "Left"
                mouseEndX = parts.count > 1 ? parts[1] : "0"
                mouseEndY = parts.count > 2 ? parts[2] : "0"
                mouseCount = parts.count > 3 ? parts[3] : "1"
            } else {
                mouseButton = "Left"
                mouseEndX = parts.first ?? "0"
                mouseEndY = parts.count > 1 ? parts[1] : "0"
                mouseCount = parts.count > 2 ? parts[2] : "1"
            }
        case .keyPress:
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            var key = value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
            keyOption = "Press & release"
            if key.lowercased().contains(" down") { keyOption = "Key down"; key = key.replacingOccurrences(of: " down", with: "", options: .caseInsensitive) }
            if key.lowercased().contains(" up") { keyOption = "Key up"; key = key.replacingOccurrences(of: " up", with: "", options: .caseInsensitive) }
            keyName = key.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            keyCount = "1"
        case .text:
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            actionText = value.hasPrefix("\"") && value.hasSuffix("\"")
                ? String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                : value
        case .generic:
            break
        }
    }

    private func beginNewAction(_ source: String) {
        guard let row = RecorderRows.parse(source + "\n").first else { return }
        beginActionEdit(row)
        editingAction = nil
    }

    private func commitActionEdit() {
        switch editorKind {
        case .mouseMove:
            editAction = "MouseMove"
            editValue = [mouseStartX, mouseStartY, mouseEndX, mouseEndY, mouseDuration, mouseRelative ? "1" : "0"].joined(separator: ", ")
        case .mouseClick:
            editAction = "MouseClick"
            editValue = "\"\(mouseButton)\", \(mouseEndX), \(mouseEndY), \(mouseCount)"
        case .keyPress:
            editAction = "Send"
            let count = max(1, Int(keyCount) ?? 1)
            if keyOption == "Key down" {
                editValue = "\"{\(keyName) down}\""
            } else if keyOption == "Key up" {
                editValue = "\"{\(keyName) up}\""
            } else if keyName.hasPrefix("^") || keyName.hasPrefix("!") || keyName.hasPrefix("+") || keyName.hasPrefix("#") {
                editValue = "\"\(keyName)\""
            } else {
                editValue = count > 1 ? "\"{\(keyName) \(count)}\"" : "\"{\(keyName)}\""
            }
        case .text:
            editAction = "SendText"
            editValue = "\"" + actionText.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        case .generic:
            break
        }
        if let id = editingAction, let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].action = editAction
            rows[index].value = editValue
            rows[index].label = editLabel
            rows[index].comment = editComment
        } else {
            let id = (rows.map(\.id).max() ?? -1) + 1
            rows.append(ActionRow(id: id, source: editAction + " " + editValue, action: editAction, value: editValue,
                                  label: editLabel, comment: editComment))
            selected = id
        }
        editingAction = nil
        actionEditorOpen = false
        dirty = true
    }

    private func playFromSelection() {
        guard let selected, let index = rows.firstIndex(where: { $0.id == selected }) else { return e.play() }
        e.runScript(RecorderRows.render(Array(rows[index...])), selectedName + " · from selected action")
    }
}

private struct ActionCell: View {
    let text: String
    var width: CGFloat?

    var body: some View {
        Text(text).font(.system(size: 12, design: .monospaced))
            .lineLimit(1).truncationMode(.tail)
            .frame(width: width).frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
    }
}
