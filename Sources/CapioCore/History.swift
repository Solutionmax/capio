import Foundation

public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case screenshot, screencast, gif

    public var fileExtension: String {
        switch self {
        case .screenshot: return "png"
        case .screencast: return "mp4"
        case .gif: return "gif"
        }
    }

    public var badge: String { fileExtension.uppercased() }
}

/// One capture on disk, plus where it went in Amfora.
public struct CaptureRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let kind: CaptureKind
    public let createdAt: Date
    public let bytes: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: Double?
    public let link: String?
    public let amforaFileId: String?
    public let amforaShareId: String?
    public let ocrText: String?
    /// When the link was made; nil for links from before 0.5, which count from `createdAt`.
    public let uploadedAt: Date?

    /// A link lives a week; then the share and the file leave Amfora and the capture stays on this Mac only.
    public static let linkLifetime: TimeInterval = 7 * 86_400

    public init(id: UUID = UUID(), fileName: String, kind: CaptureKind, createdAt: Date, bytes: Int64,
                pixelWidth: Int, pixelHeight: Int, duration: Double? = nil, link: String? = nil,
                amforaFileId: String? = nil, amforaShareId: String? = nil, ocrText: String? = nil, uploadedAt: Date? = nil) {
        self.id = id; self.fileName = fileName; self.kind = kind; self.createdAt = createdAt; self.bytes = bytes
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.duration = duration; self.link = link
        self.amforaFileId = amforaFileId; self.amforaShareId = amforaShareId; self.ocrText = ocrText
        self.uploadedAt = uploadedAt
    }

    public func uploaded(link: String, fileId: String, shareId: String, at date: Date = Date()) -> CaptureRecord {
        CaptureRecord(id: id, fileName: fileName, kind: kind, createdAt: createdAt, bytes: bytes,
                      pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, link: link,
                      amforaFileId: fileId, amforaShareId: shareId, ocrText: ocrText, uploadedAt: date)
    }

    /// A link from before 0.5 has no upload time; it gets its own week from `now` instead of vanishing at once.
    public func stampingLegacyLink(_ now: Date) -> CaptureRecord {
        guard link != nil, uploadedAt == nil else { return self }
        return CaptureRecord(id: id, fileName: fileName, kind: kind, createdAt: createdAt, bytes: bytes,
                             pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, link: link,
                             amforaFileId: amforaFileId, amforaShareId: amforaShareId, ocrText: ocrText, uploadedAt: now)
    }

    /// Whether the link belongs to the Amfora at `base` (the address in Settings may have changed since).
    public func linkIsOn(_ base: URL) -> Bool {
        guard let link, let host = URL(string: link)?.host else { return false }
        return host == base.host
    }

    /// Whether the link is a week old and should be taken off Amfora.
    public func linkExpired(now: Date) -> Bool {
        guard link != nil else { return false }
        return now.timeIntervalSince(uploadedAt ?? createdAt) >= Self.linkLifetime
    }

    public func withoutUpload() -> CaptureRecord {
        CaptureRecord(id: id, fileName: fileName, kind: kind, createdAt: createdAt, bytes: bytes,
                      pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, ocrText: ocrText)
    }

    public func with(ocrText text: String) -> CaptureRecord {
        CaptureRecord(id: id, fileName: fileName, kind: kind, createdAt: createdAt, bytes: bytes,
                      pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration, link: link,
                      amforaFileId: amforaFileId, amforaShareId: amforaShareId, ocrText: text, uploadedAt: uploadedAt)
    }
}

struct HistoryFile: Codable {
    let version: Int
    let records: [CaptureRecord]
}

/// The capture index. Newest first. Writes are atomic; a file it cannot read is set aside, never overwritten.
public final class HistoryStore {
    public let indexURL: URL
    public private(set) var records: [CaptureRecord]
    /// Set when the index could not be read and was moved to this path.
    public private(set) var setAside: URL?

    public init(indexURL: URL) {
        self.indexURL = indexURL
        self.records = []
        guard let data = try? Data(contentsOf: indexURL) else { return }
        if let file = try? Self.decoder.decode(HistoryFile.self, from: data) {
            records = file.records.sorted { $0.createdAt > $1.createdAt }
        } else {
            let aside = indexURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
            setAside = aside
        }
    }

    public func record(id: UUID) -> CaptureRecord? { records.first { $0.id == id } }

    public func add(_ r: CaptureRecord) throws {
        try commit([r] + records.filter { $0.id != r.id })
    }

    public func replace(_ r: CaptureRecord) throws {
        guard records.contains(where: { $0.id == r.id }) else { return }
        try commit(records.map { $0.id == r.id ? r : $0 })
    }

    public func remove(id: UUID) throws {
        try commit(records.filter { $0.id != id })
    }

    private func commit(_ next: [CaptureRecord]) throws {
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(HistoryFile(version: 1, records: next))
        try data.write(to: indexURL, options: .atomic)
        records = next
    }

    /// Captures whose link is a week old, in the order given.
    public static func expiredLinks(_ records: [CaptureRecord], now: Date) -> [CaptureRecord] {
        records.filter { $0.linkExpired(now: now) }
    }

    /// Filter by kind and a free text query over the name, the link and the recognised text.
    public static func filter(_ records: [CaptureRecord], kind: CaptureKind?, query: String) -> [CaptureRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return records.filter { r in
            guard kind == nil || r.kind == kind else { return false }
            guard !q.isEmpty else { return true }
            let hay = [r.fileName, r.link ?? "", r.ocrText ?? ""].joined(separator: "\n")
            return hay.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum CaptureNaming {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// "Capio 2026-11-21 at 10.42.31.png", with " (2)" and up when the name is taken.
    /// `ext` is for a screenshot saved as something other than PNG.
    public static func fileName(kind: CaptureKind, ext: String? = nil, date: Date, isTaken: (String) -> Bool) -> String {
        let stem = "Capio \(formatter.string(from: date))"
        let ext = ext ?? kind.fileExtension
        let first = "\(stem).\(ext)"
        guard isTaken(first) else { return first }
        let n = (2...).first { !isTaken("\(stem) (\($0)).\(ext)") } ?? 2
        return "\(stem) (\(n)).\(ext)"
    }

    /// "214 KB", "1.2 MB".
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "Today 10:42", "Yesterday 16:20", "Thu 19 Nov"; with the year once it is another year.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 || days == 1 {
            f.dateFormat = "HH:mm"
            return "\(days == 0 ? "Today" : "Yesterday") \(f.string(from: date))"
        }
        f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "EEE d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }

    /// "0:48", "2:10", "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
