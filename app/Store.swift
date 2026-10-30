// Store.swift: the files under ~/.mantra_macro, the settings, the ten slots, the macros.
// The same folder and the same settings.json the Lua recorder used (macro.lua, slots.lua), so every macro, picture,
// zone and slot he made before 30.10.2026 is there in the Swift app as it was.
import Foundation

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let DIR = HOME + "/.mantra_macro"
let MAC_DIR = DIR + "/macros"          // the named ones, <name>.ahk (and <name>.json from before the language)
let IMG_DIR = DIR + "/images"          // the pictures ClickImage looks for
let REC_DIR = DIR + "/recordings"      // the raw events of every recording, kept by date
let TRASH_DIR = DIR + "/trash"         // whatever the bin removed, never deleted
let TMP_DIR = DIR + "/tmp"
let SET_FILE = DIR + "/settings.json"
let LAST_AHK = DIR + "/last.ahk"       // the plain last recording, what Play plays with no macro chosen
let LAST_JSON = DIR + "/last.json"

let fm = FileManager.default
func has(_ p: String) -> Bool { fm.fileExists(atPath: p) }
func mkdirs(_ ps: String...) { for p in ps { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true) } }
func readText(_ p: String) -> String? { try? String(contentsOfFile: p, encoding: .utf8) }
func writeText(_ p: String, _ t: String) -> Bool { (try? t.write(toFile: p, atomically: true, encoding: .utf8)) != nil }

// MARK: the ten slots, slots.lua ported: pure, tested in tests/StoreTests.swift

enum Slots {
    static let ORDER = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    static func valid(_ s: String) -> Bool { ORDER.contains(s) }
    // a table read from disk, made safe: only the ten slots, only names, no name twice (the first slot keeps it)
    static func normalise(_ any: Any?) -> [String: String] {
        var out: [String: String] = [:], seen = Set<String>()
        guard let t = any as? [String: Any] else { return out }   // Lua wrote an empty table as []
        for k in ORDER { if let v = t[k] as? String, !v.isEmpty, !seen.contains(v) { out[k] = v; seen.insert(v) } }
        return out
    }
    static func slotOf(_ s: [String: String], _ name: String) -> String? { ORDER.first { s[$0] == name } }
    // put name into slot: whatever was there is dropped, whatever slot name sat in is emptied
    @discardableResult static func assign(_ s: inout [String: String], _ slot: String, _ name: String) -> String? {
        guard valid(slot) else { return "no slot " + slot }
        guard !name.isEmpty else { return "no name" }
        if let b = slotOf(s, name) { s[b] = nil }
        s[slot] = name; return nil
    }
    static func clear(_ s: inout [String: String], _ slot: String) { s[slot] = nil }
    @discardableResult static func remove(_ s: inout [String: String], _ name: String) -> String? {
        let k = slotOf(s, name); if let k = k { s[k] = nil }; return k
    }
    @discardableResult static func rename(_ s: inout [String: String], _ old: String, _ new: String) -> String? {
        let k = slotOf(s, old); if let k = k { s[k] = new }; return k
    }
    // MOVE, the reorder: like dragging a row in a list, the rows between shift by one, nothing is lost
    static func move(_ s: inout [String: String], _ from: String, _ to: String) {
        guard let a = ORDER.firstIndex(of: from), let b = ORDER.firstIndex(of: to), a != b else { return }
        var list = ORDER.map { s[$0] }
        let m = list.remove(at: a); list.insert(m, at: b)
        for (i, k) in ORDER.enumerated() { s[k] = list[i] }
    }
    static func swap(_ s: inout [String: String], _ a: String, _ b: String) {
        guard valid(a), valid(b) else { return }
        let t = s[a]; s[a] = s[b]; s[b] = t
    }
    static func firstFree(_ s: [String: String]) -> String? { ORDER.first { s[$0] == nil } }
    // a new macro lands in the first free slot by itself
    @discardableResult static func autoPlace(_ s: inout [String: String], _ name: String) -> String? {
        if slotOf(s, name) != nil { return nil }
        guard let k = firstFree(s) else { return nil }
        s[k] = name; return k
    }
}

// MARK: the keys

struct Binding: Equatable { var mods: [String]; var key: String }
let MOD_ORDER = ["ctrl", "alt", "shift", "cmd"]
let ACTIONS: [(id: String, label: String)] = [
    ("record", "Record, and stop recording"),
    ("play", "Play the macro in the player, and stop it"),
    ("stop", "Stop whatever is running"),
    ("newMacro", "New macro: name it, then record"),
    ("settings", "Open the settings window"),
]
let DEFAULT_KEYS: [String: Binding] = [
    "record": Binding(mods: ["ctrl", "alt", "cmd"], key: "r"),
    "play": Binding(mods: ["ctrl", "alt", "cmd"], key: "p"),
    "stop": Binding(mods: ["ctrl", "alt", "cmd"], key: "."),
    "newMacro": Binding(mods: ["ctrl", "alt", "cmd"], key: "n"),
    "settings": Binding(mods: ["ctrl", "alt", "cmd"], key: "m"),
]
let DEFAULT_LOAD = ["alt"], DEFAULT_RUN = ["ctrl"]
func sameMods(_ a: [String], _ b: [String]) -> Bool { Set(a) == Set(b) }
func cleanMods(_ m: [String]) -> [String] { MOD_ORDER.filter { m.contains($0) } }

let GLYPH = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
let KEYLABEL = ["escape": "Esc", "space": "Space", "return": "↩", "tab": "⇥", "delete": "⌫", "forwarddelete": "⌦",
                "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "Home", "end": "End",
                "pageup": "PgUp", "pagedown": "PgDn"]
func modsLabel(_ m: [String]) -> String { MOD_ORDER.filter { m.contains($0) }.map { GLYPH[$0]! }.joined() }
func keyLabel(_ b: Binding?) -> String {
    guard let b = b, !b.key.isEmpty else { return "none" }
    return modsLabel(b.mods) + (KEYLABEL[b.key] ?? (b.key.count == 1 ? b.key.uppercased() : b.key))
}

// MARK: the settings, read and written as the Lua did (keys it does not know are kept)

struct Zone: Equatable { var x, y, w, h: Double }

final class Settings {
    var raw: [String: Any] = [:]
    var speed = 1.0, clickDelay = 0.0, ignoreTravel = false
    var autoSmall = true, onTop = false
    var keys = DEFAULT_KEYS, loadMods = DEFAULT_LOAD, runMods = DEFAULT_RUN
    var slots: [String: String] = [:]
    var zones: [String: Zone] = [:]
    var current: String?

    static let SPEEDS = [0.5, 1, 2, 4, 8]
    static let DELAYS = [0, 0.25, 0.5, 1, 2]

    func load() {
        guard let d = fm.contents(atPath: SET_FILE), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        raw = j
        speed = (j["speed"] as? Double) ?? 1
        clickDelay = (j["clickDelay"] as? Double) ?? 0
        ignoreTravel = (j["ignoreTravel"] as? Bool) ?? false
        autoSmall = (j["autoSmall"] as? Bool) ?? true
        onTop = (j["onTop"] as? Bool) ?? false
        current = j["current"] as? String
        slots = Slots.normalise(j["slots"])
        zones = [:]
        if let z = j["zones"] as? [String: Any] {
            for (k, v) in z {
                guard let v = v as? [String: Any], let x = v["x"] as? Double, let y = v["y"] as? Double,
                      let w = v["w"] as? Double, let h = v["h"] as? Double, w > 0, h > 0 else { continue }
                zones[k] = Zone(x: x, y: y, w: w, h: h)
            }
        }
        keys = DEFAULT_KEYS
        if let k = j["keys"] as? [String: Any] {
            for (id, v) in k {
                if id == "loadMods", let m = v as? [String], !m.isEmpty { loadMods = cleanMods(m) }
                else if id == "runMods", let m = v as? [String], !m.isEmpty { runMods = cleanMods(m) }
                else if DEFAULT_KEYS[id] != nil, let b = v as? [String: Any], let key = b["key"] as? String {
                    keys[id] = Binding(mods: cleanMods(b["mods"] as? [String] ?? []), key: key)
                }
            }
        }
    }
    func save() {
        mkdirs(DIR)
        var j = raw
        j["speed"] = speed; j["clickDelay"] = clickDelay; j["ignoreTravel"] = ignoreTravel
        j["autoSmall"] = autoSmall; j["onTop"] = onTop
        j["current"] = current ?? NSNull()
        j["slots"] = slots
        j["zones"] = zones.mapValues { ["x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] }
        var k: [String: Any] = ["loadMods": loadMods, "runMods": runMods]
        for (id, b) in keys { k[id] = ["mods": b.mods, "key": b.key] }
        j["keys"] = k
        if j["current"] is NSNull { j.removeValue(forKey: "current") }
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: SET_FILE), options: .atomic)
        }
        raw = j
    }

    // WHAT ALREADY USES THIS CHORD, or nil: a key is refused rather than bound twice
    func usedBy(_ mods: [String], _ key: String, except: String?) -> String? {
        for a in ACTIONS where a.id != except {
            if let b = keys[a.id], b.key == key, sameMods(b.mods, mods) { return a.label }
        }
        if Slots.ORDER.contains(key) {
            if except != "loadMods", sameMods(loadMods, mods) { return "loading slot " + key }
            if except != "runMods", sameMods(runMods, mods) { return "running slot " + key }
        }
        return nil
    }
    func setKey(_ id: String, _ mods: [String], _ key: String) -> String? {
        guard DEFAULT_KEYS[id] != nil else { return "no action " + id }
        if let t = usedBy(mods, key, except: id) { return "that key already does: " + t }
        keys[id] = Binding(mods: cleanMods(mods), key: key); save(); return nil
    }
    // the slot modifiers: each holds at least one modifier, and the two differ
    func setMods(_ which: String, _ mods: [String]) -> String? {
        let clean = cleanMods(mods)
        if clean.isEmpty { return "hold at least one modifier, or the digits could not be typed" }
        if sameMods(clean, which == "loadMods" ? runMods : loadMods) { return "loading and running cannot share one chord" }
        for d in Slots.ORDER { if let t = usedBy(clean, d, except: which) { return "that chord with \(d) already does: " + t } }
        if which == "loadMods" { loadMods = clean } else { runMods = clean }
        save(); return nil
    }
    func resetKeys() { keys = DEFAULT_KEYS; loadMods = DEFAULT_LOAD; runMods = DEFAULT_RUN; save() }
}

// MARK: the macros in the folder

enum Macros {
    static func ahk(_ n: String) -> String { MAC_DIR + "/" + n + ".ahk" }
    static func json(_ n: String) -> String { MAC_DIR + "/" + n + ".json" }
    static func kind(_ n: String) -> String? {
        if n.isEmpty { return nil }
        if has(ahk(n)) { return "script" }
        if has(json(n)) { return "recording" }
        return nil
    }
    static func exists(_ n: String) -> Bool { kind(n) != nil }
    static func list() -> [String] {
        var set = Set<String>()
        for f in (try? fm.contentsOfDirectory(atPath: MAC_DIR)) ?? [] where !f.hasPrefix(".") {
            if f.hasSuffix(".ahk") { set.insert(String(f.dropLast(4))) }
            else if f.hasSuffix(".json") { set.insert(String(f.dropLast(5))) }
        }
        return set.sorted { $0.lowercased() < $1.lowercased() }
    }
    // the name a macro gets by itself, Croatian style (4.9.2026): day, month, hour. "4.9. 18.52"
    static func croName(_ d: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .hour, .minute], from: d)
        return String(format: "%d.%d. %02d.%02d", c.day!, c.month!, c.hour!, c.minute!)
    }
    // safe as a file name: no slashes, colons or control characters, no leading dot
    static func clean(_ s: String) -> String {
        var t = String(s.unicodeScalars.map { "/\\:".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) ? "-" : Character($0) })
        t = t.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        return t
    }
    static func readRecording(_ p: String) -> (events: [RecEvent], recorded: String)? {
        guard let d = fm.contents(atPath: p), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let evs = j["events"] else { return nil }
        // Lua wrote an empty event list as {} and a full one as [...]
        let arr = (evs as? [Any]) ?? []
        guard let ed = try? JSONSerialization.data(withJSONObject: arr),
              let list = try? JSONDecoder().decode([RecEvent].self, from: ed) else { return nil }
        return (list, j["recorded"].map { "\($0)" } ?? "")
    }
    // the text of a macro: a script as written, a recording turned into one
    static func read(_ n: String) -> (text: String?, why: String) {
        switch kind(n) {
        case "script": return readText(ahk(n)).map { ($0, "script") } ?? (nil, "cannot read " + n)
        case "recording":
            guard let r = readRecording(json(n)) else { return (nil, "cannot read " + n) }
            return (Script.fromEvents(r.events, keyNames: KeyMap.names, header: [n + ", recorded " + r.recorded]), "recording")
        default: return (nil, "no macro called " + n)
        }
    }
    @discardableResult static func write(_ n: String, _ text: String) -> String? {
        mkdirs(DIR, MAC_DIR)
        guard writeText(ahk(n), text) else { return "cannot write " + n }
        // a recording of the same name is superseded: to the trash folder, never deleted
        if has(json(n)) { mkdirs(TRASH_DIR); try? fm.moveItem(atPath: json(n), toPath: TRASH_DIR + "/" + n + " (recording).json") }
        return nil
    }
    struct Info { var name, kind: String; var lines, events: Int; var recorded: String; var bad: Bool }
    // everything the window shows about one macro, read from disk each time so a rename in the Finder shows
    static func info(_ n: String) -> Info {
        let k = kind(n) ?? "script"
        var i = Info(name: n, kind: k, lines: 0, events: 0, recorded: "", bad: false)
        if k == "script" {
            guard let t = readText(ahk(n)) else { i.bad = true; return i }
            var first: String?
            for l in t.components(separatedBy: "\n") {
                let s = l.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty && !s.hasPrefix(";") { i.lines += 1 }
                if first == nil && s.hasPrefix(";") { first = s.dropFirst().trimmingCharacters(in: .whitespaces) }
            }
            if let f = first, let r = f.range(of: "recorded ") { i.recorded = String(f[r.upperBound...]) }
        } else if let r = readRecording(json(n)) { i.events = r.events.count; i.recorded = r.recorded } else { i.bad = true }
        return i
    }
    static func trash(_ n: String) -> String? {
        mkdirs(TRASH_DIR)
        for ext in [".ahk", ".json"] {
            let from = MAC_DIR + "/" + n + ext
            guard has(from) else { continue }
            var dest = TRASH_DIR + "/" + n + ext
            if has(dest) { dest = TRASH_DIR + "/" + n + " " + stamp() + ext }
            do { try fm.moveItem(atPath: from, toPath: dest) } catch { return "could not move: \(error.localizedDescription)" }
        }
        return nil
    }
    static func rename(_ old: String, _ new: String) -> String? {
        for ext in [".ahk", ".json"] where has(MAC_DIR + "/" + old + ext) {
            do { try fm.moveItem(atPath: MAC_DIR + "/" + old + ext, toPath: MAC_DIR + "/" + new + ext) }
            catch { return "could not rename: \(error.localizedDescription)" }
        }
        return nil
    }
    static func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }
}

enum Pictures {
    static func list() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: IMG_DIR)) ?? [])
            .filter { !$0.hasPrefix(".") && ($0.lowercased().hasSuffix(".png") || $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg")) }
            .sorted { $0.lowercased() < $1.lowercased() }
    }
    static func path(_ f: String) -> String {
        if f.hasPrefix("/") { return f }
        if f.hasPrefix("~/") { return HOME + f.dropFirst(1) }
        return IMG_DIR + "/" + f
    }
}
