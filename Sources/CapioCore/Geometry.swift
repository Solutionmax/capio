import CoreGraphics

/// The eight grips on a selection, clockwise from the top left corner.
public enum Handle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Selection math in view points with a top left origin (flipped views, CG global display space).
public enum SelectionMath {
    /// Below this a drag counts as a click.
    public static let minSize: CGFloat = 4

    public static func clamp(_ p: CGPoint, to b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    /// The rect spanned by a drag in any direction, kept inside `bounds`.
    public static func rect(from a: CGPoint, to b: CGPoint, in bounds: CGRect) -> CGRect {
        let p = clamp(a, to: bounds)
        let q = clamp(b, to: bounds)
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }

    public static func point(of h: Handle, on r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The grip under `p`, corners first so a small selection still resizes diagonally.
    public static func handle(at p: CGPoint, on r: CGRect, radius: CGFloat = 8) -> Handle? {
        let order: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        return order.first { h in
            let q = point(of: h, on: r)
            return abs(q.x - p.x) <= radius && abs(q.y - p.y) <= radius
        }
    }

    /// Drags one grip to `p`; the opposite edges stay where they are. Crossing over flips cleanly.
    public static func resize(_ r: CGRect, handle h: Handle, to p: CGPoint, in bounds: CGRect) -> CGRect {
        let q = clamp(p, to: bounds)
        let minX: CGFloat = [.topLeft, .bottomLeft, .left].contains(h) ? q.x : r.minX
        let maxX: CGFloat = [.topRight, .bottomRight, .right].contains(h) ? q.x : r.maxX
        let minY: CGFloat = [.topLeft, .topRight, .top].contains(h) ? q.y : r.minY
        let maxY: CGFloat = [.bottomLeft, .bottomRight, .bottom].contains(h) ? q.y : r.maxY
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// Moves `r` by `d`, never past the edges of `bounds`.
    public static func move(_ r: CGRect, by d: CGVector, in bounds: CGRect) -> CGRect {
        let x = min(max(r.minX + d.dx, bounds.minX), bounds.maxX - r.width)
        let y = min(max(r.minY + d.dy, bounds.minY), bounds.maxY - r.height)
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// Whole pixels for cropping an image captured at `scale`.
    /// A Cocoa screen point (origin bottom left) as a point in that screen's view (origin top left).
    public static func viewPoint(mouse: CGPoint, screenFrame f: CGRect) -> CGPoint {
        CGPoint(x: mouse.x - f.minX, y: f.maxY - mouse.y)
    }

    /// What a click without a drag takes: the frontmost window under the point, else the whole screen.
    public static func pick(windows: [CGRect], at p: CGPoint, in bounds: CGRect) -> CGRect {
        (windows.first { $0.contains(p) } ?? bounds).intersection(bounds)
    }

    public static func pixelRect(_ r: CGRect, scale: CGFloat) -> CGRect {
        let x = (r.minX * scale).rounded()
        let y = (r.minY * scale).rounded()
        return CGRect(x: x, y: y, width: (r.maxX * scale).rounded() - x, height: (r.maxY * scale).rounded() - y)
    }

    /// Where the round buttons go: under the selection, else above it, else inside along the bottom.
    /// The tool strip sits above the selection: on its left edge, or centred when the selection is narrower.
    /// Without room above it moves inside the selection.
    public static func stripOrigin(selection s: CGRect, stripSize: CGSize, bounds: CGRect, gap: CGFloat = 10) -> CGPoint {
        let wanted = s.width >= stripSize.width ? s.minX : s.midX - stripSize.width / 2
        let x = min(max(wanted, bounds.minX + 8), bounds.maxX - stripSize.width - 8)
        let above = s.minY - gap - stripSize.height
        return CGPoint(x: x, y: above >= bounds.minY + 4 ? above : s.minY + gap)
    }

    public static func barOrigin(selection s: CGRect, barSize: CGSize, bounds: CGRect, gap: CGFloat = 16) -> CGPoint {
        let x = min(max(s.midX - barSize.width / 2, bounds.minX + 8), bounds.maxX - barSize.width - 8)
        if s.maxY + gap + barSize.height <= bounds.maxY - 8 { return CGPoint(x: x, y: s.maxY + gap) }
        if s.minY - gap - barSize.height >= bounds.minY + 8 { return CGPoint(x: x, y: s.minY - gap - barSize.height) }
        return CGPoint(x: x, y: s.maxY - gap - barSize.height)
    }
}

/// The row under the selection: the size on the left, then one wide Screenshot button with the small
/// screencast and GIF circles beside it, the pin, and settings on the right corner.
/// Positions are left edges, in points from the bar's left.
public enum BarLayout {
    public static let white: CGFloat = 48
    public static let prime: CGFloat = 56
    public static let small: CGFloat = 44
    public static let ghost: CGFloat = 40
    /// The Screenshot button: as tall as `prime`, wide enough for its word and the Return key.
    public static let wide: CGFloat = 200
    public static let gap: CGFloat = 10
    /// Room for the shadow around the buttons.
    public static let pad: CGFloat = 6
    /// Room kept at the left for the size label.
    public static let label: CGFloat = 150
    static let group = wide + gap + small + gap + small
    /// Narrowest bar in which nothing overlaps.
    public static let minWidth: CGFloat = label + gap + group + 8 + ghost + gap + white

    /// As wide as the selection, never narrower than `minWidth` or wider than the screen.
    public static func width(for selection: CGRect, in bounds: CGRect) -> CGFloat {
        max(min(max(selection.width, minWidth), bounds.width - 16 - 2 * pad), minWidth)
    }

    /// Left edges of the size label, screenshot, screencast, GIF, pin, settings.
    /// The group is centred, but never closer to the size label than one gap.
    public static func slots(width: CGFloat) -> [CGFloat] {
        let start = max(label + gap, ((width - group) / 2).rounded())
        return [0, start, start + wide + gap, start + wide + small + 2 * gap, start + group + 8, width - white]
    }
}

/// Where the toast goes: top right, a little under the menu bar. The menu bar counts even when it hides
/// itself (then `visible` reaches the top of the screen) and on a notch screen (`safeTop`).
public enum ToastPlacement {
    public static let gap: CGFloat = 12
    /// A menu bar is never thinner than this, also when it is hidden at the moment.
    public static let minMenuBar: CGFloat = 24
    /// Transparent room between the top of the panel and the card, for the close button.
    public static let cardInset: CGFloat = 10

    /// The panel frame in Cocoa screen coordinates (origin bottom left).
    public static func frame(size: CGSize, screen: CGRect, visible: CGRect, safeTop: CGFloat, menuBar: CGFloat) -> CGRect {
        let bar = max(screen.maxY - visible.maxY, safeTop, menuBar, minMenuBar)
        let top = screen.maxY - bar - gap + cardInset
        return CGRect(x: visible.maxX - size.width - 2, y: top - size.height, width: size.width, height: size.height)
    }
}
