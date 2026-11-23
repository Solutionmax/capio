import CoreGraphics
import CoreText
import Foundation

public enum Tool: String, CaseIterable, Codable, Sendable {
    case arrow, rectangle, pen, text, highlight, number, obfuscate

    /// Single letter shortcut, as in the tool menu.
    public var key: String {
        switch self {
        case .arrow: return "a"
        case .rectangle: return "r"
        case .pen: return "p"
        case .text: return "t"
        case .highlight: return "h"
        case .number: return "n"
        case .obfuscate: return "o"
        }
    }

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// SF Symbol for menus and the draw button.
    public var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .number: return "1.circle"
        case .obfuscate: return "eye.slash"
        }
    }

    public static func forKey(_ k: String) -> Tool? { allCases.first { $0.key == k.lowercased() } }
}

public struct RGBA: Equatable, Codable, Sendable {
    public let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32) {
        self.init(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255)
    }

    public func with(alpha: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
    /// Perceived brightness, 0 to 1.
    public var luminance: CGFloat { 0.299 * r + 0.587 * g + 0.114 * b }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

public enum Palette {
    public static let indigo = RGBA(hex: 0x5B5CF0)
    public static let red = RGBA(hex: 0xF2364A)
    public static let yellow = RGBA(hex: 0xFFD23F)
    public static let green = RGBA(hex: 0x22C993)
    public static let pink = RGBA(hex: 0xFF3D8B)
    public static let all: [(name: String, color: RGBA)] = [
        ("Indigo", indigo), ("Red", red), ("Yellow", yellow), ("Green", green), ("Pink", pink),
    ]
    static let outline = RGBA(hex: 0x17181B)
}

/// One mark on a capture, in view points (top left origin).
public struct Annotation {
    public let tool: Tool
    public let color: RGBA
    /// arrow, rectangle, highlight, obfuscate: start and end. pen: the stroke. text, number: the anchor.
    public let points: [CGPoint]
    public let text: String
    public let number: Int
    /// obfuscate: the pixelated patch that covers `rect`.
    public let image: CGImage?

    public init(tool: Tool, color: RGBA, points: [CGPoint], text: String = "", number: Int = 0, image: CGImage? = nil) {
        self.tool = tool; self.color = color; self.points = points
        self.text = text; self.number = number; self.image = image
    }

    public func with(points: [CGPoint]) -> Annotation {
        Annotation(tool: tool, color: color, points: points, text: text, number: number, image: image)
    }

    public func with(image: CGImage?) -> Annotation {
        Annotation(tool: tool, color: color, points: points, text: text, number: number, image: image)
    }

    public var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .null }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A stray click with a drag tool should not leave a dot behind.
    public var isMeaningful: Bool {
        switch tool {
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: return !points.isEmpty
        case .pen: return points.count > 1
        case .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return hypot(b.x - a.x, b.y - a.y) >= 8
        case .rectangle, .highlight, .obfuscate:
            return rect.width >= 3 && rect.height >= 3
        }
    }
}

/// Draws annotations into a context whose user space is view points with a top left origin.
/// The live overlay and the exported PNG both go through here, so what you see is what you get.
public enum AnnotationRenderer {
    public static let lineWidth: CGFloat = 4
    public static let textSize: CGFloat = 22
    public static let numberRadius: CGFloat = 13

    public static func draw(_ list: [Annotation], in ctx: CGContext) {
        list.forEach { draw($0, in: ctx) }
    }

    public static func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch a.tool {
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.with(alpha: 0.45).cgColor)
            ctx.fill(a.rect)
        case .obfuscate:
            drawPatch(a, in: ctx)
        case .rectangle:
            shadow(ctx)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.addPath(CGPath(roundedRect: a.rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
        case .arrow:
            guard let p = a.points.first, let q = a.points.last else { return }
            shadow(ctx)
            ctx.addPath(arrowPath(from: p, to: q))
            ctx.setFillColor(a.color.cgColor)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.setLineJoin(.round)
            ctx.drawPath(using: .fillStroke)
        case .pen:
            guard let first = a.points.first else { return }
            shadow(ctx)
            ctx.move(to: first)
            a.points.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        case .number:
            guard let c = a.points.first else { return }
            drawNumber(a.number, at: c, color: a.color, in: ctx)
        case .text:
            guard let anchor = a.points.first else { return }
            drawText(a.text, at: anchor, color: a.color, in: ctx)
        }
    }

    /// A tapered arrow pointing from `p` to `q`: thin tail, solid head.
    public static func arrowPath(from p: CGPoint, to q: CGPoint) -> CGPath {
        let length = max(hypot(q.x - p.x, q.y - p.y), 1)
        let head = min(26, max(12, length * 0.4))
        let half = head * 0.52
        let neck: CGFloat = 4
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: 0, y: -1.5), CGPoint(x: length - head + 3, y: -neck), CGPoint(x: length - head, y: -half),
            CGPoint(x: length, y: 0),
            CGPoint(x: length - head, y: half), CGPoint(x: length - head + 3, y: neck), CGPoint(x: 0, y: 1.5),
        ])
        path.closeSubpath()
        let t = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: atan2(q.y - p.y, q.x - p.x))
        return path.copy(using: [t]) ?? path
    }

    /// Size of a text mark, so the editor can place and hit test it.
    public static func textBounds(_ text: String, at anchor: CGPoint) -> CGRect {
        let line = makeLine(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGRect(x: anchor.x, y: anchor.y, width: CGFloat(width), height: ascent + descent)
    }

    static func shadow(_ ctx: CGContext) {
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
    }

    static func drawPatch(_ a: Annotation, in ctx: CGContext) {
        let r = a.rect
        guard let img = a.image else {
            ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
            ctx.fill(r)
            return
        }
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
    }

    static func drawNumber(_ n: Int, at c: CGPoint, color: RGBA, in ctx: CGContext) {
        let circle = CGRect(x: c.x - numberRadius, y: c.y - numberRadius, width: numberRadius * 2, height: numberRadius * 2)
        ctx.saveGState()
        shadow(ctx)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
        let font = boldFont(13)
        let line = makeLine(String(n), font: font)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: c.x - width / 2, y: c.y + CTFontGetCapHeight(font) / 2)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.setTextDrawingMode(.fill)
        CTLineDraw(line, ctx)
    }

    static func drawText(_ text: String, at anchor: CGPoint, color: RGBA, in ctx: CGContext) {
        let line = makeLine(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let baseline = CGPoint(x: anchor.x, y: anchor.y + ascent)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(5)
        // A light halo under dark text and a dark one under light text, so it reads on any picture.
        ctx.setStrokeColor(color.luminance < 0.5 ? CGColor(gray: 1, alpha: 1) : Palette.outline.cgColor)
        ctx.setTextDrawingMode(.stroke)
        ctx.textPosition = baseline
        CTLineDraw(line, ctx)
        ctx.setFillColor(color.cgColor)
        ctx.setTextDrawingMode(.fill)
        ctx.textPosition = baseline
        CTLineDraw(line, ctx)
    }

    static func boldFont(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    static func makeLine(_ text: String, font: CTFont = boldFont(textSize)) -> CTLine {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
    }
}
