import AppKit
import Carbon.HIToolbox
import CapioCore
import os
import Security
import SwiftUI
import UniformTypeIdentifiers

let log = Logger(subsystem: "net.solutionmax.capio", category: "app")

enum Theme {
    static let accent = NSColor(srgbRed: 0x5B / 255.0, green: 0x5C / 255.0, blue: 0xF0 / 255.0, alpha: 1)
    static var accentColor: Color { Color(nsColor: accent) }

    static func ns(_ c: RGBA) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// Menu bar glyph: viewfinder corners around the shutter dot. Template, so macOS tints it.
    static let menuBarIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let p = NSBezierPath()
            let corners: [[NSPoint]] = [
                [NSPoint(x: 3, y: 7.5), NSPoint(x: 3, y: 3), NSPoint(x: 7.5, y: 3)],
                [NSPoint(x: 10.5, y: 3), NSPoint(x: 15, y: 3), NSPoint(x: 15, y: 7.5)],
                [NSPoint(x: 15, y: 10.5), NSPoint(x: 15, y: 15), NSPoint(x: 10.5, y: 15)],
                [NSPoint(x: 7.5, y: 15), NSPoint(x: 3, y: 15), NSPoint(x: 3, y: 10.5)],
            ]
            for c in corners {
                p.move(to: c[0]); p.line(to: c[1]); p.line(to: c[2])
            }
            p.lineWidth = 1.7
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            NSColor.black.setStroke()
            p.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.4, y: 6.4, width: 5.2, height: 5.2)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()

    static let appIcon: NSImage = {
        guard let cg = CapioIcon.image(pixels: 128) else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: 64, height: 64))
    }()
}

extension View {
    /// Liquid Glass on macOS 26 and later, material before that.
    @ViewBuilder func glassPanel(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// System wide shortcuts through Carbon: no Accessibility permission needed.
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    /// What a pressed shortcut starts; set once at launch.
    var onPress: ((ShortcutAction) -> Void)?
    /// Actions whose keys macOS refused to register.
    private(set) var refused: Set<ShortcutAction> = []

    /// Replaces every registration with `set` and returns the actions that were refused.
    @discardableResult
    func apply(_ set: ShortcutSet) -> Set<ShortcutAction> {
        installHandlerOnce()
        pause()
        refused = []
        for action in ShortcutAction.allCases {
            guard let s = set[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4341_5049), id: action.id) // 'CAPI'
            let status = RegisterEventHotKey(UInt32(s.keyCode), UInt32(s.modifiers), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                refused.insert(action)
                log.error("shortcut for \(action.rawValue) refused (status \(status))")
            }
        }
        return refused
    }

    /// True for macOS's own shortcuts that are switched on (screenshots, Spotlight, Mission Control and so on).
    /// Limit: macOS does not tell which keys other apps hold, so only Capio's own and the system's are checked.
    static func usedBySystem(_ s: Shortcut) -> Bool {
        var out: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&out) == noErr, let list = out?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains {
            ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && ($0[kHISymbolicHotKeyCode as String] as? Int) == s.keyCode
                && ($0[kHISymbolicHotKeyModifiers as String] as? Int).map { $0 & 0x1B00 } == s.modifiers // Carbon mask, measured on macOS 26
        }
    }

    /// Lets go of every shortcut, so the settings pane can read the keys the user presses.
    func pause() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    private func installHandlerOnce() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = id.id
            DispatchQueue.main.async {
                guard let action = ShortcutAction.allCases.first(where: { $0.id == pressed }) else { return }
                HotKeys.shared.onPress?(action)
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// The Amfora API key lives in the login Keychain, never in preferences.
enum Keychain {
    static let service = "net.solutionmax.capio"
    static let account = "amfora-api-key"
    private static var cached: String??

    static func read() -> String? {
        // A snapshot run stays away from the real key: macOS may ask for it, and nobody is there to answer.
        if Prefs.dataDir != nil { return nil }
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let value = status == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        if status != errSecSuccess && status != errSecItemNotFound { log.error("keychain read failed: \(status)") }
        cached = .some(value)
        return value
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status == errSecSuccess { cached = .some(key) } else { log.error("keychain save failed: \(status)") }
        return status == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        cached = .some(nil)
    }
}

enum Prefs {
    static let defaults = UserDefaults.standard
    /// Shown as the example in Settings; there is no built in server, everyone names their own Amfora.
    static let serverExample = "https://files.example.net"

    static var server: String {
        get { defaults.string(forKey: "server") ?? "" }
        set { defaults.set(newValue, forKey: "server") }
    }

    /// "Always create an external link". Off: a capture stays on this Mac until you ask for a link.
    static var uploadEnabled: Bool {
        get { defaults.bool(forKey: "upload") }
        set { defaults.set(newValue, forKey: "upload") }
    }

    /// 0.4 sent every capture to Amfora; from 0.5 that is a choice. Turns it off once, after that it is yours.
    static func migrate() {
        guard !defaults.bool(forKey: "migrated05") else { return }
        defaults.set(false, forKey: "upload")
        defaults.set(true, forKey: "migrated05")
    }

    static var shortcuts: ShortcutSet {
        get { ShortcutSet(stored: (defaults.dictionary(forKey: "shortcuts") ?? [:]).compactMapValues { $0 as? String }) }
        set { defaults.set(newValue.stored, forKey: "shortcuts") }
    }

    /// Keys shared with `@AppStorage` in the settings panes.
    enum Key {
        static let screenshotSound = "screenshotSound"
        static let drawColor = "drawColor"
        static let micOn = "micOn"
        static let camOn = "camOn"
        static let clickRings = "clickRings"
        static let viewerLinks = "viewerLinks"
        static let imageFormat = "imageFormat"
        static let imageSize = "imageSize"
        static let videoSize = "videoSize"
        static let videoRate = "videoRate"
        static let gifWidth = "gifWidth"
        static let gifRate = "gifRate"
        static let autoCheck = "autoCheck"
        static let autoInstall = "autoInstall"
    }

    /// Updates: look when Capio starts and once a day (on until switched off), and ask before installing (until switched on).
    static var autoCheck: Bool { defaults.object(forKey: Key.autoCheck) as? Bool ?? true }
    static var autoInstall: Bool { defaults.bool(forKey: Key.autoInstall) }
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }
    /// The version the user chose Skip This Version for; the one after it is offered again.
    static var skippedVersion: String? {
        get { defaults.string(forKey: "skippedVersion") }
        set { defaults.set(newValue, forKey: "skippedVersion") }
    }

    // Nothing stored means what Capio always did: PNG at Retina, video as large as the area at 30.
    static var imageFormat: ImageFormat { defaults.string(forKey: Key.imageFormat).flatMap(ImageFormat.init) ?? .png }
    static var imageSize: ImageSize { defaults.string(forKey: Key.imageSize).flatMap(ImageSize.init) ?? .retina }
    static var videoSize: VideoSize { defaults.string(forKey: Key.videoSize).flatMap(VideoSize.init) ?? .original }
    static var videoRate: Int { Quality.choice(defaults.integer(forKey: Key.videoRate), from: Quality.videoRates, fallback: Quality.defaultVideoRate) }
    static var gifWidth: Int { Quality.choice(defaults.integer(forKey: Key.gifWidth), from: Quality.gifWidths, fallback: Quality.defaultGIFWidth) }
    static var gifRate: Int { Quality.choice(defaults.integer(forKey: Key.gifRate), from: Quality.gifRates, fallback: Quality.defaultGIFRate) }

    static var screenshotSound: Bool { defaults.bool(forKey: Key.screenshotSound) }
    /// Off until the viewer runs next to Amfora; a /v/ link without it leads nowhere.
    static var viewerLinks: Bool { defaults.bool(forKey: Key.viewerLinks) }
    static var clickRings: Bool { defaults.object(forKey: Key.clickRings) as? Bool ?? true }

    /// The colour a new drawing starts with; a stale index falls back to the first.
    static var drawColor: RGBA {
        let i = defaults.integer(forKey: Key.drawColor)
        return Palette.all.indices.contains(i) ? Palette.all[i].color : Palette.all[0].color
    }

    /// Snapshot runs keep their files apart from the real ones.
    static let dataDir = ProcessInfo.processInfo.environment["CAPIO_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    // Limit: records keep only a file name, so captures made before a folder change are looked up in the new folder.
    static var folder: URL {
        get {
            if let dataDir { return dataDir.appendingPathComponent("Captures", isDirectory: true) }
            if let p = defaults.string(forKey: "folder") { return URL(fileURLWithPath: p, isDirectory: true) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Capio", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "folder") }
    }

    static var folderDisplay: String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// The Amfora behind the saved key, whether or not every capture goes there.
    static var amfora: AmforaConfig? {
        guard let key = Keychain.read() else { return nil }
        return AmforaConfig(address: server, key: key)
    }

    static var historyURL: URL {
        if let dataDir { return dataDir.appendingPathComponent("history.json") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Capio", isDirectory: true).appendingPathComponent("history.json")
    }
}

enum Sounds {
    /// The system's own screenshot sound; quiet when the file is not there.
    @MainActor private static let sound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    /// Kept in a static so it is not released halfway through playing.
    @MainActor static func shutter() {
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

enum Clipboard {
    /// The picture itself plus the file's own bytes, so an app that takes PNG or JPEG gets exactly what was saved.
    static func copyImage(data: Data, format: ImageFormat, image: NSImage) {
        let type: NSPasteboard.PasteboardType = format == .png ? .png : NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        pb.addTypes([type], owner: nil)
        pb.setData(data, forType: type)
    }

    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }
}
