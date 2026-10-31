// Window.swift: the settings window, what the page on :8829 was, top to bottom: the transport, the slots, the macros,
// the pictures, the keys, playback, the window, the folder. One window, resizable, the page as wide as the window
// (swift-apps.md "Never cut text"). The first row is MACRO RECORDER  ON  OFF … TOP (PERMISSIONS) ✕ (v4, 31.10.2026).
import SwiftUI
import AppKit

extension Color {
    static let ground = Color(red: 0x0B/255, green: 0x0D/255, blue: 0x10/255)
    static let card = Color(red: 0x14/255, green: 0x1A/255, blue: 0x21/255)
    static let slate = Color(red: 0x23/255, green: 0x30/255, blue: 0x3D/255)
    static let sand = Color(red: 0xF2/255, green: 0xDD/255, blue: 0xB4/255)
    static let amber = Color(red: 0xE8/255, green: 0xA3/255, blue: 0x3D/255)
    static let on = Color(red: 0x33/255, green: 0xD1/255, blue: 0x7A/255)
    static let off = Color(red: 0x7A/255, green: 0x80/255, blue: 0x87/255)
    static let rec = Color(red: 1, green: 0x3B/255, blue: 0x30/255)
}

// a key is its word; its colour is its state
struct Word: View {
    let text: String; var color: Color = .sand; var size: CGFloat = 12; var help = ""; var ax: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: size, weight: .bold, design: .monospaced)).foregroundColor(color)
                .padding(.horizontal, 4).padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).focusable(false).help(help)
        // v4: a fixed identifier for every word, so a script finds it (MANTRA_MANIFEST swift-apps.md)
        .accessibilityIdentifier(ax ?? text.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

struct Section<Content: View>: View {
    let title: String; var hint = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).foregroundColor(.off)
            if !hint.isEmpty { Text(hint).font(.system(size: 11)).foregroundColor(.off).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
    }
}

struct MainView: View {
    @ObservedObject var e = Engine.shared
    var close: () -> Void
    var quit: () -> Void
    var edit: (String) -> Void
    var docs: () -> Void
    @State var newName = ""
    @State var picName = ""
    @State var renaming: String?
    @State var renameText = ""
    @State var armed: String?
    @State var dragging: String?

    var s: Settings { e.settings }

    var body: some View {
        GeometryReader { g in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    top; transport; permissions; slots; macros; pictures; keys; playback; window; foot
                }
                .frame(width: max(300, g.size.width - 28), alignment: .leading).clipped()
                .padding(14)
            }
        }
        .background(Color.ground)
        .foregroundColor(.sand)
        .focusEffectDisabled()
        .frame(minWidth: 380, idealWidth: 480, maxWidth: .infinity, minHeight: 320, idealHeight: 760, maxHeight: .infinity)
        .id(e.tick)
    }

    // MARK: the first row

    var top: some View {
        HStack(spacing: 8) {
            Text("MACRO RECORDER").font(.system(size: 12, weight: .bold, design: .monospaced))
            Word(text: "ON", color: .on, help: "The recorder listens to its keys") {}
            Word(text: "OFF", color: .off, help: "Stop it and quit", action: quit)
            Spacer()
            // v4 (Marko, 31.10.2026: "On, off and top"): TOP, green = the window stays above every other window
            Word(text: "TOP", color: s.onTop ? .on : .off, help: "Always on top: green, the window stays above every other window", ax: "top") {
                s.onTop.toggle(); s.save(); e.changed()
                NSApp.windows.first { $0.title == "Macro Recorder (Mantra)" }?.level = s.onTop ? .floating : .normal
            }
            .accessibilityValue(s.onTop ? "on" : "off")
            // v3 (Marko, 30.10.2026): a permission missing, "Permissions" at the top right; a click opens its page
            if !Permissions.state().all {
                Word(text: "PERMISSIONS", color: .amber, help: "A permission is missing: this opens its page in System Settings") { Permissions.openMissing() }
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundColor(.off).frame(width: 30, height: 30) }
                .buttonStyle(.plain).focusable(false).help("Close the window (it stays ON)")
                .accessibilityLabel("Close window").accessibilityIdentifier("close")
        }
    }

    // MARK: the transport

    func lamp(_ word: String, _ lit: Bool, _ c: Color, _ cap: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            VStack(spacing: 4) {
                Circle().fill(lit ? c : Color.slate).frame(width: 8, height: 8)
                Text(word).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(lit ? c : .sand)
                Text(cap).font(.system(size: 10, design: .monospaced)).foregroundColor(.off)
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.slate.opacity(0.6)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var readout: String {
        if e.recording { return "recording" + (e.pending.map { ": " + $0 } ?? "") }
        if e.playing { return "playing: " + e.playName }
        if let er = e.lastError { return er.name + ": " + er.msg }
        return "in the player: " + (e.current ?? ((e.text ?? "").isEmpty ? (has(LAST_AHK) ? "last recording" : "nothing") : "last recording"))
    }
    var transport: some View {
        Section(title: "MACRO RECORDER") {
            Text(readout).font(.system(size: 12, design: .monospaced))
                .foregroundColor(e.lastError != nil && !e.playing ? .rec : .amber).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                lamp("RECORD", e.recording, .rec, keyLabel(s.keys["record"])) { e.toggleRecording() }
                lamp("PLAY", e.playing, .on, keyLabel(s.keys["play"])) { e.togglePlay() }
                lamp("STOP", false, .sand, keyLabel(s.keys["stop"])) { e.stopAll() }
            }
            HStack(spacing: 8) {
                TextField(Macros.croName(), text: $newName).textFieldStyle(.roundedBorder)
                Button("Record new") { e.newMacroNamed(newName); newName = "" }
                Button("Write new") { if let n = e.newScript(newName) { newName = ""; edit(n) } }
            }
            Text("Record new: do the thing, then press the record key to stop. Write new: an empty script opens in the editor. Either lands in the first free slot.")
                .font(.system(size: 11)).foregroundColor(.off).fixedSize(horizontal: false, vertical: true)
            if !e.note.isEmpty { Text(e.note).font(.system(size: 11, design: .monospaced)).foregroundColor(.off).fixedSize(horizontal: false, vertical: true) }
        }
    }

    // MARK: the permissions (v2, 30.10.2026, Marko: "open permissions for screen capture or whatever is missing")

    func perm(_ name: String, _ ok: Bool, _ what: String, _ pane: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Color.on : Color.amber).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(ok ? .on : .amber)
                Text(ok ? what : what + ": not allowed yet").font(.system(size: 10)).foregroundColor(.off).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Word(text: ok ? "ALLOWED" : "OPEN", color: ok ? .off : .amber, help: "System Settings → Privacy & Security") {
                Permissions.ask(pane)
            }
        }
    }
    var permissions: some View {
        let p = Permissions.state()
        return Section(title: "PERMISSIONS", hint: p.all ? "" : "OPEN takes you to the page in System Settings; switch Macro Recorder (Mantra) on there. The window notices by itself.") {
            perm("ACCESSIBILITY", p.access, "plays the clicks and keys", "Accessibility")
            perm("INPUT MONITORING", p.input, "records the keys and clicks", "ListenEvent")
            perm("SCREEN RECORDING", p.screen, "finds a button from its picture", "ScreenCapture")
        }
    }


    var slots: some View {
        let L = modsLabel(s.loadMods), R = modsLabel(s.runMods)
        let names = Set(Macros.list())
        return Section(title: "SLOTS", hint: "\(L)digit puts the slot's macro in the player. \(R)digit runs it. Drag a row, or use the arrows, to reorder.") {
            ForEach(Array(Slots.ORDER.enumerated()), id: \.offset) { i, k in
                let n = s.slots[k]
                let missing = n != nil && !names.contains(n!)
                HStack(spacing: 8) {
                    Text("⋮⋮").foregroundColor(.off).font(.system(size: 11))
                    Text(k).font(.system(size: 14, weight: .bold, design: .monospaced)).frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.slate))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n ?? "empty").foregroundColor(n == nil ? .off : (e.current == n ? .amber : .sand)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        Text(missing ? "not in the folder" : "\(L)\(k) loads · \(R)\(k) runs").font(.system(size: 10)).foregroundColor(missing ? .rec : .off)
                    }
                    Spacer(minLength: 4)
                    Word(text: "▶", color: n != nil && !missing ? .on : .slate, help: "run now") { if n != nil && !missing { e.runSlot(k) } }
                    Word(text: "▲", color: i > 0 ? .sand : .slate, help: "move up") { if i > 0 { Slots.swap(&s.slots, k, Slots.ORDER[i - 1]); e.slotsChanged() } }
                    Word(text: "▼", color: i < 9 ? .sand : .slate, help: "move down") { if i < 9 { Slots.swap(&s.slots, k, Slots.ORDER[i + 1]); e.slotsChanged() } }
                    Word(text: "×", color: n != nil ? .sand : .slate, help: "empty this slot") { Slots.clear(&s.slots, k); e.slotsChanged() }
                }
                .padding(.vertical, 2)
                .onDrag { dragging = k; return NSItemProvider(object: k as NSString) }
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    if let f = dragging { Slots.move(&s.slots, f, k); e.slotsChanged() }
                    dragging = nil; return true
                }
            }
        }
    }

    // MARK: the macros

    var macros: some View {
        let list = Macros.list()
        return Section(title: "MACROS IN THE FOLDER", hint: list.isEmpty ? "None yet: record one, or write one." : "Click a name to rename it. A digit puts it in that slot.") {
            ForEach(list, id: \.self) { n in
                let info = Macros.info(n)
                let slot = Slots.slotOf(s.slots, n)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if renaming == n {
                            TextField("name", text: $renameText, onCommit: { e.rename(n, renameText); renaming = nil })
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Text(n).foregroundColor(e.current == n ? .amber : .sand).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                .onTapGesture { renaming = n; renameText = n }
                        }
                        Spacer(minLength: 4)
                        Word(text: "▶", color: .on, help: "run now") { e.runNamed(n) }
                        Word(text: "LOAD", color: e.current == n ? .amber : .sand, help: "put it in the player") { _ = e.loadMacro(n) }
                        Word(text: "EDIT", help: "open in the script editor") { edit(n) }
                        Word(text: armed == n ? "SURE?" : "BIN", color: armed == n ? .rec : .off, help: "move to the trash folder") {
                            if armed == n { e.trash(n); armed = nil } else { armed = n }
                        }
                    }
                    Text(info.bad ? "cannot read" : (info.kind == "script" ? "\(info.lines) lines" : "\(info.events) events, a recording")
                         + (info.recorded.isEmpty ? "" : " · " + info.recorded))
                        .font(.system(size: 10)).foregroundColor(info.bad ? .rec : .off)
                    HStack(spacing: 2) {
                        ForEach(Slots.ORDER, id: \.self) { d in
                            Word(text: d, color: slot == d ? .on : .off, size: 11, help: slot == d ? "take it out of slot \(d)" : "put it in slot \(d)") {
                                if slot == d { Slots.clear(&s.slots, d) } else { Slots.assign(&s.slots, d, n) }
                                e.slotsChanged()
                            }
                        }
                    }
                }.padding(.vertical, 3)
                Divider().background(Color.slate)
            }
        }
    }

    // MARK: the pictures

    var pictures: some View {
        let list = Pictures.list()
        return Section(title: "PICTURES", hint: "ClickImage \"name.png\" finds a picture on the screen and clicks its centre. A zone is faster and cannot be fooled by something similar elsewhere.") {
            TextField("button name", text: $picName).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Snap button") { e.snap(picName); picName = "" }.help("drag over the button; it searches all screens")
                Button("Snap & set zone") { e.newPattern(picName); picName = "" }.help("two steps: snap the button, then drag its search zone")
            }
            ForEach(list, id: \.self) { f in
                let z = s.zones[f]
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if let img = NSImage(contentsOfFile: IMG_DIR + "/" + f) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 64, height: 28)
                                .background(Color.slate)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            Text(z.map { "zone \(Int($0.x)), \(Int($0.y))  \(Int($0.w)) × \(Int($0.h))" } ?? "all screens")
                                .font(.system(size: 10)).foregroundColor(z == nil ? .off : .amber)
                        }
                    }
                    HStack(spacing: 4) {
                        Word(text: "FIND", help: "find it on the screen now and move the mouse there") { e.findTest(f) }
                        Word(text: "ZONE", color: z == nil ? .sand : .amber, help: "draw the rectangle of the screen where it is searched") { e.setZone(f) }
                        Word(text: "ALL", color: z == nil ? .slate : .sand, help: "search every screen again") { if z != nil { e.clearZone(f) } }
                        Word(text: armed == "img:" + f ? "SURE?" : "BIN", color: armed == "img:" + f ? .rec : .off, help: "move to the trash folder") {
                            if armed == "img:" + f { e.trashPicture(f); armed = nil } else { armed = "img:" + f }
                        }
                    }.padding(.leading, 68)
                }
            }
        }
    }

    // MARK: the keys

    func modToggles(_ which: String, _ cur: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(MOD_ORDER, id: \.self) { m in
                Word(text: GLYPH[m]!, color: cur.contains(m) ? .on : .off, size: 14) {
                    var n = cur; if let i = n.firstIndex(of: m) { n.remove(at: i) } else { n.append(m) }
                    e.setMods(which, n)
                }
            }
        }
    }
    var keys: some View {
        Section(title: "KEYS", hint: "Change, then press the new chord with a modifier (or a function key). Esc keeps the old one. A chord already in use is refused.") {
            ForEach(ACTIONS, id: \.id) { a in
                HStack {
                    Text(a.label).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(e.capturing == a.id ? "press…" : keyLabel(s.keys[a.id]))
                        .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(e.capturing == a.id ? .amber : .sand)
                    Word(text: "CHANGE", color: e.capturing == nil ? .sand : .slate) { if e.capturing == nil { e.captureKey(a.id) } }
                }
            }
            HStack { Text("Load a slot: modifiers + digit").font(.system(size: 12)); Spacer(); modToggles("loadMods", s.loadMods) }
            HStack { Text("Run a slot: modifiers + digit").font(.system(size: 12)); Spacer(); modToggles("runMods", s.runMods) }
            Word(text: "BACK TO THE DEFAULT KEYS", color: .sand) { e.resetKeys() }
        }
    }

    // MARK: playback, the window, the folder

    var playback: some View {
        Section(title: "PLAYBACK", hint: "Speed divides every Sleep. Delay between clicks puts every click at least that long after the last one.") {
            HStack(spacing: 4) {
                Text("Speed").font(.system(size: 12)).frame(width: 64, alignment: .leading)
                ForEach(Settings.SPEEDS, id: \.self) { v in
                    Word(text: (v == 0.5 ? "½" : "\(Int(v))") + "×", color: s.speed == v ? .on : .off) { s.speed = v; s.save(); e.changed() }
                }
            }
            HStack(spacing: 4) {
                Text("Delay").font(.system(size: 12)).frame(width: 64, alignment: .leading)
                ForEach(Settings.DELAYS, id: \.self) { v in
                    Word(text: v == 0 ? "AS RECORDED" : (v == 0.25 ? "¼ s" : v == 0.5 ? "½ s" : "\(Int(v)) s"), color: s.clickDelay == v ? .on : .off) {
                        s.clickDelay = v; s.save(); e.changed()
                    }
                }
            }
        }
    }
    var window: some View {
        Section(title: "WINDOW AND FOLDER") {
            HStack(spacing: 8) {
                Word(text: "OPEN AT START", color: s.autoSmall ? .on : .off, help: "the window opens when the app starts (not at login)") { s.autoSmall.toggle(); s.save(); e.changed() }
            }
            HStack(spacing: 8) {
                Word(text: "MACROS FOLDER") { mkdirs(MAC_DIR); NSWorkspace.shared.open(URL(fileURLWithPath: MAC_DIR)) }
                Word(text: "PICTURES FOLDER") { mkdirs(IMG_DIR); NSWorkspace.shared.open(URL(fileURLWithPath: IMG_DIR)) }
                Word(text: "THE LANGUAGE", action: docs)
            }
        }
    }
    var foot: some View {
        HStack {
            Button("v\(VERSION)") { NSWorkspace.shared.open(URL(string: RELEASES)!) }.buttonStyle(.plain)
                .font(.system(size: 10)).foregroundColor(.off.opacity(0.6))
            Spacer()
        }
    }
}
