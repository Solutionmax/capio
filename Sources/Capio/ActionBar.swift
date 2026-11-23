import AppKit
import CapioCore

/// A button in the row under the selection: flat circle (or the wide Screenshot pill), one soft shadow, no gradient.
final class RoundButton: NSButton {
    /// white: white circle. small: smaller white circle with an accent glyph. ghost: glyph only.
    /// wide: the accent Screenshot pill with its word and the Return key.
    enum Style { case white, small, ghost, wide }

    let style: Style
    let symbol: String?
    let label: String?
    var isOn = false { didSet { needsDisplay = true } }
    var tint: NSColor? { didSet { needsDisplay = true } }
    var symbolOverride: String? { didSet { needsDisplay = true } }

    private var shape: CGSize {
        switch style {
        case .white: return CGSize(width: BarLayout.white, height: BarLayout.white)
        case .small: return CGSize(width: BarLayout.small, height: BarLayout.small)
        case .ghost: return CGSize(width: BarLayout.ghost, height: BarLayout.ghost)
        case .wide: return CGSize(width: BarLayout.wide, height: BarLayout.prime)
        }
    }

    private var body: NSRect {
        NSRect(x: bounds.midX - shape.width / 2, y: bounds.midY - shape.height / 2, width: shape.width, height: shape.height)
    }

    private func pill(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2) }

    init(style: Style, symbol: String? = nil, label: String? = nil, tip: String, target: AnyObject, action: Selector) {
        self.style = style
        self.symbol = symbol
        self.label = label
        super.init(frame: .zero)
        frame.size = NSSize(width: shape.width + 2 * BarLayout.pad, height: BarLayout.prime + 2 * BarLayout.pad)
        self.target = target
        self.action = action
        toolTip = tip
        setAccessibilityLabel(tip)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { frame.size }
    override var isFlipped: Bool { false }

    /// Only the shape takes clicks: the frames of neighbours overlap in the shadow margin.
    override func hitTest(_ point: NSPoint) -> NSView? {
        pill(body.insetBy(dx: -2, dy: -2)).contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = body
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: style == .ghost ? -1 : -3)
        shadow.shadowBlurRadius = style == .ghost ? 3 : 8
        shadow.shadowColor = NSColor(white: 0, alpha: style == .ghost ? 0.6 : 0.35)
        let accentFill = style == .wide

        if style != .ghost {
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            (accentFill ? Theme.accent : NSColor.white).setFill()
            pill(r).fill()
            NSGraphicsContext.restoreGraphicsState()
            if isHighlighted {
                NSColor(white: 0, alpha: 0.14).setFill()
                pill(r).fill()
            }
            if isOn {
                let ring = pill(r.insetBy(dx: -2, dy: -2))
                ring.lineWidth = 3
                (accentFill ? NSColor.white : Theme.accent).setStroke()
                ring.stroke()
            }
        }

        let fg: NSColor = tint ?? {
            switch style {
            case .white: return NSColor(white: 0.11, alpha: 1)
            case .small: return Theme.accent
            default: return .white
            }
        }()
        if style == .wide { drawWide(in: r, fg: fg); return }
        if let label {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: style == .small ? 13 : 14, weight: .heavy), .foregroundColor: fg]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        } else if let img = glyph(symbolOverride ?? symbol, size: 19, color: fg) {
            NSGraphicsContext.saveGraphicsState()
            if style == .ghost { shadow.set() }
            img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Camera, the word, and a light key cap with the Return glyph on the right.
    private func drawWide(in r: NSRect, fg: NSColor) {
        var x = r.minX + 18
        if let cam = glyph(symbol, size: 20, color: fg) {
            cam.draw(in: NSRect(x: x, y: r.midY - cam.size.height / 2, width: cam.size.width, height: cam.size.height))
            x += cam.size.width + 8
        }
        if let label {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: fg]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: x, y: r.midY - size.height / 2), withAttributes: attrs)
        }
        let cap = NSRect(x: r.maxX - 11 - 30, y: r.midY - 14, width: 30, height: 28)
        NSColor(white: 1, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: cap, xRadius: 8, yRadius: 8).fill()
        if let ret = glyph("return", size: 13, color: fg) {
            ret.draw(in: NSRect(x: cap.midX - ret.size.width / 2, y: cap.midY - ret.size.height / 2, width: ret.size.width, height: ret.size.height))
        }
    }

    private func glyph(_ name: String?, size: CGFloat, color: NSColor) -> NSImage? {
        guard let name else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color])))
    }
}

enum BarAction { case screenshot, screencast, gif, pin, settings }

/// The row under the selection, laid out by `BarLayout`: the size on the left, then the round buttons.
final class ActionBar: NSView {
    var onAction: ((BarAction, NSView) -> Void)?
    private var buttons: [(RoundButton, BarAction)] = []
    private var size = ""

    init() {
        super.init(frame: .zero)
        let items: [(RoundButton.Style, String?, String?, String, BarAction)] = [
            (.wide, "camera.fill", "Screenshot", "Screenshot (Return)", .screenshot),
            (.small, "video.fill", nil, "Screencast", .screencast),
            (.small, nil, "GIF", "GIF", .gif),
            (.ghost, "pin.fill", nil, "Pin to screen", .pin),
            (.white, "gearshape.fill", nil, "Settings", .settings),
        ]
        for item in items {
            let b = RoundButton(style: item.0, symbol: item.1, label: item.2, tip: item.3, target: self, action: #selector(tapped(_:)))
            addSubview(b)
            buttons.append((b, item.4))
        }
        layout(width: BarLayout.minWidth)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// `width` is the span between the outer edges; the view is `BarLayout.pad` larger on every side.
    func layout(width: CGFloat) {
        frame.size = NSSize(width: width + 2 * BarLayout.pad, height: BarLayout.prime + 2 * BarLayout.pad)
        for (slot, entry) in zip(BarLayout.slots(width: width).dropFirst(), buttons) {
            entry.0.frame.origin = NSPoint(x: slot, y: 0)
        }
    }

    func show(size text: String) {
        guard text != size else { return }
        size = text
        needsDisplay = true
    }

    /// Dark label with a frame glyph and the size in points, where the eye starts reading the row.
    override func draw(_ dirtyRect: NSRect) {
        guard !size.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white,
        ]
        let textSize = size.size(withAttributes: attrs)
        let glyph = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.7)])))
        let glyphWidth = glyph.map { $0.size.width + 8 } ?? 0
        let r = CGRect(x: BarLayout.pad, y: bounds.midY - 15, width: min(textSize.width + glyphWidth + 28, BarLayout.label), height: 30)
        NSColor(srgbRed: 0.227, green: 0.231, blue: 0.247, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        if let glyph {
            glyph.draw(in: CGRect(x: r.minX + 14, y: r.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        size.draw(at: CGPoint(x: r.minX + 14 + glyphWidth, y: r.midY - textSize.height / 2), withAttributes: attrs)
    }

    @objc private func tapped(_ sender: RoundButton) {
        guard let action = buttons.first(where: { $0.0 === sender })?.1 else { return }
        onAction?(action, sender)
    }

    /// Rings the recording button that Return will start; a plain screenshot needs no ring.
    func setPrimary(_ action: BarAction) {
        for (b, a) in buttons where a == .screencast || a == .gif { b.isOn = a == action }
    }
}

/// One square in the tool strip: a tool or undo (symbol), or a colour (dot).
final class StripButton: NSButton {
    private let symbol: String?
    private let dot: NSColor?
    var isOn = false { didSet { needsDisplay = true } }

    init(symbol: String? = nil, dot: NSColor? = nil, tip: String, target: AnyObject, action: Selector) {
        self.symbol = symbol
        self.dot = dot
        super.init(frame: NSRect(x: 0, y: 0, width: dot == nil ? 30 : 24, height: 30))
        self.target = target
        self.action = action
        toolTip = tip
        setAccessibilityLabel(tip)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let dot {
            let c = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
            dot.setFill()
            NSBezierPath(ovalIn: c).fill()
            if isOn {
                let ring = NSBezierPath(ovalIn: c.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2
                Theme.accent.setStroke()
                ring.stroke()
            }
            return
        }
        let box = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        if isOn { Theme.accent.setFill(); box.fill() } else if isHighlighted { NSColor(white: 0, alpha: 0.1).setFill(); box.fill() }
        let fg = isOn ? NSColor.white : NSColor(white: 0.11, alpha: isEnabled ? 1 : 0.3)
        guard let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [fg]))) else { return }
        img.draw(in: NSRect(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
    }
}

/// The drawing tools above the selection, there as soon as an area is chosen: seven tools, five colours, undo.
final class ToolStrip: NSView {
    var onTool: ((Tool) -> Void)?
    var onColor: ((RGBA) -> Void)?
    var onUndo: (() -> Void)?
    private var tools: [(StripButton, Tool)] = []
    private var dots: [StripButton] = []
    private var undo: StripButton!
    private var dividers: [CGFloat] = []

    init() {
        super.init(frame: .zero)
        var x: CGFloat = 5
        func place(_ b: StripButton) {
            b.frame.origin = NSPoint(x: x, y: 5)
            addSubview(b)
            x += b.frame.width + 2
        }
        func divide() {
            dividers.append(x + 4)
            x += 11
        }
        for t in Tool.allCases {
            let b = StripButton(symbol: t.symbol, tip: "\(t.title) (\(t.key.uppercased()))", target: self, action: #selector(toolTapped(_:)))
            place(b)
            tools.append((b, t))
        }
        divide()
        for (i, entry) in Palette.all.enumerated() {
            let b = StripButton(dot: Theme.ns(entry.color), tip: "\(entry.name) (\(i + 1))", target: self, action: #selector(colorTapped(_:)))
            b.tag = i
            place(b)
            dots.append(b)
        }
        divide()
        undo = StripButton(symbol: "arrow.uturn.backward", tip: "Undo the last drawing (⌘Z)", target: self, action: #selector(undoTapped))
        place(undo)
        frame.size = NSSize(width: x + 3, height: 40)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowOffset = NSSize(width: 0, height: -3)
            s.shadowBlurRadius = 8
            s.shadowColor = NSColor(white: 0, alpha: 0.35)
            return s
        }()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0, alpha: 0.14).setFill()
        for x in dividers { NSRect(x: x, y: 10, width: 1, height: 20).fill() }
    }

    /// A click between the buttons must not reach the canvas and start a new selection.
    override func mouseDown(with event: NSEvent) {}

    func show(tool: Tool?, color: RGBA, canUndo: Bool) {
        for (b, t) in tools { b.isOn = t == tool }
        for (b, entry) in zip(dots, Palette.all) { b.isOn = entry.color == color }
        undo.isEnabled = canUndo
        undo.needsDisplay = true
    }

    @objc private func toolTapped(_ sender: StripButton) {
        if let t = tools.first(where: { $0.0 === sender })?.1 { onTool?(t) }
    }

    @objc private func colorTapped(_ sender: StripButton) { onColor?(Palette.all[sender.tag].color) }
    @objc private func undoTapped() { onUndo?() }
}
