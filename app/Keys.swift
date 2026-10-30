// Keys.swift: key names, the global chords, and catching a new chord from the keyboard.
// The names are Hammerspoon's (hs.keycodes.map), because the recordings and the language were written with them:
// "return", "escape", "f5", "pad7", and for the character keys whatever the current layout types on that key.
import AppKit
import Carbon.HIToolbox

enum KeyMap {
    static let SPECIAL: [String: Int] = [
        "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete, "escape": kVK_Escape,
        "help": kVK_Help, "home": kVK_Home, "pageup": kVK_PageUp, "forwarddelete": kVK_ForwardDelete, "end": kVK_End,
        "pagedown": kVK_PageDown, "left": kVK_LeftArrow, "right": kVK_RightArrow, "down": kVK_DownArrow, "up": kVK_UpArrow,
        "shift": kVK_Shift, "rightshift": kVK_RightShift, "cmd": kVK_Command, "rightcmd": kVK_RightCommand,
        "alt": kVK_Option, "rightalt": kVK_RightOption, "ctrl": kVK_Control, "rightctrl": kVK_RightControl,
        "capslock": kVK_CapsLock, "fn": kVK_Function,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15,
        "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
        "pad.": kVK_ANSI_KeypadDecimal, "pad*": kVK_ANSI_KeypadMultiply, "pad+": kVK_ANSI_KeypadPlus,
        "pad/": kVK_ANSI_KeypadDivide, "pad-": kVK_ANSI_KeypadMinus, "pad=": kVK_ANSI_KeypadEquals,
        "padclear": kVK_ANSI_KeypadClear, "padenter": kVK_ANSI_KeypadEnter,
        "pad0": kVK_ANSI_Keypad0, "pad1": kVK_ANSI_Keypad1, "pad2": kVK_ANSI_Keypad2, "pad3": kVK_ANSI_Keypad3,
        "pad4": kVK_ANSI_Keypad4, "pad5": kVK_ANSI_Keypad5, "pad6": kVK_ANSI_Keypad6, "pad7": kVK_ANSI_Keypad7,
        "pad8": kVK_ANSI_Keypad8, "pad9": kVK_ANSI_Keypad9,
    ]
    // the character keys: every code from A to the grave accent, plus the ISO key left of 1
    static let CHAR_CODES: [Int] = Array(0...50).filter { ![36, 48, 49].contains($0) } + [kVK_ISO_Section]
    static let US: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_S: "s", kVK_ANSI_D: "d", kVK_ANSI_F: "f", kVK_ANSI_H: "h", kVK_ANSI_G: "g",
        kVK_ANSI_Z: "z", kVK_ANSI_X: "x", kVK_ANSI_C: "c", kVK_ANSI_V: "v", kVK_ANSI_B: "b", kVK_ANSI_Q: "q",
        kVK_ANSI_W: "w", kVK_ANSI_E: "e", kVK_ANSI_R: "r", kVK_ANSI_Y: "y", kVK_ANSI_T: "t", kVK_ANSI_1: "1",
        kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_6: "6", kVK_ANSI_5: "5", kVK_ANSI_Equal: "=",
        kVK_ANSI_9: "9", kVK_ANSI_7: "7", kVK_ANSI_Minus: "-", kVK_ANSI_8: "8", kVK_ANSI_0: "0",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_O: "o", kVK_ANSI_U: "u", kVK_ANSI_LeftBracket: "[", kVK_ANSI_I: "i",
        kVK_ANSI_P: "p", kVK_ANSI_L: "l", kVK_ANSI_J: "j", kVK_ANSI_Quote: "'", kVK_ANSI_K: "k",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/",
        kVK_ANSI_N: "n", kVK_ANSI_M: "m", kVK_ANSI_Period: ".", kVK_ANSI_Grave: "`", kVK_ISO_Section: "§",
    ]
    // the character a key types on the current layout, with no modifier (hs.keycodes does the same)
    static func layoutChar(_ code: Int) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0, len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let r = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
            guard r == noErr, len > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: len).lowercased()
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }
    }
    static var codes: [String: Int] = build().0
    static var names: [Int: String] = build().1
    static func build() -> ([String: Int], [Int: String]) {
        var c = SPECIAL, n: [Int: String] = [:]
        for (k, v) in SPECIAL where n[v] == nil { n[v] = k }
        for code in CHAR_CODES {
            let ch = layoutChar(code) ?? US[code]
            guard let ch = ch else { continue }
            if c[ch] == nil { c[ch] = code }
            n[code] = ch
        }
        return (c, n)
    }
    static func reload() { (codes, names) = build() }
    static func flags(_ mods: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        if mods.contains("ctrl") { f.insert(.maskControl) }
        if mods.contains("alt") { f.insert(.maskAlternate) }
        if mods.contains("shift") { f.insert(.maskShift) }
        if mods.contains("cmd") { f.insert(.maskCommand) }
        return f
    }
    static func mods(_ f: CGEventFlags, fn: Bool = false) -> [String] {
        var m: [String] = []
        if f.contains(.maskCommand) { m.append("cmd") }
        if f.contains(.maskAlternate) { m.append("alt") }
        if f.contains(.maskControl) { m.append("ctrl") }
        if f.contains(.maskShift) { m.append("shift") }
        if fn && f.contains(.maskSecondaryFn) { m.append("fn") }
        return m
    }
}

// MARK: the global chords, through Carbon's hot keys (no permission needed for these)

final class Hotkeys {
    static let shared = Hotkeys()
    var refs: [EventHotKeyRef] = []
    var actions: [UInt32: () -> Void] = [:]
    var next: UInt32 = 1
    var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var id = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let a = Hotkeys.shared.actions[id.id] { DispatchQueue.main.async(execute: a) }
            return noErr
        }, 1, &spec, nil, nil)
    }
    // always lets every earlier binding go first, so a changed key never leaves its old chord alive (LESSONS 8)
    func unbindAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []; actions = [:]
    }
    @discardableResult func bind(_ b: Binding, _ fn: @escaping () -> Void) -> Bool {
        install()
        guard let code = KeyMap.codes[b.key] else { return false }
        var m: UInt32 = 0
        if b.mods.contains("cmd") { m |= UInt32(cmdKey) }
        if b.mods.contains("alt") { m |= UInt32(optionKey) }
        if b.mods.contains("ctrl") { m |= UInt32(controlKey) }
        if b.mods.contains("shift") { m |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D414352), id: next)    // "MACR"
        guard RegisterEventHotKey(UInt32(code), m, id, GetApplicationEventTarget(), 0, &ref) == noErr, let r = ref else { return false }
        refs.append(r); actions[next] = fn; next += 1
        return true
    }
}

// MARK: catching a new chord: the next key with a modifier (or a function key) becomes the action's key

final class KeyCapture {
    var monitor: Any?, timer: Timer?
    var id: String?
    // calls back on every key with (mods, name); returns true when it is done
    func start(_ id: String, _ onKey: @escaping (_ mods: [String], _ name: String) -> Bool, _ onTimeout: @escaping () -> Void) {
        stop()
        self.id = id
        Hotkeys.shared.unbindAll()        // a chord already bound would be swallowed by its hot key before we see it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let name = KeyMap.names[Int(e.keyCode)] ?? ""
            let mods = KeyMap.mods(CGEventFlags(rawValue: UInt64(e.modifierFlags.rawValue)))
            if !name.isEmpty, onKey(mods, name) { self?.stop() }
            return nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.stop(); onTimeout() }
    }
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; timer?.invalidate(); timer = nil; id = nil
    }
}
