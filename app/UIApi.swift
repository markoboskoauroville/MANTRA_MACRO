// UIApi.swift: v43 (28.11.2026). The recorder window's own API on 127.0.0.1:8829, in the style of /dashboard/open: so a test or a
// screenshot can bring up the window, a stored macro, a dialog, without a click or a key on Marko's screen.
//   POST /ui/open {focus: false}       the window on the screen without taking the keyboard; answers its window number
//   POST /ui/preview {macro: "name"}   shows that stored macro in the script view WITHOUT loading it into the player
//                                      (settings.json is not touched); ends by itself after 5 minutes without a call, or /ui/reset
//   POST /ui/dialog {kind}             opens the insert dialog: key, click, move, drag, wheel, text, image, waittext, window
//   POST /ui/select {line} / /ui/edit {line}   selects line N (from 1) / opens its Edit dialog
//   POST /ui/close-dialog              closes the dialog (a capture that waits in it is cancelled)
//   POST /ui/reset                     the window shows the player's macro again
//   POST /ui/close                     the window off the screen (a capture that waits is cancelled)
// A screenshot of the window without a click: `screencapture -l <window_number> file.png`.
import SwiftUI

final class UIBridge: ObservableObject {
    static let shared = UIBridge()
    @Published var seq = 0
    var command: [String: Any] = [:]
    func send(_ c: [String: Any]) { command = c; seq += 1 }
}

enum UIApi {
    static func api(_ method: String, _ path: String, _ j: [String: Any]) -> ([String: Any], Int) {
        guard let d = NSApp.delegate as? AppDelegate, let w = d.window else { return (["ok": false, "error": "no window yet"], 409) }
        func ask(_ op: String) {
            var c = j
            c["op"] = op
            UIBridge.shared.send(c)
        }
        switch (method, path) {
        case ("POST", "/ui/open"):
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            if j["focus"] as? Bool ?? true { d.show() } else { w.orderFrontRegardless() }
            return (["ok": true, "window_number": w.windowNumber, "version": VERSION], 200)
        case ("POST", "/ui/close"):
            InputCapture.shared.cancel()
            ask("reset")
            w.orderOut(nil)
            return (["ok": true], 200)
        case ("POST", "/ui/preview"), ("POST", "/ui/dialog"), ("POST", "/ui/select"), ("POST", "/ui/edit"),
             ("POST", "/ui/close-dialog"), ("POST", "/ui/reset"):
            ask(String(path.dropFirst("/ui/".count)))
            return (["ok": true, "window_number": w.windowNumber], 200)
        case ("GET", "/ui"):
            return (["ok": true, "visible": w.isVisible, "window_number": w.windowNumber, "capture_armed": InputCapture.shared.armed], 200)
        default:
            return (["error": "no such route"], 404)
        }
    }
}
