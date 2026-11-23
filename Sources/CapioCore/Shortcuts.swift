import Foundation

/// One system wide key combination. `modifiers` is the Carbon mask, `label` the key as the user's layout names it.
public struct Shortcut: Equatable, Sendable {
    public static let command = 0x100, shift = 0x200, option = 0x800, control = 0x1000

    public let keyCode: Int
    public let modifiers: Int
    public let label: String

    public init(keyCode: Int, modifiers: Int, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
        self.label = label
    }

    /// A bare key or Shift plus a key would swallow normal typing in every app.
    public var isValid: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 && !label.isEmpty }

    /// In the order macOS writes them: ⌃⌥⇧⌘ and then the key.
    public var display: String {
        let marks = [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
        return marks.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + label
    }

    /// Same keys, whatever the label says (a layout change renames a key, it does not move it).
    public func sameKeys(as other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    public var stored: String { "\(keyCode),\(modifiers),\(label)" }

    public init?(stored: String) {
        let parts = stored.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = Int(parts[0]), let mods = Int(parts[1]), (0..<256).contains(code) else { return nil }
        self.init(keyCode: code, modifiers: mods, label: String(parts[2]))
        guard isValid else { return nil }
    }

    private static let named: [Int: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
        76: "Enter", 117: "⌦", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 105: "F13", 107: "F14", 113: "F15",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Keys without a printable character get a name; the rest is what the key types without modifiers.
    public static func label(keyCode: Int, characters: String?) -> String {
        if let name = named[keyCode] { return name }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return c.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) } ? c : ""
    }

    /// NSEvent modifier flags (raw value) to the Carbon mask.
    public static func carbon(cocoaFlags: UInt) -> Int {
        let map: [(UInt, Int)] = [(1 << 20, command), (1 << 17, shift), (1 << 19, option), (1 << 18, control)]
        return map.reduce(0) { cocoaFlags & $1.0 != 0 ? $0 | $1.1 : $0 }
    }
}

/// What a system wide shortcut can start, in the order of the settings pane and the menu.
public enum ShortcutAction: String, CaseIterable, Sendable {
    case area, quick, window, screencast, gif

    public var title: String {
        switch self {
        case .area: return "Select an area"
        case .quick: return "Quick screenshot"
        case .window: return "Window screenshot"
        case .screencast: return "Screencast"
        case .gif: return "GIF"
        }
    }

    public var menuTitle: String {
        switch self {
        case .area: return "Select an Area"
        case .quick: return "Quick Screenshot"
        case .window: return "Window Screenshot"
        case .screencast: return "Record Screencast"
        case .gif: return "Record GIF"
        }
    }

    public var hint: String {
        switch self {
        case .area: return "Then pick photo, video or GIF"
        case .quick: return "Drag, let go, done"
        case .window: return "The window under the mouse, at once"
        case .screencast, .gif: return "Again to stop"
        }
    }

    public var standard: Shortcut {
        let mods = Shortcut.control | Shortcut.command
        switch self {
        case .window: return Shortcut(keyCode: 18, modifiers: mods, label: "1")
        case .area: return Shortcut(keyCode: 19, modifiers: mods, label: "2")
        case .quick: return Shortcut(keyCode: 20, modifiers: mods, label: "3")
        case .screencast: return Shortcut(keyCode: 21, modifiers: mods, label: "4")
        case .gif: return Shortcut(keyCode: 23, modifiers: mods, label: "5")
        }
    }

    /// Stable number for the hot key registration.
    public var id: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

/// The user's choice per action. An action without an entry has no shortcut.
public struct ShortcutSet: Equatable, Sendable {
    private let map: [ShortcutAction: Shortcut]
    private static let none = "none"

    public static let standard = ShortcutSet(map: Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.standard) }))

    private init(map: [ShortcutAction: Shortcut]) { self.map = map }

    /// From preferences. A missing or unreadable entry means the standard keys, unless another action already took them.
    public init(stored: [String: String]) {
        var out: [ShortcutAction: Shortcut] = [:]
        var fallback: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            let raw = stored[action.rawValue]
            if raw == Self.none { continue }
            if let s = raw.flatMap(Shortcut.init(stored:)), !out.values.contains(where: { $0.sameKeys(as: s) }) { out[action] = s } else { fallback.append(action) }
        }
        for action in fallback where !out.values.contains(where: { $0.sameKeys(as: action.standard) }) { out[action] = action.standard }
        map = out
    }

    public var stored: [String: String] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, map[$0]?.stored ?? Self.none) })
    }

    public subscript(action: ShortcutAction) -> Shortcut? { map[action] }

    /// The other action that already uses these keys.
    public func owner(of shortcut: Shortcut, besides action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && map[$0]?.sameKeys(as: shortcut) == true }
    }

    /// A copy with one action changed; nil takes the shortcut away.
    public func setting(_ shortcut: Shortcut?, for action: ShortcutAction) -> ShortcutSet {
        var copy = map
        copy[action] = shortcut
        return ShortcutSet(map: copy)
    }
}
