// BlobPanel.swift: the window of a text blob (v32). It can never become key or main, never activates the app, shows on every
// Space and over full-screen apps, and lets the mouse through unless it is the blob's own small close area (or a sticky blob).
import AppKit

final class BlobPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    static func make(frame: NSRect, interactive: Bool, title: String) -> BlobPanel {
        let p = BlobPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = title
        p.level = .statusBar                                   // the same level as the lock bar: over full-screen apps too
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = !interactive
        p.isReleasedWhenClosed = false
        p.sharingType = .readOnly                              // visible to screen capture and CGWindowList (owner "MacroRecorder")
        return p
    }
}
