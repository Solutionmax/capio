import AppKit
import CapioCore

/// Runs one capture: freeze every display, show the overlays, act on the outcome.
@MainActor
final class CaptureController: OverlayDelegate {
    private var windows: [OverlayWindow] = []
    private var starting = false
    private var session: RecordingSession?
    let library: Library
    let openSettings: () -> Void
    /// The running recording's time for the menu bar, nil when it ends.
    var onRecordingTick: ((String?) -> Void)?

    var isRecording: Bool { session != nil }
    /// Selecting or recording: no update window or restart in between.
    var isBusy: Bool { session != nil || starting || !windows.isEmpty }

    init(library: Library, openSettings: @escaping () -> Void) {
        self.library = library
        self.openSettings = openSettings
    }

    /// `mode` picks what Return does: ⌃⌘2 screenshot, ⌃⌘4 screencast, ⌃⌘5 GIF. While recording, a shortcut stops it.
    /// `quick` takes the screenshot the moment the mouse lets go, without the buttons.
    func start(mode: OverlayAction = .capture, quick: Bool = false) {
        if let session { session.stop(); return }
        guard windows.isEmpty, !starting else { return }
        guard ScreenGrabber.hasPermission else { askForPermission(); return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let shots = try await ScreenGrabber.grabAll()
                guard !shots.isEmpty else { return }
                windows = shots.map { OverlayWindow(frozen: $0, delegate: self) }
                windows.forEach { $0.canvas.setPrimary(mode); $0.canvas.quick = quick }
                NSApp.activate()
                windows.forEach { $0.orderFrontRegardless() }
                let mouse = NSEvent.mouseLocation
                let key = windows.first { $0.frame.contains(mouse) } ?? windows[0]
                key.makeKeyAndOrderFront(nil)
                key.makeFirstResponder(key.canvas)
            } catch {
                log.error("capture failed: \(error.localizedDescription)")
                Toast.shared.showError("Could not capture the screen", detail: error.localizedDescription)
            }
        }
    }

    /// The window under the mouse, without the overlay: one key press, one screenshot. No window there takes the whole screen.
    func captureWindow() {
        if let session { session.stop(); return }
        guard windows.isEmpty, !starting else { return }
        guard ScreenGrabber.hasPermission else { askForPermission(); return }
        let mouse = NSEvent.mouseLocation
        starting = true
        Task {
            defer { starting = false }
            do {
                let shots = try await ScreenGrabber.grabAll()
                guard let shot = shots.first(where: { NSMouseInRect(mouse, $0.screen.frame, false) }) ?? shots.first else { return }
                let frame = shot.screen.frame
                let area = SelectionMath.pick(windows: shot.windows, at: SelectionMath.viewPoint(mouse: mouse, screenFrame: frame),
                                              in: CGRect(origin: .zero, size: frame.size))
                guard let image = Exporter.render(shot.image, selection: area, scale: shot.scale, annotations: []) else { return }
                Flash.show(CGRect(x: frame.minX + area.minX, y: frame.maxY - area.maxY, width: area.width, height: area.height))
                library.saveScreenshot(image, scale: shot.scale)
            } catch {
                log.error("window capture failed: \(error.localizedDescription)")
                Toast.shared.showError("Could not capture the screen", detail: error.localizedDescription)
            }
        }
    }

    func overlayDidBeginSelection(_ canvas: CanvasView) {
        for w in windows where w.canvas !== canvas { w.canvas.clearSelection() }
        if let w = canvas.window, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }

    func overlay(_ canvas: CanvasView, finished action: OverlayAction) {
        let scale = canvas.frozen.scale
        let screen = canvas.frozen.screen
        let area = canvas.selection
        let image = action == .capture || action == .pin ? canvas.export() : nil
        close()
        // Give the keyboard back to the app the user came from, so ⌘V pastes there at once.
        if action != .settings { NSApp.deactivate() }
        switch action {
        case .cancel:
            break
        case .capture:
            if let image { library.saveScreenshot(image, scale: scale) }
        case .pin:
            if let image { PinWindow.show(image, scale: scale) }
        case .settings:
            openSettings()
        case .screencast, .gif:
            if let area { record(action == .gif ? .gif : .screencast, screen: screen, rect: area) }
        }
    }

    /// Stops a running recording (menu bar click, shortcut).
    func stopRecording() { session?.stop() }

    private func record(_ kind: CaptureKind, screen: NSScreen, rect: CGRect) {
        let s = RecordingSession(kind: kind, screen: screen, rect: rect, library: library)
        s.onTick = { [weak self] t in self?.onRecordingTick?(t) }
        s.onEnd = { [weak self] in
            self?.session = nil
            self?.onRecordingTick?(nil)
        }
        session = s
        Task { await s.start() }
    }

    /// Called from inside the overlay's own event handling: keep the windows alive until that has returned.
    private func close() {
        let old = windows
        windows = []
        old.forEach { $0.orderOut(nil) }
        DispatchQueue.main.async { _ = old }
    }

    private func askForPermission() {
        ScreenGrabber.requestPermission()
        let alert = NSAlert()
        alert.messageText = "Capio needs Screen Recording"
        alert.informativeText = "Turn on Capio in System Settings, Privacy & Security, Screen & System Audio Recording. Then use the shortcut again. macOS may ask you to reopen Capio."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A short accent frame around what was just captured, so a screenshot without the overlay is still seen.
@MainActor
enum Flash {
    private static var window: NSWindow?

    /// `rect` in Cocoa screen coordinates. Shown after the picture is taken, so it is never in it.
    static func show(_ rect: CGRect) {
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let frame = NSView(frame: NSRect(origin: .zero, size: rect.size))
        frame.wantsLayer = true
        frame.layer?.borderColor = Theme.accent.cgColor
        frame.layer?.borderWidth = 4
        w.contentView = frame
        window?.orderOut(nil)
        window = w
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.45; w.animator().alphaValue = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            w.orderOut(nil)
            if window === w { window = nil }
        }
    }
}

/// A capture floating above everything, to compare or keep in view.
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []

    static func show(_ image: CGImage, scale: CGFloat) {
        let picture = Exporter.nsImage(image, scale: scale)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, screen.width * 0.6 / picture.size.width, screen.height * 0.6 / picture.size.height)
        let size = NSSize(width: picture.size.width * fit, height: picture.size.height * fit)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        let w = PinWindow(picture: picture, frame: NSRect(origin: origin, size: size))
        open.append(w)
        w.orderFrontRegardless()
        w.makeKey()
    }

    private let picture: NSImage

    init(picture: NSImage, frame: NSRect) {
        self.picture = picture
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = frame.size
        let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.image = picture
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor(white: 0, alpha: 0.25).cgColor
        view.toolTip = "Drag to move · double-click or Esc to close · right-click for more"
        contentView = view
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyPicture), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "w").target = self
        view.menu = menu
    }

    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { closePin() } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    @objc private func copyPicture() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture])
    }

    @objc private func closePin() {
        orderOut(nil)
        PinWindow.open.removeAll { $0 === self }
    }
}
