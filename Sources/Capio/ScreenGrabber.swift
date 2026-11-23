import AppKit
import ScreenCaptureKit

/// One display, frozen at the moment the shortcut was pressed.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
    /// Normal windows on this display, front to back, in view points (top left origin).
    let windows: [CGRect]
}

enum ScreenGrabber {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    @MainActor
    static func grabAll() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == getpid() }
        let windows = windowFrames()
        var out: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let scale = screen.backingScaleFactor
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let bounds = CGDisplayBounds(id)
            let local = windows.compactMap { $0.intersects(bounds) ? $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) : nil }
            out.append(FrozenScreen(screen: screen, image: image, scale: scale, windows: local))
        }
        return out
    }

    /// Window frames in CG global space (top left of the main display), front to back.
    static func windowFrames() -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let pid = Int(getpid())
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != pid,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d),
                  r.width > 40, r.height > 40 else { return nil }
            return r
        }
    }
}
