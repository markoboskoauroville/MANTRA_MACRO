import SwiftUI
import AppKit

final class RecorderSettingsWindow {
    static var current: NSWindow?

    static func show() {
        if let current {
            current.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Settings - Macro Recorder (Mantra)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 460)
        window.center()
        window.contentView = NSHostingView(rootView: RecorderSettingsView(close: { window.performClose(nil) }))
        window.contentView?.wantsLayer = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            current = nil
        }
        current = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct RecorderSettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case recording = "Recording"
        case playback = "Playback"
        case hotkeys = "Hotkeys"
        case interface = "User Interface"
        case network = "Network"
        case ai = "AI"
        var id: String { rawValue }
    }

    @ObservedObject var engine = Engine.shared
    @State private var page: Page = .recording
    var close: () -> Void

    private var settings: Settings { engine.settings }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(Page.allCases, id: \.id, selection: $page) { item in
                    Text(item.rawValue).padding(.vertical, 4).tag(item)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: 170)
                .background(Color.card)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(page.rawValue).font(.system(size: 20, weight: .semibold))
                        pageContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.ground)
            }
            HStack {
                Button("Reset settings") { reset() }
                Spacer()
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Help") { DocsWindow.show() }
            }
            .padding(10)
            .background(Color.card)
        }
        .foregroundColor(.sand)
        .background(Color.ground)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .recording: recording
        case .playback: playback
        case .hotkeys: hotkeys
        case .interface: interface
        case .network: information(
            "Local engine",
            "Recording, playback, OCR and image search run on this Mac. Mantra does not need a proxy or external recording service."
        )
        case .ai: information(
            "AI-ready, local by default",
            "Apple Vision handles OCR and Mantra's image engine handles visual clicks on-device. Macro Recorder can also expose the same screen tools through its localhost API."
        )
        }
    }

    private var recording: some View {
        settingsGroup("Mouse") {
            Toggle("Record mouse paths", isOn: bool(\.recordMousePaths))
                .help("Writes mouse movement between clicks as MouseMove actions.")
            slider("Minimum mouse movement", value: double(\.minMouseMovement), range: 1...30, format: "%.0f px")
            slider("Mouse sensitivity", value: double(\.mouseSensitivity), range: 0...100, format: "%.0f%%")
        }
        .overlayGroup("Keyboard") {
            Toggle("Capture keyboard input as combined text", isOn: bool(\.combineText))
                .help("Groups ordinary typing into one Send action.")
        }
        .overlayGroup("Timing") {
            slider("Minimum wait time", value: double(\.minWaitMs), range: 20...2000, format: "%.0f ms")
        }
    }

    private var playback: some View {
        settingsGroup("Playback") {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundColor(.on)
                VStack(alignment: .leading) {
                    Text("Input protection is always on")
                    Text("The Mac is locked while a macro uses keyboard or mouse; TAKE OVER gives it back.")
                        .font(.system(size: 11)).foregroundColor(.off)
                }
            }
            HStack {
                Text("Speed")
                Spacer()
                Picker("", selection: valueBinding(\.speed)) {
                    ForEach(Settings.SPEEDS, id: \.self) { Text("\($0.clean)x").tag($0) }
                }.frame(width: 130).labelsHidden()
            }
            HStack {
                Text("Delay between clicks")
                Spacer()
                Picker("", selection: valueBinding(\.clickDelay)) {
                    ForEach(Settings.DELAYS, id: \.self) { Text($0 == 0 ? "As recorded" : "\($0.clean)s").tag($0) }
                }.frame(width: 160).labelsHidden()
            }
            Toggle("Recalibrate moved windows before playback", isOn: bool(\.autoRecal))
        }
    }

    private var hotkeys: some View {
        settingsGroup("Recording and playback") {
            ForEach(ACTIONS, id: \.id) { action in
                HStack {
                    Text(action.label).frame(maxWidth: .infinity, alignment: .leading)
                    Text(engine.capturing == action.id ? "Press the new shortcut…" : keyLabel(settings.keys[action.id]))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(engine.capturing == action.id ? .amber : .sand)
                    Button(engine.capturing == action.id ? "Cancel" : "Change") {
                        if engine.capturing == action.id { engine.capturing = nil; engine.bindKeys(); engine.changed() }
                        else { engine.captureKey(action.id) }
                    }
                }
            }
        }
    }

    private var interface: some View {
        settingsGroup("Window") {
            Toggle("Open the recorder window at start", isOn: bool(\.autoSmall))
            Toggle("Keep the recorder on top", isOn: bool(\.onTop))
            Button("Show permissions") { Permissions.openMissing() }
            Text("Mantra messages remain in the menu bar unless the recorder needs your attention.")
                .font(.system(size: 11)).foregroundColor(.off)
        }
    }

    private func information(_ title: String, _ text: String) -> some View {
        settingsGroup(title) {
            Text(text).fixedSize(horizontal: false, vertical: true).foregroundColor(.off)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.off)
            Divider().background(Color.slate)
            content()
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
    }

    private func bool(_ keyPath: WritableKeyPath<Settings, Bool>) -> SwiftUI.Binding<Bool> {
        var target = engine.settings
        return SwiftUI.Binding(
            get: { target[keyPath: keyPath] },
            set: { target[keyPath: keyPath] = $0; save() }
        )
    }

    private func double(_ keyPath: WritableKeyPath<Settings, Double>) -> SwiftUI.Binding<Double> {
        var target = engine.settings
        return SwiftUI.Binding(
            get: { target[keyPath: keyPath] },
            set: { target[keyPath: keyPath] = $0; save() }
        )
    }

    private func valueBinding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> SwiftUI.Binding<T> {
        var target = engine.settings
        return SwiftUI.Binding(
            get: { target[keyPath: keyPath] },
            set: { target[keyPath: keyPath] = $0; save() }
        )
    }

    private func slider(_ title: String, value: SwiftUI.Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).frame(width: 60, alignment: .trailing)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func save() {
        settings.save()
        if page == .interface {
            NSApp.windows.first { $0.title == APP_NAME }?.level = settings.onTop ? .floating : .normal
        }
        engine.changed()
    }

    private func reset() {
        settings.resetKeys()
        settings.recordMousePaths = false
        settings.minMouseMovement = 5
        settings.mouseSensitivity = 90
        settings.combineText = true
        settings.minWaitMs = 500
        settings.speed = 1
        settings.clickDelay = 0
        settings.autoSmall = true
        settings.onTop = false
        settings.autoRecal = true
        settings.save()
        engine.bindKeys()
        engine.changed()
    }
}

private extension View {
    @ViewBuilder
    func overlayGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.off)
            Divider().background(Color.slate)
            content()
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
    }
}

private extension Double {
    var clean: String {
        self == rounded() ? String(Int(self)) : String(format: "%.2g", self)
    }
}
