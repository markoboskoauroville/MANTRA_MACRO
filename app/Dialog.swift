import AppKit
import ApplicationServices

// v23 (Marko, 13.11.2026, from Mantra Remote Viewing's LOGIN button: "When there is a pop-up ... to enter my password to
// allow keychain or anything while I'm developing apps ... it searches, even the dialog does not need to be in focus. It
// searches through my macOS and looking where is this dialog ... enter the password and always allow. The first option is
// always allow if there is there, if not then just OK."):
//   "login-dialog: <password>"   (inbox; `macro login-dialog` reads the password from stdin; STAR_API POST /login-dialog)
// Every window of every process is searched through Accessibility for a password dialog: a secure text field inside a
// dialog, a sheet or a system prompt (SecurityAgent, coreautha, UserNotificationCenter ...), never inside a web page.
// It is brought forward, the password goes into its secure field (AXValue, else typed into the focused field), and the
// first of ALWAYS ALLOW, ALLOW, OK, UNLOCK ... is pressed. Every such dialog on the screen is answered in one call (a
// codesign build can ask five times). A dialog that is still there after its press is reported (wrong password?) and
// never tried twice in one call, so a wrong password cannot lock the keychain.
// When Accessibility sees no dialog but a SecurityAgent window is on screen, it is brought forward, the password is typed
// into its focused field, and ALWAYS ALLOW / ALLOW / OK is found on its picture (Vision) and clicked; else Return.
// The password is never written into an answer, a log or a file.
enum PwDialog {
    /// processes whose windows are system prompts even when they do not call themselves dialogs
    static let systemProcs: Set<String> = ["securityagent", "coreautha", "coreauthd", "coreauthuiagent",
                                           "usernotificationcenter", "systemuiserver", "authorizationhost",
                                           "installer", "systempreferences", "systemsettings", "keychainaccess",
                                           "softwareupdatenotificationmanager", "storeuid"]
    /// the buttons, in Marko's order: Always Allow first, then OK, then the other words macOS uses for "go on"
    static let buttons = ["alwaysallow", "allow", "ok", "unlock", "modifysettings", "installhelper", "updatesettings",
                          "usepassword", "continue", "install", "signin", "login", "logon"]

    struct Found {
        let app: NSRunningApplication
        let window: AXUIElement
        let title: String
        let field: AXUIElement?
        let buttons: [(String, AXUIElement)]
    }

    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private static func str(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static func procName(_ a: NSRunningApplication) -> String {
        norm(a.localizedName ?? a.executableURL?.lastPathComponent ?? "")
    }

    /// one window looked through: its secure fields (not inside a web page), its buttons, whether a sheet holds them
    private static func scan(_ w: AXUIElement) -> (fields: [AXUIElement], buttons: [(String, AXUIElement)], sheet: Bool) {
        var fields: [AXUIElement] = [], btns: [(String, AXUIElement)] = [], sheet = false
        var stack: [(AXUIElement, Int)] = [(w, 0)], seen = 0
        while let (e, d) = stack.popLast(), seen < 1500 {
            seen += 1
            let role = str(e, kAXRoleAttribute), sub = str(e, kAXSubroleAttribute)
            if role == "AXWebArea" { continue }            // a website's password box is never the Mac's
            if role == "AXSheet" { sheet = true }
            if sub == "AXSecureTextField" { fields.append(e) }
            if role == "AXButton" {
                let t = [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute)].first { !$0.isEmpty } ?? ""
                if !t.isEmpty { btns.append((t, e)) }
            }
            if d < 14, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids.reversed() { stack.append((k, d + 1)) }
            }
        }
        return (fields, btns, sheet)
    }

    /// every password dialog on the Mac, system prompts first
    static func find() -> [Found] {
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [Found] = []
        for a in NSWorkspace.shared.runningApplications where a.processIdentifier != me && !a.isTerminated {
            let pn = procName(a)
            let isSystem = systemProcs.contains(pn)
            let root = AXUIElementCreateApplication(a.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)       // a hung app must not hold the whole search
            for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                let sub = str(w, kAXSubroleAttribute)
                let dialogish = isSystem || sub == "AXDialog" || sub == "AXSystemDialog" || sub == "AXFloatingWindow"
                let s = scan(w)
                let hasGo = s.buttons.contains { buttons.contains(norm($0.0)) }
                if !s.fields.isEmpty && hasGo && (dialogish || s.sheet) {
                    out.append(Found(app: a, window: w, title: str(w, kAXTitleAttribute), field: s.fields.first, buttons: s.buttons))
                } else if s.fields.isEmpty && pn == "securityagent" && s.buttons.contains(where: { norm($0.0) == "alwaysallow" }) {
                    // a keychain prompt that asks no password, only Always Allow / Deny / Allow
                    out.append(Found(app: a, window: w, title: str(w, kAXTitleAttribute), field: nil, buttons: s.buttons))
                }
            }
        }
        return out.sorted { systemProcs.contains(procName($0.app)) && !systemProcs.contains(procName($1.app)) }
    }

    private static func count(_ field: AXUIElement) -> Int? {
        (attr(field, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            ?? (attr(field, kAXValueAttribute) as? String)?.count
    }

    /// typed into whatever has the keyboard focus, character by character, as text (any layout)
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                ev.flags = []
                ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                ev.markedPost()
            }
            Thread.sleep(forTimeInterval: 0.012)
        }
    }
    static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            if let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) { ev.flags = flags; ev.markedPost() }
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
    static func click(_ p: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let back = CGEvent(source: nil)?.location
        for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.markedPost()
            Thread.sleep(forTimeInterval: 0.04)
        }
        if let b = back { CGWarpMouseCursorPosition(b) }        // his pointer goes back where it was
    }
    private static func center(_ e: AXUIElement) -> CGPoint? {
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return s.width > 0 && s.height > 0 ? CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2) : nil
    }

    /// the window still on screen with a password field in it?
    private static func stillThere(_ f: Found) -> Bool {
        guard attr(f.window, kAXRoleAttribute) != nil else { return false }
        let w = (attr(AXUIElementCreateApplication(f.app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard w.contains(where: { CFEqual($0, f.window) }) else { return false }
        return f.field == nil || !scan(f.window).fields.isEmpty
    }

    /// one dialog answered: (what was done, closed?)
    static func answer(_ f: Found, _ pw: String) -> (String, Bool) {
        let who = (f.app.localizedName ?? "?") + (f.title.isEmpty ? "" : " \"\(f.title)\"")
        f.app.activate()
        AXUIElementPerformAction(f.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(f.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.25)
        var how = "no password asked"
        if let field = f.field {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, pw as CFString)
            Thread.sleep(forTimeInterval: 0.1)
            if set == .success, count(field) == pw.count {
                how = "password set"
            } else {
                // the field did not take a value: click into it, empty it, type
                if let c = center(field) { click(c) } else { AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
                Thread.sleep(forTimeInterval: 0.15)
                key(0, .maskCommand)                 // ⌘A
                key(51)                              // ⌫
                type(pw)
                how = "password typed"
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        // the first button of Marko's order the dialog has; else its default button; else Return
        var pressed = ""
        for want in buttons {
            guard let b = f.buttons.first(where: { norm($0.0) == want }) else { continue }
            if AXUIElementPerformAction(b.1, kAXPressAction as CFString) == .success { pressed = b.0 }
            else if let c = center(b.1) { click(c); pressed = b.0 + " (clicked)" }
            if !pressed.isEmpty { break }
        }
        if pressed.isEmpty, let d = attr(f.window, kAXDefaultButtonAttribute) {
            let b = d as! AXUIElement
            if AXUIElementPerformAction(b, kAXPressAction as CFString) == .success { pressed = str(b, kAXTitleAttribute) + " (default)" }
        }
        if pressed.isEmpty { key(36); pressed = "Return" }
        var closed = false
        for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.15); if !stillThere(f) { closed = true; break } }
        return ("\(who): \(how), pressed \(pressed)" + (closed ? "" : ", STILL OPEN (wrong password?)"), closed)
    }

    /// no dialog Accessibility can see, but a SecurityAgent window is on the screen: forward, type, find the button
    static func bySight(_ pw: String) -> (Bool, String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            let owner = norm(w[kCGWindowOwnerName as String] as? String ?? "")
            guard owner == "securityagent" || owner == "coreautha",
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 120, ht > 80 else { continue }
            NSRunningApplication(processIdentifier: pid)?.activate()
            Thread.sleep(forTimeInterval: 0.3)
            type(pw)                                  // SecurityAgent opens with its password field focused
            Thread.sleep(forTimeInterval: 0.15)
            let rect = "rect:\(Int(x)),\(Int(y)),\(Int(wd)),\(Int(ht))"
            let lines = Ocr.read(rect).lines
            var pressed = "Return"
            if let hit = ["alwaysallow", "allow", "ok"].lazy.compactMap({ want in lines.first { norm($0.text) == want } }).first {
                click(CGPoint(x: hit.x + hit.w / 2, y: hit.y + hit.h / 2)); pressed = hit.text + " (by sight)"
            } else { key(36) }
            return (true, "\(w[kCGWindowOwnerName as String] as? String ?? "SecurityAgent") (not readable by Accessibility): password typed, pressed \(pressed)")
        }
        return nil
    }

    /// the whole LOGIN: every password dialog on the Mac answered
    static func run(_ pw: String) -> (Bool, String) {
        guard !pw.isEmpty else { return (false, "no password given") }
        guard AXIsProcessTrusted() else { return (false, "Macro Recorder has no Accessibility permission") }
        let front = NSWorkspace.shared.frontmostApplication
        var done: [String] = [], tried: [AXUIElement] = [], allClosed = true
        for _ in 0..<8 {
            guard let f = find().first(where: { c in !tried.contains { CFEqual($0, c.window) } }) else { break }
            tried.append(f.window)
            let (msg, closed) = answer(f, pw)
            done.append(msg); allClosed = allClosed && closed
            Thread.sleep(forTimeInterval: 0.3)       // the next prompt of a build comes a moment later
        }
        if done.isEmpty {
            if let r = bySight(pw) { return r }
            return (false, "NO DIALOG: no password dialog found on the Mac")
        }
        // his app comes back to the front when every dialog closed
        if allClosed, let a = front, !systemProcs.contains(procName(a)) { a.activate() }
        return (allClosed, done.joined(separator: "\n"))
    }
}
