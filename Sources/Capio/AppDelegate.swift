import AppKit
import Carbon.HIToolbox
import CapioCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let library = Library()
    private lazy var capture = CaptureController(library: library) { [weak self] in self?.showSettings() }
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.runIfAsked() { return }
        Prefs.migrate()
        NSApp.mainMenu = Self.editMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Theme.menuBarIcon
            button.setAccessibilityLabel("Capio")
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: HistoryView(library: library, actions: historyActions()))

        HotKeys.shared.onPress = { [weak self] action in self?.run(action) }
        HotKeys.shared.apply(Prefs.shortcuts)
        capture.onRecordingTick = { [weak self] time in self?.showRecording(time) }

        Toast.shared.onDeleteUpload = { [weak self] r in self?.library.deleteUpload(r) }
        Toast.shared.onDelete = { [weak self] r in self?.library.delete(r) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.library.removeExpiredLinks() }
        }
        Task { [weak self] in
            // Limit: hourly is plenty for a week long link; Amfora ends the share itself even when this Mac sleeps.
            while let self, !Task.isCancelled {
                self.library.removeExpiredLinks()
                try? await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
            }
        }
        Toast.shared.onShowInFinder = { [weak self] r in self?.reveal(r) }
        UpdateController.shared.isBusy = { [weak self] in self?.capture.isBusy ?? false }
        UpdateController.shared.start()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            Toast.shared.showInfo("Capio is in your menu bar", detail: "Press ⌃⌘2 and drag to capture an area. Captures stay on this Mac; right click one in the menu for a link.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdateController.shared.willTerminate()
    }

    /// An accessory app has no menu bar of its own; without an Edit menu ⌘V, ⌘C and ⌘A do nothing in text fields.
    static func editMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Capio")
        appItem.submenu?.addItem(withTitle: "Quit Capio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    /// One entry for the shortcuts and the menu. While a recording runs, every one of them stops it.
    private func run(_ action: ShortcutAction) {
        popover.performClose(nil)
        if !capture.isRecording { Toast.shared.hide() }
        switch action {
        case .area: capture.start(mode: .capture)
        case .quick: capture.start(mode: .capture, quick: true)
        case .window: capture.captureWindow()
        case .screencast: capture.start(mode: .screencast)
        case .gif: capture.start(mode: .gif)
        }
    }

    /// While recording the menu bar shows a red dot and the time; a click there stops.
    private func showRecording(_ time: String?) {
        guard let button = statusItem.button else { return }
        if let time {
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 11)])
            title.append(NSAttributedString(string: time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]))
            button.attributedTitle = title
            button.toolTip = "Click to stop recording"
        } else {
            button.attributedTitle = NSAttributedString()
            button.image = Theme.menuBarIcon
            button.toolTip = nil
            statusItem.length = NSStatusItem.squareLength
        }
    }

    @objc private func statusClicked() {
        if capture.isRecording { capture.stopRecording(); return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let shortcuts = Prefs.shortcuts
            for action in ShortcutAction.allCases {
                let item = menu.addItem(withTitle: action.menuTitle, action: #selector(menuRun(_:)), keyEquivalent: "")
                item.representedObject = action.rawValue
                // Limit: keys with a name (F5, arrows) run fine but are not shown in the menu.
                // ⌘, and ⌘Q belong to Settings and Quit further down.
                if let s = shortcuts[action], let key = s.label == "Space" ? " " : s.label.count == 1 ? s.label.lowercased() : nil,
                   !(s.modifiers == Shortcut.command && [",", "q"].contains(key)) {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = Self.flags(carbon: s.modifiers)
                }
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Open Capio Folder", action: #selector(menuFolder), keyEquivalent: "")
            menu.addItem(withTitle: "Check for Updates…", action: #selector(menuUpdates), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "Quit Capio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            NSApp.activate()
            // The folder may have changed while the popover was closed (Finder, Terminal): look again.
            library.objectWillChange.send()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func menuRun(_ item: NSMenuItem) {
        guard let action = (item.representedObject as? String).flatMap(ShortcutAction.init(rawValue:)) else { return }
        // From the menu the mouse is on the menu bar, not on a window: let the user click the window instead.
        run(action == .window ? .quick : action)
    }

    private static func flags(carbon: Int) -> NSEvent.ModifierFlags {
        let map: [(Int, NSEvent.ModifierFlags)] = [(Shortcut.command, .command), (Shortcut.shift, .shift), (Shortcut.option, .option), (Shortcut.control, .control)]
        return map.reduce(into: []) { if carbon & $1.0 != 0 { $0.insert($1.1) } }
    }
    @objc private func menuFolder() { openFolder() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuUpdates() { UpdateController.shared.checkNow() }

    /// Opens the settings, on `tab` when the caller needs a specific pane.
    func showSettings(_ tab: SettingsTab? = nil) {
        popover.performClose(nil)
        if settingsWindow == nil {
            // First time without a key: start on Sharing, since that is what is missing. Later the tab stays where it was left.
            (settingsWindow, settingsTabs) = SettingsWindow.make(initial: tab ?? (Keychain.read() == nil ? .sharing : .general))
        } else if let tab {
            settingsTabs?.selectedTabViewItemIndex = tab.rawValue
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: Prefs.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.folder)
    }

    private func reveal(_ r: CaptureRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([library.url(for: r)])
    }

    private func historyActions() -> HistoryActions {
        HistoryActions(
            open: { [weak self] r in if let u = self?.library.url(for: r) { NSWorkspace.shared.open(u) } },
            reveal: { [weak self] r in self?.reveal(r) },
            copyFile: { [weak self] r in if let u = self?.library.url(for: r) { Clipboard.copyFile(u) } },
            copyLink: { r in if let l = r.link { Clipboard.copyText(l) } },
            openLink: { r in if let l = r.link, let u = URL(string: l) { NSWorkspace.shared.open(u) } },
            upload: { [weak self] r in
                guard let self else { return }
                if Prefs.amfora == nil { self.showSettings(.sharing); return }
                self.library.upload(r, thumbnail: NSImage(contentsOf: self.library.url(for: r)))
            },
            pin: { [weak self] r in
                guard let self, let src = CGImageSourceCreateWithURL(self.library.url(for: r) as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                PinWindow.show(cg, scale: Exporter.scale(of: src) ?? NSScreen.main?.backingScaleFactor ?? 2)
            },
            copyText: { r in if let t = r.ocrText, !t.isEmpty { Clipboard.copyText(t) } },
            delete: { [weak self] r in self?.library.delete(r) },
            deleteUpload: { [weak self] r in self?.library.deleteUpload(r) },
            openFolder: { [weak self] in self?.openFolder() },
            settings: { [weak self] in self?.showSettings() }
        )
    }
}
