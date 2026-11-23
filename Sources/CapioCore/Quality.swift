import Foundation

/// How a screenshot is written to disk.
public enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpegHigh, jpegMedium

    public var title: String {
        switch self {
        case .png: return "PNG"
        case .jpegHigh: return "JPEG High"
        case .jpegMedium: return "JPEG Medium"
        }
    }

    public var fileExtension: String { self == .png ? "png" : "jpg" }

    /// nil for PNG, which has no quality to choose.
    public var jpegQuality: Double? {
        switch self {
        case .png: return nil
        case .jpegHigh: return 0.9
        case .jpegMedium: return 0.7
        }
    }
}

/// Retina keeps every pixel of the display; Normal is one pixel a point.
public enum ImageSize: String, CaseIterable, Sendable {
    case retina, normal

    public var title: String { self == .retina ? "Retina (2x)" : "Normal (1x)" }
}

public enum VideoSize: String, CaseIterable, Sendable {
    case original, p1080, p720

    public var title: String {
        switch self {
        case .original: return "Original"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    /// The tallest a video may be, in pixels; nil keeps the area as it is.
    public var maxHeight: Int? {
        switch self {
        case .original: return nil
        case .p1080: return 1080
        case .p720: return 720
        }
    }
}

/// The choices in Settings for video, GIF and screenshot, and what they cost.
public enum Quality {
    public static let videoRates = [30, 60]
    public static let defaultVideoRate = 30
    public static let gifWidths = [480, 640, 800, 1200]
    public static let defaultGIFWidth = 800
    public static let gifRates = [10, 15, 20]
    public static let defaultGIFRate = 15

    /// A stored number that is no longer one of the choices falls back to the default.
    public static func choice(_ stored: Int, from options: [Int], fallback: Int) -> Int {
        options.contains(stored) ? stored : fallback
    }

    /// Pixel size of the video for an area of `width` x `height` pixels: at most `size.maxHeight` high,
    /// never enlarged, both sides even (H.264 wants that).
    public static func videoPixels(width: Int, height: Int, size: VideoSize) -> (width: Int, height: Int) {
        guard let limit = size.maxHeight, height > limit else { return (width & ~1, height & ~1) }
        // A tall narrow area keeps a width the encoder accepts.
        return (max(16, Int(Double(width) * Double(limit) / Double(height)) & ~1), limit)
    }

    /// The most H.264 can carry (level 5.2), in 16 x 16 blocks a second. 4K at 60 fits, 5K at 60 does not.
    static let maxBlocksPerSecond = 2_073_600

    /// The frame rate a video of this size is recorded at: `wanted`, or 30 when the area is too large for more.
    public static func videoRate(width: Int, height: Int, wanted: Int) -> Int {
        let blocks = ((width + 15) / 16) * ((height + 15) / 16)
        return blocks * wanted > maxBlocksPerSecond ? min(wanted, defaultVideoRate) : wanted
    }

    /// Three bits a pixel a second with a floor of 2 Mbps; 60 frames a second get half as much again.
    public static func videoBitRate(width: Int, height: Int, fps: Int) -> Int {
        let base = max(2_000_000, width * height * 3)
        return fps > 30 ? base * 3 / 2 : base
    }

    public static func megabytesPerMinute(bitRate: Int) -> Int {
        Int((Double(bitRate) * 60 / 8 / 1_000_000).rounded())
    }

    /// Size of a GIF next to the default (800 wide, 15 frames a second): pixels times frames.
    public static func gifFactor(width: Int, rate: Int) -> Double {
        let w = Double(width) / Double(defaultGIFWidth)
        return w * w * Double(rate) / Double(defaultGIFRate)
    }

    /// The line under the video choices. `screen` is the full display in pixels.
    public static func videoHint(size: VideoSize, fps: Int, screen: (width: Int, height: Int)) -> String {
        let px = videoPixels(width: screen.width, height: screen.height, size: size)
        let rate = videoRate(width: px.width, height: px.height, wanted: fps)
        let mb = megabytesPerMinute(bitRate: videoBitRate(width: px.width, height: px.height, fps: rate))
        let capped = rate < fps ? " A full screen is too large for \(fps) and records at \(rate)." : ""
        switch size {
        case .original: return "Full sharpness. A full screen can reach \(mb) MB a minute. Small areas are never enlarged." + capped
        case .p1080: return "Good for sharing. A full screen is about \(mb) MB a minute."
        case .p720: return "Smallest. About \(mb) MB a minute, small text gets soft."
        }
    }

    public static func gifHint(width: Int, rate: Int) -> String {
        let factor = gifFactor(width: width, rate: rate)
        let reference = "\(defaultGIFWidth) at \(defaultGIFRate)"
        if abs(factor - 1) < 0.01 { return "Fine for most captures. GIFs have no sound." }
        if factor < 1 { return "Smaller file: about \(Int((factor * 100).rounded()))% of the size of \(reference)." }
        let times = String(format: "%.1f", factor).replacingOccurrences(of: ".0", with: "")
        return "Larger file: about \(times) times the size of \(reference)."
    }

    public static func imageHint(format: ImageFormat, size: ImageSize) -> String {
        let first: String
        switch format {
        case .png: first = "PNG keeps text sharp. JPEG is smaller for photos and a little softer for text."
        case .jpegHigh: first = "Smaller than PNG for photos. Text stays almost as sharp."
        case .jpegMedium: first = "Smallest file. Fine for photos, text shows light smudges."
        }
        return size == .retina ? first : first + " Normal keeps a quarter of the pixels of a Retina display and looks soft when zoomed in."
    }

    /// The Content-Type Amfora stores with an upload.
    public static func mime(fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
