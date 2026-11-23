import AppKit
import CapioCore
import ServiceManagement
import SwiftUI

/// The five panes of the settings window, in toolbar order.
enum SettingsTab: Int, CaseIterable {
    case general, screenshots, screencasts, sharing, shortcuts

    var title: String {
        switch self {
        case .general: return "General"
        case .screenshots: return "Screenshots"
        case .screencasts: return "Screencasts"
        case .sharing: return "Sharing"
        case .shortcuts: return "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .screenshots: return "camera"
        case .screencasts: return "video"
        case .sharing: return "link"
        case .shortcuts: return "keyboard"
        }
    }
}

/// Preference window with the tabs in the toolbar; the window grows and shrinks with the pane.
@MainActor
enum SettingsWindow {
    /// `initial` is selected before the window exists, so the window is born at that pane's size.
    static func make(initial: SettingsTab = .general) -> (NSWindow, NSTabViewController) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.title = "Capio Settings"
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPane(tab: tab))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = initial.rawValue
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.center()
        return (w, tabs)
    }
}

struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane()
            case .screenshots: ScreenshotsPane()
            case .screencasts: ScreencastsPane()
            case .sharing: SharingPane()
            case .shortcuts: ShortcutsPane()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accentColor)
    }
}

private struct GeneralPane: View {
    @State private var folder = Prefs.folderDisplay
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var screenOK = ScreenGrabber.hasPermission
    @State private var problem = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Captures folder") {
                    HStack {
                        Text(folder).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Open Capio at login", isOn: $loginItem)
                    .onChange(of: loginItem) { _, on in setLoginItem(on) }
                if !problem.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).font(.callout)
                }
            }
            Section {
                LabeledContent("Screen Recording") {
                    HStack {
                        Text(screenOK ? "Allowed" : "Not allowed").foregroundStyle(screenOK ? Color.green : Color.orange)
                        if !screenOK {
                            Button("Open System Settings") {
                                ScreenGrabber.requestPermission()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenOK = ScreenGrabber.hasPermission
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.folder
        panel.prompt = "Use Folder"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.folder = url
        folder = Prefs.folderDisplay
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = ""
        } catch {
            problem = "Open at login: \(error.localizedDescription)"
            loginItem = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ScreenshotsPane: View {
    @AppStorage(Prefs.Key.screenshotSound) private var sound = false
    @AppStorage(Prefs.Key.drawColor) private var drawColor = 0
    @AppStorage(Prefs.Key.imageFormat) private var format = ImageFormat.png
    @AppStorage(Prefs.Key.imageSize) private var size = ImageSize.retina

    var body: some View {
        Form {
            Section {
                Toggle("Play a sound when a screenshot is taken", isOn: $sound)
                Picker("Drawing colour to start with", selection: $drawColor) {
                    ForEach(Array(Palette.all.enumerated()), id: \.offset) { i, entry in
                        Text(entry.name).tag(i)
                    }
                }
            } footer: {
                Text("While drawing, 1 to 5 switch the colour.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ChoicePicker("Format", ImageFormat.allCases, selection: $format) { $0.title }
                ChoicePicker("Size", ImageSize.allCases, selection: $size) { $0.title }
            } footer: {
                Text(Quality.imageHint(format: format, size: size)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// One row of choices next to each other, like the mockup.
private struct ChoicePicker<Value: Hashable>: View {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    init(_ label: String, _ options: [Value], selection: Binding<Value>, title: @escaping (Value) -> String) {
        self.label = label
        self.options = options
        _selection = selection
        self.title = title
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

private struct ScreencastsPane: View {
    @AppStorage(Prefs.Key.micOn) private var mic = true
    @AppStorage(Prefs.Key.camOn) private var cam = false
    @AppStorage(Prefs.Key.clickRings) private var rings = true
    @AppStorage(Prefs.Key.videoSize) private var videoSize = VideoSize.original
    @AppStorage(Prefs.Key.videoRate) private var videoRate = Quality.defaultVideoRate
    @AppStorage(Prefs.Key.gifWidth) private var gifWidth = Quality.defaultGIFWidth
    @AppStorage(Prefs.Key.gifRate) private var gifRate = Quality.defaultGIFRate

    /// The main display in pixels, for the megabytes in the hint.
    private var screenPixels: (width: Int, height: Int) {
        guard let s = NSScreen.main else { return (2880, 1800) }
        return (Int(s.frame.width * s.backingScaleFactor), Int(s.frame.height * s.backingScaleFactor))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Microphone on when a screencast starts", isOn: $mic)
                Toggle("Webcam on when a screencast starts", isOn: $cam)
                Toggle("Show a ring around mouse clicks", isOn: $rings)
            }
            Section {
                ChoicePicker("Size", VideoSize.allCases, selection: $videoSize) { $0.title }
                ChoicePicker("Frames per second", Quality.videoRates, selection: $videoRate) { "\($0)" }
            } header: {
                Text("Video")
            } footer: {
                Text(Quality.videoHint(size: videoSize, fps: videoRate, screen: screenPixels)).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ChoicePicker("Width", Quality.gifWidths, selection: $gifWidth) { "\($0)" }
                ChoicePicker("Frames per second", Quality.gifRates, selection: $gifRate) { "\($0)" }
            } header: {
                Text("GIF")
            } footer: {
                Text(Quality.gifHint(width: gifWidth, rate: gifRate)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SharingPane: View {
    @State private var server = Prefs.server
    @State private var key = ""
    @State private var hasKey = Keychain.read() != nil
    @State private var upload = Prefs.uploadEnabled
    @State private var status = ""
    @State private var statusOK = true
    @State private var testing = false
    @AppStorage(Prefs.Key.viewerLinks) private var viewerLinks = false

    var body: some View {
        Form {
            Section {
                Toggle("Always create an external link", isOn: $upload)
                    .onChange(of: upload) { _, on in Prefs.uploadEnabled = on }
            } footer: {
                Text("Off: every capture stays on this Mac. Right click a capture in the Capio menu and choose Create External Link. A link works for 7 days; then Capio removes it from Amfora.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField("Amfora address", text: $server, prompt: Text(Prefs.serverExample))
                SecureField("API key", text: $key, prompt: Text(hasKey ? "Saved in your Keychain" : "amf_…"))
                HStack {
                    Button(testing ? "Checking…" : "Save and test") { saveAndTest() }.disabled(testing)
                    if hasKey { Button("Remove key", role: .destructive) { removeKey() } }
                    if !status.isEmpty {
                        Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(statusOK ? Color.green : Color.orange).font(.callout)
                    }
                    Spacer()
                }
            } footer: {
                Text("Make a key in Amfora under Profile, API keys, with full access. It stays in your Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show a preview of the picture, GIF or video", isOn: $viewerLinks)
            } footer: {
                Text("The link then shows the picture, GIF or video at once (…/v/…). Only turn this on when the Capio viewer runs next to your Amfora; without it these links lead nowhere.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func saveAndTest() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let useKey = typed.isEmpty ? (Keychain.read() ?? "") : typed
        guard let cfg = AmforaConfig(address: server, key: useKey) else {
            statusOK = false
            status = useKey.isEmpty ? "Paste your API key first." : "The address must start with https:// (http only on your own network)."
            return
        }
        testing = true
        Task {
            defer { testing = false }
            do {
                let who = try await AmforaClient(cfg: cfg).whoAmI()
                // Only a key that works replaces the saved one.
                if !typed.isEmpty {
                    guard Keychain.save(typed) else { statusOK = false; status = "Could not save the key in your Keychain."; return }
                    key = ""
                    hasKey = true
                }
                Prefs.server = cfg.base.absoluteString
                server = Prefs.server
                statusOK = true
                status = "Connected as \(who)"
            } catch {
                statusOK = false
                status = error.localizedDescription
            }
        }
    }

    private func removeKey() {
        Keychain.delete()
        hasKey = false
        statusOK = true
        status = "Key removed. Captures stay on this Mac."
    }
}

private struct ShortcutsPane: View {
    @State private var keys = Prefs.shortcuts
    @State private var recording: ShortcutAction?
    @State private var problem: (action: ShortcutAction, text: String)?
    @State private var refused = HotKeys.shared.refused
    @State private var monitor: Any?

    private let fixed: [(String, String)] = [
        ("Drawing tool", "A  R  P  T  H  N  O"),
        ("Colour", "1 to 5"),
        ("Undo the last drawing", "⌘Z"),
        ("Take the screenshot", "Return"),
        ("Cancel", "Esc"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    let note = note(for: action)
                    LabeledContent {
                        ShortcutField(shortcut: keys[action], isRecording: recording == action,
                                      onClick: { toggle(action) }, onClear: { change(action, to: nil) })
                    } label: {
                        Text(action.title)
                        Text(note.text).foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                    }
                }
                Button("Restore defaults") { restore() }.disabled(keys == .standard)
            } footer: {
                Text("Click a field and press the new keys, with ⌘, ⌃ or ⌥.")
            }
            Section("In the selection") {
                ForEach(fixed, id: \.0) { row in
                    LabeledContent(row.0) { Text(row.1) }
                }
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stopRecording() }
    }

    private func note(for action: ShortcutAction) -> (text: String, isWarning: Bool) {
        if let problem, problem.action == action { return (problem.text, true) }
        if recording == action { return (keys[action].map { "Esc keeps \($0.display)" } ?? "Esc to stop", false) }
        if refused.contains(action) { return ("Not active: macOS refused these keys.", true) }
        return (action.hint, false)
    }

    /// While a field listens, Capio's own shortcuts are off: otherwise pressing one would start a capture instead.
    private func toggle(_ action: ShortcutAction) {
        let wasRecording = recording == action
        stopRecording()
        if wasRecording { return }
        problem = nil
        recording = action
        HotKeys.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let mods = Shortcut.carbon(cocoaFlags: event.modifierFlags.rawValue)
            if code == 53, mods == 0 { stopRecording(); return nil }
            record(Shortcut(keyCode: code, modifiers: mods, label: Shortcut.label(keyCode: code, characters: event.characters(byApplyingModifiers: []))),
                   for: action)
            return nil
        }
    }

    private func stopRecording() {
        guard recording != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        refused = HotKeys.shared.apply(keys)
    }

    private func record(_ shortcut: Shortcut, for action: ShortcutAction) {
        guard shortcut.isValid else {
            problem = (action, "Use ⌘, ⌃ or ⌥ together with a key.")
            return
        }
        stopRecording()
        change(action, to: shortcut)
    }

    /// Saves only what macOS accepts; a refused or double shortcut leaves the old one in place.
    private func change(_ action: ShortcutAction, to shortcut: Shortcut?) {
        stopRecording()
        let still = keys[action].map { " Still \($0.display)." } ?? ""
        if let shortcut, let owner = keys.owner(of: shortcut, besides: action) {
            problem = (action, "\(shortcut.display) is already used for \(owner.title).\(still)")
            return
        }
        if let shortcut, HotKeys.usedBySystem(shortcut) {
            problem = (action, "\(shortcut.display) is used by macOS.\(still)")
            return
        }
        let candidate = keys.setting(shortcut, for: action)
        if HotKeys.shared.apply(candidate).contains(action) {
            problem = (action, "\(shortcut?.display ?? "This") was refused by macOS.\(still)")
        } else {
            keys = candidate
            Prefs.shortcuts = candidate
            problem = nil
        }
        refused = HotKeys.shared.apply(keys)
    }

    private func restore() {
        stopRecording()
        keys = .standard
        Prefs.shortcuts = .standard
        problem = nil
        refused = HotKeys.shared.apply(keys)
    }
}

/// Shows one shortcut; a click makes it listen for the next key press.
private struct ShortcutField: View {
    let shortcut: Shortcut?
    let isRecording: Bool
    let onClick: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClick) {
                Text(isRecording ? "Type shortcut…" : shortcut?.display ?? "None")
                    .font(isRecording || shortcut == nil ? .body : .system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(isRecording || shortcut == nil ? Color.secondary : Color.primary)
                    .frame(width: 124, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Theme.accentColor : Color.primary.opacity(0.18), lineWidth: isRecording ? 2 : 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Press the new shortcut" : "Shortcut \(shortcut?.display ?? "none"), click to change")
            Button(action: onClear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(shortcut == nil || isRecording ? 0 : 1)
                .disabled(shortcut == nil || isRecording)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove this shortcut")
        }
    }
}
