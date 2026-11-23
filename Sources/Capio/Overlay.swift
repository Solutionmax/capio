import AppKit
import CapioCore
import CoreImage

enum OverlayAction { case cancel, capture, pin, screencast, gif, settings }

@MainActor
protocol OverlayDelegate: AnyObject {
    func overlay(_ canvas: CanvasView, finished action: OverlayAction)
    func overlayDidBeginSelection(_ canvas: CanvasView)
}

/// Borderless window over one display: frozen picture, dim, selection, drawings, round buttons.
final class OverlayWindow: NSWindow {
    let canvas: CanvasView

    init(frozen: FrozenScreen, delegate: OverlayDelegate) {
        canvas = CanvasView(frozen: frozen)
        super.init(contentRect: frozen.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Above the menu bar, below pop up menus so the tool menu shows on top.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        canvas.delegate = delegate
        contentView = OverlayRoot(frozen: frozen, canvas: canvas)
        setFrame(frozen.screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Stacks the frozen picture, the canvas and the action bar.
final class OverlayRoot: NSView {
    let canvas: CanvasView
    let bar = ActionBar()
    let strip = ToolStrip()

    init(frozen: FrozenScreen, canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: NSRect(origin: .zero, size: frozen.screen.frame.size))
        let picture = NSView(frame: bounds)
        picture.wantsLayer = true
        picture.layer?.contents = frozen.image
        picture.layer?.contentsGravity = .resize
        picture.autoresizingMask = [.width, .height]
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        addSubview(picture)
        addSubview(canvas)
        addSubview(bar)
        addSubview(strip)
        bar.isHidden = true
        strip.isHidden = true
        strip.onTool = { [weak canvas] t in canvas?.pick(tool: t) }
        strip.onColor = { [weak canvas] c in canvas?.pick(color: c) }
        strip.onUndo = { [weak canvas] in canvas?.undoLast() }
        bar.onAction = { [weak canvas] action, button in canvas?.barTapped(action, button: button) }
        canvas.onLayoutChange = { [weak self] in self?.placeBar() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func placeBar() {
        guard let s = canvas.selection, !canvas.isDragging else { bar.isHidden = true; strip.isHidden = true; return }
        bar.layout(width: BarLayout.width(for: s, in: bounds))
        bar.frame.origin = SelectionMath.barOrigin(selection: s, barSize: bar.frame.size, bounds: bounds, gap: 8)
        bar.show(size: "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))")
        bar.isHidden = false
        strip.frame.origin = SelectionMath.stripOrigin(selection: s, stripSize: strip.frame.size, bounds: bounds)
        strip.show(tool: canvas.tool, color: canvas.color, canUndo: canvas.canUndo)
        strip.isHidden = false
    }
}

/// Selection, drawing and keys. All geometry in view points, top left origin, same as the frozen picture.
final class CanvasView: NSView, NSTextFieldDelegate {
    enum Drag {
        case none
        case selecting(CGPoint)
        case moving(CGPoint, CGRect)
        case resizing(Handle)
        case drawing
    }

    let frozen: FrozenScreen
    weak var delegate: OverlayDelegate?
    var onLayoutChange: (() -> Void)?
    private(set) var selection: CGRect?
    private(set) var tool: Tool?
    private(set) var annotations: [Annotation] = []
    private(set) var color: RGBA = Prefs.drawColor
    var canUndo: Bool { !annotations.isEmpty }
    private var current: Annotation?
    private var drag: Drag = .none
    private var hoverWindow: CGRect?
    private var textField: NSTextField?
    private var textAnchor: CGPoint = .zero
    private var primary: OverlayAction = .capture
    /// Quick screenshot: letting go of the mouse takes the picture, no buttons.
    var quick = false { didSet { needsDisplay = true } }
    private static let ci = CIContext()

    init(frozen: FrozenScreen) {
        self.frozen = frozen
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isDragging: Bool {
        if case .none = drag { return false }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    func clearSelection() {
        commitText()
        selection = nil
        annotations = []
        tool = nil
        needsDisplay = true
        onLayoutChange?()
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        guard let s = selection else {
            ctx.addRect(bounds)
            if let w = hoverWindow { ctx.addRect(w) }
            ctx.fillPath(using: .evenOdd)
            if let w = hoverWindow {
                ctx.setStrokeColor(Theme.accent.cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(w.insetBy(dx: 1.5, dy: 1.5))
            }
            drawHint()
            return
        }
        ctx.addRect(bounds)
        ctx.addRect(s)
        ctx.fillPath(using: .evenOdd)

        ctx.saveGState()
        ctx.clip(to: s)
        AnnotationRenderer.draw(annotations + (current.map { [$0] } ?? []), in: ctx)
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(1)
        ctx.stroke(s.insetBy(dx: -0.5, dy: -0.5))
        if case .selecting = drag {} else { drawHandles(s, in: ctx) }
        if isDragging { drawSizeLabel(s) } // at rest the size is in the bar under the selection
    }

    /// White squares with a hairline.
    private func drawHandles(_ s: CGRect, in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        ctx.setLineWidth(1)
        for h in Handle.allCases {
            let p = SelectionMath.point(of: h, on: s)
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.fill(r)
            ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        }
    }

    /// Dark label above the top right corner: a frame glyph and the size in points.
    private func drawSizeLabel(_ s: CGRect) {
        let text = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let glyph = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.7)])))
        let glyphWidth = glyph.map { $0.size.width + 8 } ?? 0
        let box = CGSize(width: size.width + glyphWidth + 28, height: 30)
        let y = s.minY - box.height - 10 >= 4 ? s.minY - box.height - 10 : s.minY + 10
        let x = min(max(s.maxX - box.width, 4), bounds.maxX - box.width - 4)
        let r = CGRect(origin: CGPoint(x: x, y: y), size: box)
        NSColor(srgbRed: 0.227, green: 0.231, blue: 0.247, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        if let glyph {
            glyph.draw(in: CGRect(x: r.minX + 14, y: r.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        text.draw(at: CGPoint(x: r.minX + 14 + glyphWidth, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    /// The start hint at the bottom: what a drag and a click do. Gone as soon as there is a selection.
    private func drawHint() {
        let target = hoverWindow == nil ? "the whole screen" : "this window"
        let parts = (quick ? ["Drag to capture an area", "Click to capture \(target)"] : ["Drag to select an area", "Click to take \(target)"])
            + ["Esc to cancel"]
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let text = NSMutableAttributedString()
        for part in parts {
            if text.length > 0 {
                text.append(NSAttributedString(string: "    |    ", attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.28)]))
            }
            text.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: NSColor.white]))
        }
        let size = text.size()
        let r = CGRect(x: bounds.midX - size.width / 2 - 22, y: bounds.maxY - 132, width: size.width + 44, height: 38)
        NSColor(srgbRed: 0.12, green: 0.125, blue: 0.14, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: r, xRadius: 19, yRadius: 19).fill()
        text.draw(at: CGPoint(x: r.minX + 22, y: r.midY - size.height / 2))
    }

    // MARK: mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) {
        let p = point(e)
        if selection == nil {
            let w = frozen.windows.first { $0.contains(p) }
            if w != hoverWindow { hoverWindow = w; needsDisplay = true }
            NSCursor.crosshair.set()
            return
        }
        updateCursor(at: p)
    }

    private func updateCursor(at p: CGPoint) {
        guard let s = selection else { NSCursor.crosshair.set(); return }
        if tool != nil, s.contains(p) { (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set(); return }
        if let h = SelectionMath.handle(at: p, on: s) { cursor(for: h).set(); return }
        (s.contains(p) ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    private func cursor(for h: Handle) -> NSCursor {
        switch h {
        case .topLeft: return .frameResize(position: .topLeft, directions: .all)
        case .top: return .frameResize(position: .top, directions: .all)
        case .topRight: return .frameResize(position: .topRight, directions: .all)
        case .right: return .frameResize(position: .right, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        case .bottom: return .frameResize(position: .bottom, directions: .all)
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .left: return .frameResize(position: .left, directions: .all)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        commitText()
        window?.makeFirstResponder(self)
        if let s = selection, let tool, s.contains(p), SelectionMath.handle(at: p, on: s) == nil {
            startMark(tool, at: p)
            return
        }
        if let s = selection {
            if let h = SelectionMath.handle(at: p, on: s) { drag = .resizing(h); onLayoutChange?(); return }
            if s.contains(p) { drag = .moving(p, s); NSCursor.closedHand.set(); onLayoutChange?(); return }
            if !annotations.isEmpty { return } // keep the drawings: a stray click must not throw them away
        }
        selection = nil
        hoverWindow = nil
        drag = .selecting(p)
        delegate?.overlayDidBeginSelection(self)
        onLayoutChange?()
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        switch drag {
        case .selecting(let start):
            selection = SelectionMath.rect(from: start, to: p, in: bounds)
        case .moving(let start, let original):
            selection = SelectionMath.move(original, by: CGVector(dx: p.x - start.x, dy: p.y - start.y), in: bounds)
        case .resizing(let h):
            if let s = selection { selection = SelectionMath.resize(s, handle: h, to: p, in: bounds) }
        case .drawing:
            guard let c = current, let s = selection else { break }
            let q = SelectionMath.clamp(p, to: s)
            current = c.tool == .pen ? c.with(points: c.points + [q]) : c.with(points: [c.points[0], q])
        case .none:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        switch drag {
        case .selecting:
            if let s = selection, s.width >= SelectionMath.minSize, s.height >= SelectionMath.minSize { break }
            selection = SelectionMath.pick(windows: frozen.windows, at: p, in: bounds)
        case .resizing:
            if let s = selection, s.width < SelectionMath.minSize || s.height < SelectionMath.minSize {
                selection = CGRect(x: s.minX, y: s.minY, width: max(s.width, 20), height: max(s.height, 20)).intersection(bounds)
            }
        case .drawing:
            if let c = current, c.isMeaningful { annotations.append(c.tool == .obfuscate ? pixelated(c) : c) }
            current = nil
        case .moving, .none:
            break
        }
        var justSelected = false
        if case .selecting = drag { justSelected = true }
        drag = .none
        if quick, justSelected, selection != nil { finish(.capture); return }
        updateCursor(at: p)
        needsDisplay = true
        onLayoutChange?()
    }

    private func startMark(_ tool: Tool, at p: CGPoint) {
        switch tool {
        case .number:
            let next = annotations.filter { $0.tool == .number }.count + 1
            annotations.append(Annotation(tool: .number, color: color, points: [p], number: next))
            needsDisplay = true
        case .text:
            beginText(at: p)
        case .highlight:
            current = Annotation(tool: tool, color: color == Palette.indigo ? Palette.yellow : color, points: [p, p])
            drag = .drawing
        default:
            current = Annotation(tool: tool, color: color, points: [p, p])
            drag = .drawing
        }
    }

    /// The patch under an obfuscate mark, pixelated from the frozen picture so the export cannot be undone.
    private func pixelated(_ a: Annotation) -> Annotation {
        let r = a.rect.intersection(selection ?? bounds)
        let px = SelectionMath.pixelRect(r, scale: frozen.scale)
        guard !r.isEmpty, let crop = frozen.image.cropping(to: px) else { return a }
        let block = max(9 * frozen.scale, min(px.width, px.height) / 6)
        let input = CIImage(cgImage: crop).clampedToExtent()
        guard let filter = CIFilter(name: "CIPixellate", parameters: [
            kCIInputImageKey: input, kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: 0, y: 0),
        ]), let out = filter.outputImage,
            let cg = Self.ci.createCGImage(out, from: CGRect(origin: .zero, size: px.size)) else { return a }
        return Annotation(tool: .obfuscate, color: a.color, points: [r.origin, CGPoint(x: r.maxX, y: r.maxY)], image: cg)
    }

    // MARK: text

    private func beginText(at p: CGPoint) {
        let f = NSTextField(frame: NSRect(x: p.x - 3, y: p.y - 3, width: 280, height: 32))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = NSFont.systemFont(ofSize: AnnotationRenderer.textSize, weight: .bold)
        f.textColor = Theme.ns(color)
        f.placeholderString = "Type, then Return"
        f.delegate = self
        f.target = self
        f.action = #selector(textDone)
        addSubview(f)
        window?.makeFirstResponder(f)
        textField = f
        textAnchor = p
    }

    @objc private func textDone() {
        commitText()
        window?.makeFirstResponder(self)
    }

    /// Esc while typing drops the text and goes back to the canvas.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = textField else { return }
        f.sizeToFit()
        f.frame.size.width = max(f.frame.width + 20, 120)
    }

    private func commitText() {
        guard let f = textField else { return }
        let a = Annotation(tool: .text, color: color, points: [textAnchor], text: f.stringValue)
        if a.isMeaningful { annotations.append(a) }
        f.removeFromSuperview()
        textField = nil
        needsDisplay = true
    }

    // MARK: keys and buttons

    override func keyDown(with e: NSEvent) {
        let chars = e.charactersIgnoringModifiers ?? ""
        switch e.keyCode {
        case 53: delegate?.overlay(self, finished: .cancel); return
        case 36, 76: if selection != nil { finish(primary) }; return
        case 123, 124, 125, 126: nudge(e); return
        default: break
        }
        if e.modifierFlags.contains(.command) {
            if chars == "z" { undoLast() } else if chars == "c", selection != nil { finish(.capture) } else { super.keyDown(with: e) }
            return
        }
        if selection != nil, let t = Tool.forKey(chars) { choose(t); return }
        if selection != nil, let n = Int(chars), (1...Palette.all.count).contains(n) { pick(color: Palette.all[n - 1].color); return }
        super.keyDown(with: e)
    }

    private func nudge(_ e: NSEvent) {
        guard let s = selection else { return }
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        let d: CGVector
        switch e.keyCode {
        case 123: d = CGVector(dx: -step, dy: 0)
        case 124: d = CGVector(dx: step, dy: 0)
        case 125: d = CGVector(dx: 0, dy: step)
        default: d = CGVector(dx: 0, dy: -step)
        }
        selection = SelectionMath.move(s, by: d, in: bounds)
        needsDisplay = true
        onLayoutChange?()
    }

    private func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    /// What Return does, shown as the ringed button.
    func setPrimary(_ action: OverlayAction) {
        primary = action
        (superview as? OverlayRoot)?.bar.setPrimary(action == .screencast ? .screencast : action == .gif ? .gif : .screenshot)
    }

    private func choose(_ t: Tool?) {
        tool = t
        onLayoutChange?()
    }

    private func finish(_ action: OverlayAction) {
        commitText()
        delegate?.overlay(self, finished: action)
    }

    func barTapped(_ action: BarAction, button: NSView) {
        switch action {
        case .screenshot: finish(.capture)
        case .screencast: finish(.screencast)
        case .gif: finish(.gif)
        case .pin: finish(.pin)
        case .settings: finish(.settings)
        }
    }

    /// From the tool strip: a second click on the active tool goes back to moving the selection.
    func pick(tool t: Tool) { choose(t == tool ? nil : t) }

    func pick(color c: RGBA) {
        color = c
        onLayoutChange?()
    }

    func undoLast() {
        undo()
        onLayoutChange?()
    }

    /// Snapshot mode: put the canvas in a known state without mouse events.
    func demo(selection s: CGRect?, annotations list: [Annotation], tool t: Tool?, hover: CGRect? = nil) {
        selection = s
        annotations = list.map { $0.tool == .obfuscate ? pixelated($0) : $0 }
        tool = t
        hoverWindow = hover
        needsDisplay = true
        onLayoutChange?()
    }

    /// The selection with its drawings, at full pixel size.
    func export() -> CGImage? {
        commitText()
        guard let s = selection else { return nil }
        return Exporter.render(frozen.image, selection: s, scale: frozen.scale, annotations: annotations)
    }
}
