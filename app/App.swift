// Macro Recorder (Mantra): records what Marko does and writes it down as a script he can read and edit, plays it,
// ten slots on the digit keys, a script editor, and an eye that finds a button from a picture of it.
// The Swift app that replaces macro.lua, script.lua, slots.lua, settings_page.lua, editor_page.lua and find.py under
// Hammerspoon (Marko, 30.10.2026: "please convert the app open on the MacBook Display Recorder to a Swift app").
// Same folder (~/.mantra_macro), same settings.json, same .ahk macros, same keys. The page on :8829 is now this window;
// the editor and the language are windows of their own. The first row is MACRO RECORDER  ON  OFF with the ✕ far right
// (swift-apps.md): OFF lets go of the keys and quits, ✕ closes the window only and the keys keep working.
// v1 (30.10.2026): the conversion.
// v2 (30.10.2026, Marko: "open permissions for screen capture or whatever is missing"): a PERMISSIONS section, and
// Screen Recording asked at start when it is missing (never at login).
// v3 (30.10.2026, Marko: "If permissions are not set, it needs to have text in the top right: Permissions"): PERMISSIONS
// in amber at the top right while one is missing; a click opens that page in System Settings.
// v4 (31.10.2026, Marko: "Each needs to have the same user interface elements. On, off and top."): TOP on the first
// row (the window above every other, the setting "onTop" it already had, applied at launch); KEEP ON TOP and QUIT go
// (TOP and OFF do the same; swift-apps.md "No QUIT"); every word an Accessibility button with a fixed identifier.
// v8 (1.11.2026, Marko: "build a function called recalibrate"): a recording stores the view of every window clicked in;
// RECAL (button, `macro recalibrate`, Recalibrate "name") moves the clicks to where that window is now, by its picture;
// AUTO RECALIBRATE does it before a macro plays when its window moved. Recalibrate.swift, Coords.swift.
// v24 (13.11.2026, Marko: "simply copy the system from the phone to this Mac"): THE INPUT LOCK (Lock.swift, a port of the
// phone's Lock.kt): while any macro runs a thin bar at the top says CLAUDE · what · time left, an event tap swallows his
// hands, TAKE OVER gives the Mac back; macro lock / unlock / lock-status / request, and 127.0.0.1:8829 like the phone.
// v29 (16.11.2026, Marko: "All our tools need to be paused at the same time and need to have this kind of API calls to be
// stopped."): PAUSE / RESUME (Pause.swift): macros stop between steps and continue where they stopped, his hands are free
// while paused, PAUSED in orange in the menu bar; POST :8829/pause /resume, GET /pause; `macro pause|resume|pause-status`.
// And the updater (Updater.swift, MANTRA_MANIFEST kits/mac-updater): it asks to update at start.
// v33 (22.11.2026): quitting is refused while the input lock is held; the blob's ✕ and sticky body answer Accessibility presses.
// v34 (25.11.2026): the input guard as a LEASE (4 s idle, 60 s cap renewed once, 90 s watchdog, holder gone = lifted, queue),
// the bar always on screen (canHide false, screen-saver level, checked every second), ⌃⌥⌘Esc and POST /release-all, his
// app = where his hands last were, keys after an app switch to the clipboard (Lock.swift, Guard.swift).
// v31 (19.11.2026): the save-dialog workflow uses the existing capture, Accessibility and OCR tools; file-rename safely
// renames one regular file in place, preserves its extension and refuses to overwrite a destination.
// v32 (22.11.2026, Marko: "the text blob which needs to pop up and if something needs to be said to me while I'm working on
// computer and you are working in the background ... You can use the computer now."): `macro blob "<text>"` (Blob.swift): a
// quiet panel top centre on the screen where he works, never takes focus; and by itself, when the input lock is released and
// no other lock follows within two seconds, "You can use the computer now". POST :8829/blob, GET /blobs, ~/.mantra_macro/blob_log.jsonl.
import AppKit
import SwiftUI

let VERSION = 44
let APP_NAME = "Macro Recorder (Mantra)"
let RELEASES = "https://mantramacrorecorder.pages.dev"     // v7: its own website (an independent release, 31.10.2026)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let e = Engine.shared
    var lastPerm: String?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        // v28: --bar-shot <file.png> "<text>": the lock bar alone, drawn off screen into a picture (no engine, no lock, no tap)
        if let i = CommandLine.arguments.firstIndex(of: "--bar-shot"), i + 2 < CommandLine.arguments.count {
            InputLock.shared.shot(CommandLine.arguments[i + 2], to: CommandLine.arguments[i + 1]); return
        }
        // v32: --blob-shot <file.png> "<text>" [info|done|ask]: one blob drawn off screen into a picture (no engine, no lock, no server)
        if let i = CommandLine.arguments.firstIndex(of: "--blob-shot"), i + 2 < CommandLine.arguments.count {
            let k = i + 3 < CommandLine.arguments.count ? BlobKind(rawValue: CommandLine.arguments[i + 3]) ?? .info : .info
            BlobCenter.shared.shot(CommandLine.arguments[i + 2], kind: k, to: CommandLine.arguments[i + 1]); return
        }
        mainMenu()
        // v34: a lock left by a run that ended while it was held is cleared and written down; his hands' app is followed;
        // the bars are rebuilt when the displays change. Launched hidden at login (LSLaunchedHidden) the app is unhidden
        // at once: a hidden app's windows never reach the screen (that is why the v33 bar no longer appeared).
        InputLock.shared.startupCheck()
        HandTracker.shared.start()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            InputLock.shared.screensChanged()
        }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if NSApp.isHidden { NSApp.unhideWithoutActivation() } }
        BlobCenter.shared.start()
        e.start()
        _ = Dashboard.shared.launched            // v41: the moment the triggers were armed (the Dashboard's SINCE column)
        e.openWindow = { [weak self] in self?.toggleWindow() }
        buildWindow()
        menuBarIcon()
        let atLogin = CommandLine.arguments.contains("--login")
        // the recorder posts clicks and keys (Accessibility); at login it does not ask (swift-apps.md, login is silent)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !atLogin] as CFDictionary)
        if !atLogin && e.settings.autoSmall { show() }
        if !atLogin && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        // the window notices a permission switched on in System Settings within two seconds
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let p = Permissions.state(), k = "\(p.access)\(p.input)\(p.screen)"
            if k != self?.lastPerm { self?.lastPerm = k; self?.e.changed() }
        }
        Overlay.shared.render()                  // v29: PAUSED shows at once when it was paused before the restart
        Updater.checkAtStart()                   // v29: asks to update when a newer release is Latest
    }
    // v7 (31.10.2026, released on its own, no longer opened from the star): an icon in the menu bar, red while it
    // records and green while it plays, with the window, record, play and quit
    func menuBarIcon() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        si.length = NSStatusItem.variableLength
        si.button?.image = HoverCard.pipedIcon(NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Macro Recorder"))
        si.button?.imagePosition = .imageLeading
        si.button?.attributedTitle = HoverCard.rightPipe()
        let m = NSMenu()
        m.addItem(withTitle: "Open Macro Recorder", action: #selector(openFromMenu), keyEquivalent: "").target = self
        // v41: the Dashboard: everything that is armed or running, with PLAY PAUSE STOP; the title says how many are active
        let di = NSMenuItem(title: Dashboard.shared.menuTitle(), action: #selector(openDashboard), keyEquivalent: "")
        di.target = self; m.addItem(di); dashItem = di
        m.addItem(withTitle: "Record / Stop (⌃⌥⌘R)", action: #selector(recordFromMenu), keyEquivalent: "").target = self
        m.addItem(withTitle: "Play / Stop (⌃⌥⌘P)", action: #selector(playFromMenu), keyEquivalent: "").target = self
        let pi = NSMenuItem(title: "Pause macros", action: #selector(pauseFromMenu), keyEquivalent: "")
        pi.target = self; m.addItem(pi); pauseItem = pi
        m.addItem(.separator())
        m.addItem(withTitle: "Website and donations", action: #selector(siteFromMenu), keyEquivalent: "").target = self
        m.addItem(withTitle: "Quit Macro Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        si.menu = m
        statusItem = si
        HoverCard.attach(to: si) { [weak self] in
            let paused = PauseGate.shared.paused, e = self?.e
            let st = paused ? "PAUSED" : (e?.recording ?? false) ? "RECORDING" : (e?.playing ?? false) ? "PLAYING" : "IDLE"
            let col: NSColor = paused ? ORANGEC : st == "RECORDING" ? .systemRed : st == "PLAYING" ? .systemGreen : .white
            return HoverCard.Content(name: "Macro Recorder (Mantra)", what: "The one hand on the keyboard, mouse and screen", state: st, stateColor: col,
                lines: ["Input lock: \(InputLock.shared.state)", "Macro in player: " + (e?.current ?? "last recording"),
                        "Dashboard: " + (Dashboard.shared.summary().isEmpty ? "nothing armed or running" : Dashboard.shared.summary()),
                        "Pauses this session: \(PauseGate.shared.pauses)" + (paused ? " (by " + PauseGate.shared.by + ")" : ""),
                        "Last message: " + (Overlay.shared.text.isEmpty ? "none" : Overlay.shared.text)])
        }
        Overlay.shared.item = si                 // v15: the messages go beside this icon, not on the screen
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let s = self, let b = s.statusItem?.button else { return }
            let paused = PauseGate.shared.paused
            let tint: NSColor? = paused ? ORANGEC : s.e.recording ? .systemRed : (s.e.playing ? .systemGreen : nil)
            if b.contentTintColor != tint { b.contentTintColor = tint }
            let title = paused ? "Resume macros (PAUSED)" : "Pause macros"
            if s.pauseItem?.title != title { s.pauseItem?.title = title }
            let dt = Dashboard.shared.menuTitle()
            if s.dashItem?.title != dt { s.dashItem?.title = dt }
        }
    }
    @objc func openFromMenu() { show() }
    var dashItem: NSMenuItem?
    @objc func openDashboard() { DashboardWindow.show() }
    var pauseItem: NSMenuItem?
    @objc func pauseFromMenu() { if PauseGate.shared.paused { PauseGate.shared.resume(by: "menu") } else { PauseGate.shared.pause(by: "menu") } }
    @objc func recordFromMenu() { e.toggleRecording() }
    @objc func playFromMenu() { e.playing ? e.stopPlaying() : e.play() }
    @objc func siteFromMenu() { NSWorkspace.shared.open(URL(string: RELEASES)!) }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { show(); return true }
    // v33 (22.11.2026): the app does not quit, by any way (menu, OFF, an Apple-event quit, `macro ax-quit`), while a session holds
    // Marko's keyboard: a quit then would drop the guard in the middle of a test. The lock bar is the sign; quit again after it.
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if InputLock.shared.state == .on || GuardBook.shared.finishing {
            NSLog("[quit] refused: the input lock is held")
            _ = BlobCenter.shared.show(text: "Macro Recorder stays open while a session holds your keyboard. Quit it again after the lock bar has gone.",
                                      kind: .info, seconds: 8, sticky: false, id: "quit-refused")
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { e.stop() }

    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    // the settings key opens the window, and closes it again
    func toggleWindow() { if window.isVisible && window.isKeyWindow { window.orderOut(nil) } else { show() } }

    func buildWindow() {
        let view = MainView(close: { [weak self] in self?.window.performClose(nil) },
                            quit: { DispatchQueue.main.async { NSApp.terminate(nil) } },
                            edit: { EditorWindow.show($0) },
                            docs: { DocsWindow.show() })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Macro Recorder (Mantra)"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 1000, height: 480)
        window.backgroundColor = GROUND
        window.center()
        window.level = e.settings.onTop ? .floating : .normal
    }

    // a hand-made NSApplication has no Edit menu, so ⌘C ⌘V ⌘Z would not work in the editor without one
    func mainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let am = NSMenu(); appItem.submenu = am
        am.addItem(withTitle: "Quit Macro Recorder (Mantra)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); bar.addItem(editItem)
        let em = NSMenu(title: "Edit"); editItem.submenu = em
        em.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        em.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        em.addItem(.separator())
        em.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        em.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        em.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        em.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let f = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f"); f.tag = 1
        em.addItem(f)
        em.addItem(withTitle: "Complete", action: #selector(NSTextView.complete(_:)), keyEquivalent: "\u{1b}")
        NSApp.mainMenu = bar
    }
}

@main struct Main {
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate(); app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
