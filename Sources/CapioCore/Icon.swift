import CoreGraphics

/// The Capio app icon: viewfinder corners and a shutter dot on an indigo squircle. Plain CG, origin bottom left.
public enum CapioIcon {
    public static func draw(in ctx: CGContext, side s: CGFloat, accent: RGBA = Palette.indigo) {
        let inset = s * 0.1
        let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let b = body.width
        let shape = CGPath(roundedRect: body, cornerWidth: b * 0.225, cornerHeight: b * 0.225, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(shape)
        ctx.setFillColor(accent.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let top = mix(accent, RGBA(r: 1, g: 1, b: 1), 0.24), bottom = mix(accent, RGBA(r: 0, g: 0, b: 0), 0.16)
        if let g = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        }
        if let gloss = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.42), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 0.6]) {
            ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: body.midX, y: body.maxY), startRadius: 0,
                                   endCenter: CGPoint(x: body.midX, y: body.maxY), endRadius: b * 0.9, options: [])
        }
        ctx.restoreGState()

        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: b * 0.008, dy: b * 0.008), cornerWidth: b * 0.218, cornerHeight: b * 0.218, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(b * 0.015)
        ctx.strokePath()

        let lo = body.minX + b * 0.27, hi = body.maxX - b * 0.27, arm = b * 0.13
        let ylo = body.minY + b * 0.27, yhi = body.maxY - b * 0.27
        let corners: [[CGPoint]] = [
            [CGPoint(x: lo, y: yhi - arm), CGPoint(x: lo, y: yhi), CGPoint(x: lo + arm, y: yhi)],
            [CGPoint(x: hi - arm, y: yhi), CGPoint(x: hi, y: yhi), CGPoint(x: hi, y: yhi - arm)],
            [CGPoint(x: hi, y: ylo + arm), CGPoint(x: hi, y: ylo), CGPoint(x: hi - arm, y: ylo)],
            [CGPoint(x: lo + arm, y: ylo), CGPoint(x: lo, y: ylo), CGPoint(x: lo, y: ylo + arm)],
        ]
        corners.forEach { ctx.addLines(between: $0) }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(b * 0.07)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        let c = CGPoint(x: body.midX, y: body.midY)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: c.x - b * 0.11, y: c.y - b * 0.11, width: b * 0.22, height: b * 0.22))
        ctx.setFillColor(accent.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - b * 0.045, y: c.y - b * 0.045, width: b * 0.09, height: b * 0.09))
    }

    public static func image(pixels: Int, accent: RGBA = Palette.indigo) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(in: ctx, side: CGFloat(pixels), accent: accent)
        return ctx.makeImage()
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: CGFloat) -> RGBA {
        RGBA(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: 1)
    }
}
