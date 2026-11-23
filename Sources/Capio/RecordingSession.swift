import AppKit
import AVFoundation
import CapioCore
import ScreenCaptureKit
import SwiftUI

enum Permissions {
    static func microphone() async -> Bool { await ask(.audio) }
    static func camera() async -> Bool { await ask(.video) }

    private static func ask(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
}

@MainActor
final class RecordingModel: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var level: Float = 0
    @Published var micOn = true
    @Published var camOn = false
    @Published var paused = false
    @Published var saving = false
    let kind: CaptureKind

    init(kind: CaptureKind) { self.kind = kind }
}

/// One screencast or GIF: red frame, control bar, optional webcam bubble, click rings, then save and upload.
@MainActor
final class RecordingSession {
    let kind: CaptureKind
    let screen: NSScreen
    /// Display points, top left origin.
    let rect: CGRect
    let model: RecordingModel
    var onTick: ((String) -> Void)?
    var onEnd: (() -> Void)?

    private let library: Library
    private var recorder: ScreenRecorder?
    private var frame: NSWindow?
    private var bar: NSPanel?
    private var camera: CameraBubble?
    private var clicks: ClickLayer?
    private var clickMonitor: Any?
    private var timer: Timer?
    private var startedAt = Date()
    private var pausedTotal: Double = 0
    private var pausedSince: Date?
    private let temp: URL
    /// Read once, so a GIF is made at the rate it was recorded at.
    private let gifRate = Prefs.gifRate

    init(kind: CaptureKind, screen: NSScreen, rect: CGRect, library: Library) {
        self.kind = kind
        self.screen = screen
        self.rect = rect
        self.library = library
        model = RecordingModel(kind: kind)
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("capio-\(UUID().uuidString).mp4")
    }

    /// The area in Cocoa screen coordinates.
    private var cocoaRect: NSRect {
        NSRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    func start() async {
        let mic = kind == .screencast ? await Permissions.microphone() : false
        model.micOn = mic && UserDefaults.standard.object(forKey: Prefs.Key.micOn) as? Bool ?? true
        showFrame()
        showBar()
        if Prefs.clickRings { showClickLayer() }
        if kind == .screencast, UserDefaults.standard.bool(forKey: Prefs.Key.camOn) { await setCamera(true) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenRecorder.Failure(errorDescription: "The display went away.")
            }
            let ours = [bar, frame].compactMap { $0?.windowNumber }.map { CGWindowID($0) }
            let excluded = content.windows.filter { ours.contains($0.windowID) }
            let rec = ScreenRecorder(output: temp)
            rec.onLevel = { [weak model] l in Task { @MainActor in model?.level = l } }
            rec.onStopped = { [weak self] e in Task { @MainActor in self?.fail(e) } }
            // A GIF is recorded at full size and scaled when it is made, so its width stays a free choice.
            try await rec.start(display: display, rect: rect, scale: screen.backingScaleFactor, excluding: excluded,
                                microphone: mic, fps: kind == .gif ? gifRate : Prefs.videoRate,
                                size: kind == .gif ? .original : Prefs.videoSize)
            rec.setMicMuted(!model.micOn)
            recorder = rec
            startedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            tick()
        } catch {
            fail(error)
        }
    }

    // MARK: controls

    func toggleMic() {
        model.micOn.toggle()
        UserDefaults.standard.set(model.micOn, forKey: Prefs.Key.micOn)
        recorder?.setMicMuted(!model.micOn)
    }

    func toggleCamera() {
        Task { await setCamera(!model.camOn) }
    }

    func togglePause() {
        model.paused.toggle()
        recorder?.setPaused(model.paused)
        if model.paused {
            pausedSince = Date()
        } else if let since = pausedSince {
            pausedTotal += Date().timeIntervalSince(since)
            pausedSince = nil
        }
        tick()
    }

    func stop() {
        guard let recorder, !model.saving else { return }
        model.saving = true
        timer?.invalidate()
        tearDown(keepBar: true)
        Task {
            defer { close() }
            do {
                let seconds = try await recorder.stop()
                if kind == .gif {
                    Toast.shared.showWorking("Making your GIF…")
                    let gif = temp.deletingPathExtension().appendingPathExtension("gif")
                    let size = try await GIFMaker.make(from: temp, to: gif, fps: Double(gifRate), maxWidth: CGFloat(Prefs.gifWidth))
                    try? FileManager.default.removeItem(at: temp)
                    library.saveRecording(from: gif, kind: .gif, duration: seconds, pixelSize: size)
                } else {
                    library.saveRecording(from: temp, kind: .screencast, duration: seconds, pixelSize: recorder.pixelSize)
                }
            } catch {
                Toast.shared.showError("Recording failed", detail: error.localizedDescription)
            }
        }
    }

    private func fail(_ error: Error) {
        log.error("recording failed: \(error.localizedDescription)")
        Toast.shared.showError("Recording stopped", detail: error.localizedDescription)
        timer?.invalidate()
        recorder = nil
        close()
    }

    private func tick() {
        let paused = pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        model.elapsed = Date().timeIntervalSince(startedAt) - pausedTotal - paused
        onTick?(CaptureNaming.duration(model.elapsed))
    }

    private func setCamera(_ on: Bool) async {
        if on {
            guard await Permissions.camera() else {
                Toast.shared.showError("No camera access", detail: "Allow Capio in System Settings, Privacy & Security, Camera.")
                return
            }
            let size: CGFloat = min(150, rect.width / 3, rect.height / 2)
            let origin = NSPoint(x: cocoaRect.maxX - size - 14, y: cocoaRect.minY + 14)
            camera = CameraBubble(frame: NSRect(origin: origin, size: NSSize(width: size, height: size)))
            camera?.orderFrontRegardless()
        } else {
            camera?.shutDown()
            camera = nil
        }
        model.camOn = camera != nil
        UserDefaults.standard.set(model.camOn, forKey: "camOn")
    }

    // MARK: windows

    private func showFrame() {
        let w = NSWindow(contentRect: cocoaRect.insetBy(dx: -4, dy: -4), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.level = .statusBar
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = RedFrame()
        w.orderFrontRegardless()
        frame = w
    }

    private func showBar() {
        let host = NSHostingView(rootView: RecordingBar(model: model, mic: { [weak self] in self?.toggleMic() },
                                                        camera: { [weak self] in self?.toggleCamera() },
                                                        pause: { [weak self] in self?.togglePause() },
                                                        stop: { [weak self] in self?.stop() }))
        let size = host.fittingSize
        let local = SelectionMath.barOrigin(selection: rect, barSize: size, bounds: CGRect(origin: .zero, size: screen.frame.size))
        let origin = NSPoint(x: screen.frame.minX + local.x, y: screen.frame.maxY - local.y - size.height)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host
        p.orderFrontRegardless()
        bar = p
    }

    private func showClickLayer() {
        let layer = ClickLayer(frame: cocoaRect)
        layer.orderFrontRegardless()
        clicks = layer
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, let clicks = self.clicks, clicks.frame.contains(p) else { return }
                clicks.ring(at: NSPoint(x: p.x - clicks.frame.minX, y: p.y - clicks.frame.minY))
            }
        }
    }

    private func tearDown(keepBar: Bool) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        frame?.orderOut(nil)
        clicks?.orderOut(nil)
        camera?.shutDown()
        camera = nil
        if !keepBar { bar?.orderOut(nil) }
    }

    private func close() {
        tearDown(keepBar: false)
        frame = nil
        clicks = nil
        bar = nil
        onEnd?()
        onEnd = nil
    }
}

/// The red border around the recorded area. Drawn just outside it, so it never ends up in the video.
final class RedFrame: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowBlurRadius = 8
        glow.shadowColor = NSColor.systemRed.withAlphaComponent(0.6)
        glow.set()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Transparent, click-through layer over the area; a ring grows where you click (it is in the video).
final class ClickLayer: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView?.wantsLayer = true
    }

    func ring(at p: NSPoint) {
        guard let host = contentView?.layer else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -22, y: -22, width: 44, height: 44), transform: nil)
        ring.position = p
        ring.fillColor = Theme.accent.withAlphaComponent(0.25).cgColor
        ring.strokeColor = Theme.accent.cgColor
        ring.lineWidth = 2.5
        host.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        ring.opacity = 0
        ring.add(group, forKey: "ring")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { ring.removeFromSuperlayer() }
    }
}

/// Round webcam preview, movable, recorded with the screen.
final class CameraBubble: NSPanel {
    private let session = AVCaptureSession()

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = frame.width / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.cgColor
        view.layer?.backgroundColor = NSColor.black.cgColor
        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.connection?.automaticallyAdjustsVideoMirroring = false
            preview.connection?.isVideoMirrored = true
            view.layer?.insertSublayer(preview, at: 0)
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }
        contentView = view
    }

    func shutDown() {
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        orderOut(nil)
    }
}

struct RecordingBar: View {
    @ObservedObject var model: RecordingModel
    let mic: () -> Void
    let camera: () -> Void
    let pause: () -> Void
    let stop: () -> Void
    @State private var blink = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 9, height: 9)
                .opacity(model.paused || blink ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: blink)
                .onAppear { blink = true }
                .padding(.leading, 14)
            Text(model.saving ? "Saving…" : CaptureNaming.duration(model.elapsed))
                .font(.system(size: 14, weight: .semibold, design: .monospaced)).monospacedDigit()
                .padding(.horizontal, 8)
            Rectangle().fill(.white.opacity(0.22)).frame(width: 0.5, height: 22).padding(.horizontal, 4)
            if model.kind == .screencast {
                BarButton(help: model.micOn ? "Microphone on" : "Microphone off", action: mic) {
                    HStack(spacing: 6) {
                        Image(systemName: model.micOn ? "mic.fill" : "mic.slash.fill")
                        if model.micOn { LevelMeter(level: model.level) }
                    }
                }
                BarButton(help: model.camOn ? "Hide webcam" : "Show webcam", action: camera) {
                    Image(systemName: model.camOn ? "video.fill" : "video.slash.fill")
                }
            }
            BarButton(help: model.paused ? "Resume" : "Pause", action: pause) {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
            }
            Button(action: stop) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10, height: 10)
                    Text("Stop").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .fixedSize()
                .padding(.horizontal, 13).frame(height: 36)
                .background(Capsule().fill(Color(nsColor: .systemRed)))
            }
            .buttonStyle(.plain).help("Stop and save (⌃⌘4)").disabled(model.saving).padding(.leading, 4)
        }
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.trailing, 5)
        .frame(height: 46)
        .background(Capsule().fill(Color(white: 0.1, opacity: 0.82)))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .padding(14)
        .environment(\.colorScheme, .dark)
    }
}

struct BarButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label().font(.system(size: 15, weight: .semibold)).padding(.horizontal, 10).frame(minWidth: 36, minHeight: 36)
                .background(Capsule().fill(.white.opacity(hover ? 0.14 : 0)))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Float(i) / 4 < level ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 3, height: CGFloat(5 + i * 3))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
