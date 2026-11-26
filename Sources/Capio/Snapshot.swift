import AppKit
import AVFoundation
import CapioCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Capio --snapshot-dir <dir>` (with CAPIO_DATA_DIR set): draws every screen to PNG off screen, then quits.
/// Needs no Screen Recording permission: the "desktop" is drawn here, and nothing touches the clipboard or the network.
@MainActor
enum Snapshot {
    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-dir"), i + 1 < args.count else { return false }
        guard Prefs.dataDir != nil else {
            log.error("--snapshot-dir needs CAPIO_DATA_DIR, so real captures stay untouched")
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        Task {
            do { try await run(into: dir); exit(0) } catch {
                log.error("snapshot failed: \(error.localizedDescription)")
                try? "\(error)".write(to: dir.appendingPathComponent("FAILED.txt"), atomically: true, encoding: .utf8)
                exit(1)
            }
        }
        return true
    }

    static let window = CGRect(x: 150, y: 64, width: 720, height: 480)
    static let selection = CGRect(x: 172, y: 160, width: 596, height: 256)

    static var marks: [Annotation] {
        [
            Annotation(tool: .highlight, color: Palette.yellow, points: [CGPoint(x: 189, y: 197), CGPoint(x: 318, y: 224)]),
            Annotation(tool: .obfuscate, color: Palette.indigo, points: [CGPoint(x: 272, y: 293), CGPoint(x: 410, y: 319)]),
            Annotation(tool: .rectangle, color: Palette.indigo, points: [CGPoint(x: 598, y: 330), CGPoint(x: 696, y: 362)]),
            Annotation(tool: .arrow, color: Palette.indigo, points: [CGPoint(x: 440, y: 390), CGPoint(x: 594, y: 352)]),
            Annotation(tool: .text, color: Palette.indigo, points: [CGPoint(x: 300, y: 392)], text: "This amount is wrong"),
            Annotation(tool: .number, color: Palette.indigo, points: [CGPoint(x: 598, y: 330)], number: 1),
            Annotation(tool: .number, color: Palette.indigo, points: [CGPoint(x: 384, y: 211)], number: 2),
        ]
    }

    static func run(into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        let scale: CGFloat = 2
        guard let screen = NSScreen.main, let desktop = drawDesktop(scale: scale) else { throw SnapshotError("no screen or desktop") }
        let frozen = FrozenScreen(screen: screen, image: desktop, scale: scale, windows: [window])
        let size = CGSize(width: 1440, height: 900)

        let canvas = CanvasView(frozen: frozen)
        let root = OverlayRoot(frozen: frozen, canvas: canvas)
        root.frame = CGRect(origin: .zero, size: size)
        let host = offscreenWindow(size: size)
        host.contentView = root

        canvas.demo(selection: nil, annotations: [], tool: nil, hover: window)
        try save(overlay(root, frozen: frozen), dir, "1-idle")
        canvas.quick = true
        canvas.demo(selection: nil, annotations: [], tool: nil, hover: nil)
        try save(overlay(root, frozen: frozen), dir, "1-idle-quick")
        canvas.quick = false
        canvas.demo(selection: selection, annotations: [], tool: nil)
        try save(overlay(root, frozen: frozen), dir, "2-selected")
        canvas.demo(selection: selection, annotations: marks, tool: .arrow)
        try save(overlay(root, frozen: frozen), dir, "3-drawn")

        guard let exported = canvas.export() else { throw SnapshotError("export gave nothing") }
        try save(exported, dir, "4-export")
        let text = OCR.text(in: exported)
        try text.write(to: dir.appendingPathComponent("4-export-ocr.txt"), atomically: true, encoding: .utf8)

        let thumb = Exporter.nsImage(exported, scale: scale)
        let local = CaptureRecord(fileName: "Capio demo.png", kind: .screenshot, createdAt: Date(), bytes: 1, pixelWidth: 1, pixelHeight: 1)
        Toast.shared.demo(.saved("Screenshot saved", "On this Mac, copied to the clipboard."), thumbnail: thumb, record: local)
        try save(try await render(ToastView(model: Toast.shared)), dir, "5-toast-saved")
        Toast.shared.demo(.uploading(.screenshot, 0.64), thumbnail: thumb)
        try save(try await render(ToastView(model: Toast.shared)), dir, "5-toast-uploading")
        Toast.shared.demo(.link("https://files.example.net/v/k3x9m2p7qa"), thumbnail: thumb)
        try save(try await render(ToastView(model: Toast.shared)), dir, "6-toast-link")
        Toast.shared.demo(.error("Upload failed", "Amfora answered 401: Invalid API key. The file is saved and on your clipboard."), thumbnail: nil)
        try save(try await render(ToastView(model: Toast.shared)), dir, "7-toast-error")

        try seedHistory(exported: exported, scale: scale)
        let library = Library()
        let noop: (CaptureRecord) -> Void = { _ in }
        let actions = HistoryActions(open: noop, reveal: noop, copyFile: noop, copyLink: noop, openLink: noop, upload: noop,
                                     pin: noop, copyText: noop, delete: noop, deleteUpload: noop, openFolder: {}, settings: {})
        try save(try await render(HistoryView(library: library, actions: actions), settle: 1.5), dir, "8-history")
        try save(try await render(HistoryView(library: library, actions: actions, filter: .shared), settle: 1.5), dir, "8-history-public")
        try await settingsWindow(into: dir)

        Toast.shared.demo(.updated("0.7.1"), thumbnail: nil)
        try save(try await render(ToastView(model: Toast.shared)), dir, "11-toast-updated")
        let update = UpdateInfo(version: "0.7.1", notes: ["Captures you throw away in Finder leave the overview right away.",
                                                           "GIFs longer than a minute no longer stutter at the end."],
                                archive: URL(fileURLWithPath: "/"), signature: "", size: 2_100_000)
        let phases: [(String, UpdateController.Phase)] = [("available", .available(update)), ("downloading", .downloading(update, 0.62)),
                                                          ("ready", .ready(update)), ("uptodate", .upToDate),
                                                          ("failed", .failed("Could not check for updates", UpdateFailure.unavailable.localizedDescription))]
        for (name, phase) in phases {
            UpdateController.shared.demo(phase)
            try save(try await render(UpdateView(model: UpdateController.shared)), dir, "11-update-\(name)")
        }

        let recording = RecordingModel(kind: .screencast)
        recording.elapsed = 12
        recording.level = 0.6
        try save(try await render(RecordingBar(model: recording, mic: {}, camera: {}, pause: {}, stop: {})), dir, "10-recording-bar")
        try await checkGIF(into: dir)
        try checkFormats(exported, scale: scale, into: dir)
        try checkSelecting(canvas, in: host, into: dir)
        try await checkToastPanel(into: dir)
        try "ok \(Date())\n".write(to: dir.appendingPathComponent("DONE.txt"), atomically: true, encoding: .utf8)
    }

    /// The real settings window, toolbar and all, one picture per tab; the window must resize with the pane.
    /// The real panel, first with a short text and then with a long one: the card has to stay 12 points under the
    /// menu bar and the panel has to hold all of its content, also when the text grows while it is on screen.
    static func checkToastPanel(into dir: URL) async throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { throw SnapshotError("no screen") }
        let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, NSApp.mainMenu?.menuBarHeight ?? 0, ToastPlacement.minMenuBar)
        let want = screen.frame.maxY - bar - ToastPlacement.gap + ToastPlacement.cardInset
        var lines = ["screen \(screen.frame) menu bar \(bar) panel top wanted \(want)"]
        var wrong: [String] = []
        let steps: [(String, () -> Void)] = [
            ("short", { Toast.shared.showInfo("Short", detail: "One line.") }),
            ("long", { Toast.shared.showError("Upload failed", detail: "Amfora answered 401: Invalid API key. The file is saved and on your clipboard. Open Settings, Sharing, and paste a new key to try again.") }),
            ("short again", { Toast.shared.showInfo("Short", detail: "One line.") }),
        ]
        for (name, show) in steps {
            show()
            try await Task.sleep(nanoseconds: 900_000_000)
            guard let frame = Toast.shared.panelFrame, let fit = Toast.shared.panelFit else { throw SnapshotError("toast panel is not there") }
            lines.append("\(name): top \(frame.maxY) height \(frame.height) content \(fit.height)")
            if abs(frame.maxY - want) > 0.5 { wrong.append("\(name): top \(frame.maxY), wanted \(want)") }
            if frame.height + 0.5 < fit.height { wrong.append("\(name): panel \(frame.height) high, content needs \(fit.height)") }
        }
        Toast.shared.hide()
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("13-toast-panel.txt"), atomically: true, encoding: .utf8)
        guard wrong.isEmpty else { throw SnapshotError("toast panel: " + wrong.joined(separator: "; ")) }
    }

    /// Real mouse events on the canvas: a drag selects, a click picks the window or the screen, and after such a click
    /// a drag still draws a selection of one's own (it used to move the picked one, which on a whole screen does nothing).
    static func checkSelecting(_ canvas: CanvasView, in host: NSWindow, into dir: URL) throws {
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
            // The canvas is flipped and fills the window: window coordinates count from the bottom.
            guard let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: canvas.bounds.height - p.y), modifierFlags: [], timestamp: 0,
                                             windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw SnapshotError("no mouse event") }
            return e
        }
        func drag(_ a: CGPoint, _ b: CGPoint) throws {
            canvas.mouseDown(with: try mouse(.leftMouseDown, a))
            if a != b { canvas.mouseDragged(with: try mouse(.leftMouseDragged, b)) }
            canvas.mouseUp(with: try mouse(.leftMouseUp, b))
        }
        var lines: [String] = []
        var wrong: [String] = []
        func expect(_ name: String, _ want: CGRect) {
            lines.append("\(name): \(canvas.selection.map { "\($0)" } ?? "none")")
            if canvas.selection != want { wrong.append("\(name): \(String(describing: canvas.selection)), wanted \(want)") }
        }
        let own = CGRect(x: 300, y: 200, width: 400, height: 250)
        let inWindow = CGPoint(x: window.midX, y: window.midY)
        let onDesktop = CGPoint(x: 6, y: canvas.bounds.height - 6)
        guard !window.contains(onDesktop) else { throw SnapshotError("demo window covers the corner") }

        canvas.demo(selection: nil, annotations: [], tool: nil)
        try drag(own.origin, CGPoint(x: own.maxX, y: own.maxY))
        expect("drag on a fresh overlay", own)
        try drag(CGPoint(x: own.midX, y: own.midY), CGPoint(x: own.midX + 50, y: own.midY + 30))
        expect("drag inside an own selection moves it", own.offsetBy(dx: 50, dy: 30))

        canvas.demo(selection: nil, annotations: [], tool: nil)
        try drag(inWindow, inWindow)
        expect("click on a window", window)
        try drag(own.origin, CGPoint(x: own.maxX, y: own.maxY))
        expect("drag after a window click", own)

        canvas.demo(selection: nil, annotations: [], tool: nil)
        try drag(onDesktop, onDesktop)
        expect("click on the desktop", canvas.bounds)
        try drag(own.origin, CGPoint(x: own.maxX, y: own.maxY))
        expect("drag after a whole screen click", own)

        canvas.demo(selection: nil, annotations: [], tool: nil)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("14-selecting.txt"), atomically: true, encoding: .utf8)
        guard wrong.isEmpty else { throw SnapshotError("selecting: " + wrong.joined(separator: "; ")) }
    }

    static func settingsWindow(into dir: URL) async throws {
        let (w, tabs) = SettingsWindow.make()
        w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        w.orderFront(nil)
        defer { w.orderOut(nil) }
        var heights: [CGFloat] = []
        for tab in SettingsTab.allCases {
            tabs.selectedTabViewItemIndex = tab.rawValue
            try await Task.sleep(nanoseconds: 700_000_000)
            guard let chrome = w.contentView?.superview, let image = try cache(chrome).cgImage else { throw SnapshotError("settings window has no frame view") }
            try save(image, dir, "9-settings-\(tab.rawValue + 1)-\(tab.title.lowercased())")
            heights.append(w.frame.height)
        }
        try "tabs \(tabs.tabViewItems.count) heights \(heights.map { Int($0) })\n".write(to: dir.appendingPathComponent("9-settings.txt"), atomically: true, encoding: .utf8)
        // Opened straight on Sharing (no key yet), the window must already have that pane's size.
        let (direct, _) = SettingsWindow.make(initial: .sharing)
        direct.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        direct.orderFront(nil)
        try await Task.sleep(nanoseconds: 400_000_000)
        let born = direct.frame.height
        direct.orderOut(nil)
        try "opened on sharing \(Int(born))\n".write(to: dir.appendingPathComponent("9-settings-direct.txt"), atomically: true, encoding: .utf8)
        guard abs(born - heights[SettingsTab.sharing.rawValue]) < 2 else { throw SnapshotError("opened on Sharing at \(born), pane is \(heights[SettingsTab.sharing.rawValue])") }
        guard tabs.tabViewItems.count == 5, Set(heights).count > 1, heights.allSatisfy({ $0 > 150 && $0 < 700 }) else {
            throw SnapshotError("settings window does not follow its panes: \(heights)")
        }
    }

    /// Writes a 2 s test video (a square moving across) and turns it into a GIF: 30 frames at 15 a second, and again at 480 wide.
    static func checkGIF(into dir: URL) async throws {
        let mp4 = dir.appendingPathComponent("test.mp4"), gif = dir.appendingPathComponent("11-test.gif")
        try? FileManager.default.removeItem(at: mp4)
        let writer = try AVAssetWriter(outputURL: mp4, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw SnapshotError("writer: \(writer.error?.localizedDescription ?? "-")") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { throw SnapshotError("pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 640, height: 360, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            ctx.setFillColor(Palette.indigo.cgColor); ctx.fill(CGRect(x: 20 + i * 9, y: 140, width: 80, height: 80))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw SnapshotError("video not finished") }
        let size = try await GIFMaker.make(from: mp4, to: gif, fps: Double(Quality.defaultGIFRate), maxWidth: CGFloat(Quality.defaultGIFWidth))
        guard let src = CGImageSourceCreateWithURL(gif as CFURL, nil) else { throw SnapshotError("gif unreadable") }
        let frames = CGImageSourceGetCount(src)
        let small = dir.appendingPathComponent("11-test-small.gif")
        let smallSize = try await GIFMaker.make(from: mp4, to: small, fps: 10, maxWidth: 480)
        let smallFrames = CGImageSourceCreateWithURL(small as CFURL, nil).map(CGImageSourceGetCount) ?? 0
        try "frames \(frames) size \(size.width)x\(size.height), small \(smallFrames) frames \(smallSize.width)x\(smallSize.height)\n"
            .write(to: dir.appendingPathComponent("11-test-gif.txt"), atomically: true, encoding: .utf8)
        guard (29...31).contains(frames), size.width == 640 else { throw SnapshotError("GIF has \(frames) frames at \(size.width) wide") }
        guard (19...21).contains(smallFrames), smallSize.width == 480 else { throw SnapshotError("small GIF has \(smallFrames) frames at \(smallSize.width) wide") }
        try? FileManager.default.removeItem(at: mp4)
    }

    /// The export in every format and size from Settings: each file must be what its name says.
    static func checkFormats(_ image: CGImage, scale: CGFloat, into dir: URL) throws {
        var lines: [String] = []
        var bytes: [ImageFormat: Int] = [:]
        for format in ImageFormat.allCases {
            for size in ImageSize.allCases {
                let out = Exporter.sized(image, scale: scale, size: size)
                guard let data = Exporter.data(out.image, scale: out.scale, format: format) else { throw SnapshotError("no data for \(format) \(size)") }
                let url = dir.appendingPathComponent("12-\(format.rawValue)-\(size.rawValue).\(format.fileExtension)")
                try data.write(to: url)
                guard let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) as String?,
                      let read = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw SnapshotError("\(url.lastPathComponent) is unreadable") }
                let wantType = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
                let wantWidth = size == .normal ? Int((CGFloat(image.width) / scale).rounded()) : image.width
                let wantScale = size == .normal ? 1 : scale
                guard type == wantType, read.width == wantWidth, Exporter.scale(of: src) == wantScale else {
                    throw SnapshotError("\(url.lastPathComponent): type \(type), \(read.width) wide, scale \(Exporter.scale(of: src) ?? 0), wanted \(wantType) at \(wantWidth), scale \(wantScale)")
                }
                if size == .retina { bytes[format] = data.count }
                lines.append("\(format.rawValue) \(size.rawValue): \(read.width)x\(read.height), \(data.count) bytes")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("12-formats.txt"), atomically: true, encoding: .utf8)
        guard let high = bytes[.jpegHigh], let medium = bytes[.jpegMedium], medium < high else { throw SnapshotError("JPEG Medium is not smaller than High: \(bytes)") }
    }

    // MARK: drawing helpers

    /// A desktop with an invoice window, drawn at `scale`.
    static func drawDesktop(scale: CGFloat) -> CGImage? {
        let w = 1440, h = 900
        guard let ctx = CGContext(data: nil, width: Int(CGFloat(w) * scale), height: Int(CGFloat(h) * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGradient(colors: [NSColor(srgbRed: 0.37, green: 0.55, blue: 0.65, alpha: 1), NSColor(srgbRed: 0.76, green: 0.80, blue: 0.79, alpha: 1),
                            NSColor(srgbRed: 0.89, green: 0.84, blue: 0.74, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: window, xRadius: 16, yRadius: 16).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: window.minX, y: window.minY + 14, width: window.width, height: 30)).fill()
        NSBezierPath(roundedRect: NSRect(x: window.minX, y: window.minY, width: window.width, height: 30), xRadius: 16, yRadius: 16).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: window.minX + 16 + CGFloat(i) * 20, y: window.minY + 16, width: 12, height: 12)).fill()
        }
        text("ledger.app/invoices", 12.5, .regular, NSColor(white: 0.45, alpha: 1), at: CGPoint(x: window.midX - 55, y: window.minY + 14))
        text("Invoices", 22, .bold, NSColor(white: 0.08, alpha: 1), at: CGPoint(x: 178, y: 122))

        NSColor(white: 0.965, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 178, y: 168, width: 324, height: 68), xRadius: 12, yRadius: 12).fill()
        NSBezierPath(roundedRect: NSRect(x: 518, y: 168, width: 324, height: 68), xRadius: 12, yRadius: 12).fill()
        text("Outstanding", 11.5, .regular, NSColor(white: 0.45, alpha: 1), at: CGPoint(x: 192, y: 180))
        text("€ 3,131.50", 22, .bold, NSColor(white: 0.08, alpha: 1), at: CGPoint(x: 192, y: 195))
        text("1 overdue", 11.5, .semibold, NSColor(srgbRed: 0.7, green: 0.14, blue: 0.1, alpha: 1), at: CGPoint(x: 318, y: 205))
        text("Paid in November", 11.5, .regular, NSColor(white: 0.45, alpha: 1), at: CGPoint(x: 532, y: 180))
        text("€ 4,090.00", 22, .bold, NSColor(white: 0.08, alpha: 1), at: CGPoint(x: 532, y: 195))

        let cols: [CGFloat] = [178, 278, 478, 568, 710]
        for (i, head) in ["INVOICE", "CLIENT", "DATE", "AMOUNT", "STATUS"].enumerated() {
            text(head, 11, .semibold, NSColor(white: 0.45, alpha: 1), at: CGPoint(x: i == 3 ? 636 : cols[i], y: 264))
        }
        let rows = [("INV 2041", "Brightline Studio", "18 Nov", "€ 1,240.00", "Paid"),
                    ("INV 2042", "Nordhaven Ltd", "19 Nov", "€ 2,850.00", "Open"),
                    ("INV 2043", "Casa Lumen", "20 Nov", "€ 467.50", "Overdue"),
                    ("INV 2044", "Kestrel Labs", "21 Nov", "€ 980.00", "Draft"),
                    ("INV 2045", "Halvar & Co", "21 Nov", "€ 1,725.00", "Draft")]
        for (i, r) in rows.enumerated() {
            let y = 286 + CGFloat(i) * 40
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 178, y: y - 1, width: 664, height: 1)).fill()
            text(r.0, 13, .regular, NSColor(white: 0.45, alpha: 1), at: CGPoint(x: 178, y: y + 11))
            text(r.1, 13, .semibold, NSColor(white: 0.08, alpha: 1), at: CGPoint(x: 278, y: y + 11))
            text(r.2, 13, .regular, NSColor(white: 0.45, alpha: 1), at: CGPoint(x: 478, y: y + 11))
            let amount = NSAttributedString(string: r.3, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            amount.draw(at: CGPoint(x: 686 - amount.size().width, y: y + 11))
            text(r.4, 11.5, .semibold, NSColor(srgbRed: 0.16, green: 0.32, blue: 0.8, alpha: 1), at: CGPoint(x: 718, y: y + 12))
        }
        return ctx.makeImage()
    }

    static func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
    }

    static func offscreenWindow(size: CGSize) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// The canvas and bar drawn over the frozen desktop.
    static func overlay(_ root: OverlayRoot, frozen: FrozenScreen) throws -> CGImage {
        root.layoutSubtreeIfNeeded()
        let rep = try cache(root, hiding: root.subviews.first)
        let size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let top = rep.cgImage,
              let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SnapshotError("no bitmap") }
        ctx.draw(frozen.image, in: CGRect(origin: .zero, size: size))
        ctx.draw(top, in: CGRect(origin: .zero, size: size))
        guard let out = ctx.makeImage() else { throw SnapshotError("no image") }
        return out
    }

    static func cache(_ view: NSView, hiding hidden: NSView? = nil) throws -> NSBitmapImageRep {
        hidden?.isHidden = true
        defer { hidden?.isHidden = false }
        view.displayIfNeeded()
        guard let rep = pixelScale > 1 ? sharpRep(for: view) : view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotError("no rep")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// `CAPIO_SNAPSHOT_SCALE=2` draws every screen at Retina size, also on a Mac with a normal display (for the README pictures).
    static let pixelScale = CGFloat(Double(ProcessInfo.processInfo.environment["CAPIO_SNAPSHOT_SCALE"] ?? "") ?? 1)

    static func sharpRep(for view: NSView) -> NSBitmapImageRep? {
        let b = view.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * pixelScale), pixelsHigh: Int(b.height * pixelScale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = b.size
        return rep
    }

    /// A SwiftUI view in an off screen window, given time to lay out and load.
    static func render<V: View>(_ content: V, settle: Double = 0.4) async throws -> CGImage {
        let host = NSHostingView(rootView: content.background(Color(white: 0.93)))
        let size = host.fittingSize
        let w = offscreenWindow(size: size)
        host.frame = CGRect(origin: .zero, size: size)
        w.contentView = host
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
        let rep = try cache(host)
        guard let cg = rep.cgImage else { throw SnapshotError("no image for \(V.self)") }
        return cg
    }

    static func save(_ image: CGImage, _ dir: URL, _ name: String) throws {
        guard let png = Exporter.png(image, scale: 1) else { throw SnapshotError("png \(name)") }
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    static func seedHistory(exported: CGImage, scale: CGFloat) throws {
        let store = HistoryStore(indexURL: Prefs.historyURL)
        try FileManager.default.createDirectory(at: Prefs.folder, withIntermediateDirectories: true)
        guard let png = Exporter.png(exported, scale: scale) else { throw SnapshotError("seed png") }
        let now = Date()
        let seeds: [(TimeInterval, String?)] = [(-60, "https://files.example.net/e/cmi7k2f9q0001"), (-3_600 * 5, nil), (-86_400 * 2, "https://files.example.net/e/cmi1"), (-86_400 * 3, nil)]
        for (i, seed) in seeds.enumerated() {
            let date = now.addingTimeInterval(seed.0)
            let name = "Capio demo \(i + 1).png"
            try png.write(to: Prefs.folder.appendingPathComponent(name))
            let base = CaptureRecord(fileName: name, kind: .screenshot, createdAt: date, bytes: Int64(png.count),
                                     pixelWidth: exported.width, pixelHeight: exported.height)
            try store.add(seed.1.map { base.uploaded(link: $0, fileId: "f\(i)", shareId: "s\(i)", at: date) } ?? base)
        }
        // Thrown away in Finder: must not show in 8-history (footer stays "4 captures · 2 public").
        try store.add(CaptureRecord(fileName: "Capio gone.png", kind: .screenshot, createdAt: now, bytes: 1,
                                    pixelWidth: exported.width, pixelHeight: exported.height))
    }
}

struct SnapshotError: LocalizedError {
    let errorDescription: String?
    init(_ what: String) { errorDescription = what }
}
