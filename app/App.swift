// Macro Recorder (Mantra): records what Marko does and writes it down as a script he can read and edit, plays it,
// ten slots on the digit keys, a script editor, and an eye that finds a button from a picture of it.
// The Swift app that replaces macro.lua, script.lua, slots.lua, settings_page.lua, editor_page.lua and find.py under
// Hammerspoon (Marko, 30.10.2026: "please convert the app open on the MacBook Display Recorder to a Swift app").
// Same folder (~/.mantra_macro), same settings.json, same .ahk macros, same keys. The page on :8829 is now this window;
// the editor and the language are windows of their own. The first row is MACRO RECORDER  ON  OFF with the ✕ far right
// (swift-apps.md): OFF lets go of the keys and quits, ✕ closes the window only and the keys keep working.
// v1 (30.10.2026): the conversion.
import AppKit
import SwiftUI

let VERSION = 1
let RELEASES = "https://github.com/markoboskoauroville/MANTRA_MACRO/releases/latest"

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let e = Engine.shared

    func applicationDidFinishLaunching(_ n: Notification) {
        mainMenu()
        e.start()
        e.openWindow = { [weak self] in self?.toggleWindow() }
        buildWindow()
        let atLogin = CommandLine.arguments.contains("--login")
        // the recorder posts clicks and keys (Accessibility); at login it does not ask (swift-apps.md, login is silent)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !atLogin] as CFDictionary)
        if !atLogin && e.settings.autoSmall { show() }
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ n: Notification) { e.stop() }

    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    // the settings key opens the window, and closes it again
    func toggleWindow() { if window.isVisible && window.isKeyWindow { window.orderOut(nil) } else { show() } }

    func buildWindow() {
        let view = MainView(close: { [weak self] in self?.window.performClose(nil) },
                            quit: { NSApp.terminate(nil) },
                            edit: { EditorWindow.show($0) },
                            docs: { DocsWindow.show() })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Macro Recorder (Mantra)"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 380, height: 320)
        window.backgroundColor = GROUND
        window.setFrameAutosaveName("MacroRecorder")
        if !window.setFrameUsingName("MacroRecorder") { window.center() }
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
