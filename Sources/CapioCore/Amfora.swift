import Foundation

/// Where uploads go: an Amfora installation and a full access API key.
public struct AmforaConfig: Equatable, Sendable {
    public let base: URL
    public let key: String

    /// Accepts "share.example.net", "https://share.example.net/" and the like. Only https, except on a LAN address.
    public init?(address: String, key: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !k.isEmpty, !k.contains(where: \.isNewline) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var parts = URLComponents(string: withScheme), let host = parts.host, !host.isEmpty else { return nil }
        guard parts.scheme == "https" || (parts.scheme == "http" && Self.isLocal(host)) else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { return nil }
        self.base = url
        self.key = k
    }

    /// localhost, *.local, or a private IPv4 literal (10/8, 127/8, 172.16/12, 192.168/16). Names are never "local".
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { p -> Int? in p.allSatisfy(\.isNumber) && p.count <= 3 ? Int(p) : nil }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, let b): return (16...31).contains(b)
        default: return false
        }
    }

    public var isLocal: Bool { Self.isLocal(base.host ?? "") }
}

public struct AmforaError: LocalizedError, Equatable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { status > 0 ? "Amfora answered \(status): \(message)" : message }
}

public struct AmforaUpload: Equatable, Sendable {
    public let fileId: String
    public let shareId: String
    public let link: String
}

/// The requests, kept pure so the self test can check them without a server.
public enum AmforaAPI {
    static let userAgent = "Capio/0.5 (macOS)"

    static func request(_ cfg: AmforaConfig, _ method: String, _ path: String,
                        query: [URLQueryItem] = [], json: [String: Any]? = nil) -> URLRequest {
        var parts = URLComponents(url: cfg.base.appendingPathComponent("api/v1" + path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: parts.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return req
    }

    public static func me(_ cfg: AmforaConfig) -> URLRequest { request(cfg, "GET", "/auth/me") }

    /// The object key gets a random stem: file names with spaces stay out of storage URLs. The size lets
    /// Amfora 2.4.1 and later reserve only what the file needs (without it, a whole maximum file counts against the quota).
    public static func presign(_ cfg: AmforaConfig, stem: String, ext: String, size: Int64) -> URLRequest {
        request(cfg, "GET", "/files/presigned-url", query: [
            URLQueryItem(name: "filename", value: stem), URLQueryItem(name: "extension", value: ext),
            URLQueryItem(name: "size", value: String(size)),
        ])
    }

    public static func register(_ cfg: AmforaConfig, name: String, ext: String, size: Int64, objectName: String) -> URLRequest {
        request(cfg, "POST", "/files", json: ["name": name, "extension": ext, "size": size, "objectName": objectName])
    }

    public static func share(_ cfg: AmforaConfig, fileId: String, name: String, expiration: Date?) -> URLRequest {
        var body: [String: Any] = ["name": name, "files": [fileId]]
        if let expiration { body["expiration"] = ISO8601DateFormatter().string(from: expiration) }
        return request(cfg, "POST", "/shares", json: body)
    }

    /// Every share ends after a week, so a link dies on Amfora even when this Mac is off.
    public static func shareEnd(from now: Date) -> Date { now.addingTimeInterval(CaptureRecord.linkLifetime) }

    public static func alias(_ cfg: AmforaConfig, shareId: String, alias: String) -> URLRequest {
        request(cfg, "POST", "/shares/\(shareId)/alias", json: ["alias": alias])
    }

    public static func deleteShare(_ cfg: AmforaConfig, id: String) -> URLRequest { request(cfg, "DELETE", "/shares/\(id)") }
    public static func deleteFile(_ cfg: AmforaConfig, id: String) -> URLRequest { request(cfg, "DELETE", "/files/\(id)") }

    /// With the viewer next to Amfora every capture opens at `/v/<alias>`. Without it, pictures link straight
    /// to the file so chats show them inline, and a video links to its share page.
    public static func link(_ cfg: AmforaConfig, kind: CaptureKind, fileId: String, alias: String, viewer: Bool = false) -> String {
        let host = cfg.base.absoluteString.hasSuffix("/") ? String(cfg.base.absoluteString.dropLast()) : cfg.base.absoluteString
        if viewer { return "\(host)/v/\(alias)" }
        return kind == .screencast ? "\(host)/s/\(alias)" : "\(host)/e/\(fileId)"
    }

    public static func token(_ length: Int) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    /// The text of an error answer: Amfora sends {"error": ...} or {"message": ...}.
    public static func message(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in ["error", "message"] { if let s = obj[k] as? String, !s.isEmpty { return s } }
        }
        let text = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no details" : text
    }
}

/// Upload, share, delete. One instance per upload is fine; it holds no state beyond the config.
public final class AmforaClient {
    public let cfg: AmforaConfig
    let session: URLSession

    public init(cfg: AmforaConfig, session: URLSession? = nil) {
        self.cfg = cfg
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    /// The account behind the key, to show in Settings.
    public func whoAmI() async throws -> String {
        let obj = try await json(AmforaAPI.me(cfg))
        let user = (obj["user"] as? [String: Any]) ?? obj
        return (user["username"] as? String) ?? (user["email"] as? String) ?? "your account"
    }

    public func upload(file: URL, kind: CaptureKind, viewerLinks: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws -> AmforaUpload {
        let ext = file.pathExtension.isEmpty ? kind.fileExtension : file.pathExtension.lowercased()
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let presigned = try await json(AmforaAPI.presign(cfg, stem: AmforaAPI.token(12), ext: ext, size: size))
        guard let urlString = presigned["url"] as? String, let putURL = URL(string: urlString),
              let objectName = presigned["objectName"] as? String else {
            throw AmforaError(status: 0, message: "Amfora gave no upload address.")
        }
        guard putURL.scheme == "https" || (putURL.scheme == "http" && (cfg.isLocal || AmforaConfig.isLocal(putURL.host ?? ""))) else {
            throw AmforaError(status: 0, message: "Amfora gave an upload address without https; nothing was sent.")
        }
        var put = URLRequest(url: putURL)
        put.httpMethod = "PUT"
        put.timeoutInterval = 600
        put.setValue(Quality.mime(fileExtension: ext), forHTTPHeaderField: "Content-Type")
        let (_, putResponse) = try await session.upload(for: put, fromFile: file, delegate: ProgressDelegate(progress))
        let putStatus = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(putStatus) else { throw AmforaError(status: putStatus, message: "storage refused the upload") }

        let registered = try await retrying(times: 3, when: { $0.status == 503 }) {
            try await self.json(AmforaAPI.register(self.cfg, name: file.lastPathComponent, ext: ext, size: size, objectName: objectName))
        }
        guard let fileId = (registered["file"] as? [String: Any])?["id"] as? String else {
            throw AmforaError(status: 0, message: "Amfora did not return the new file.")
        }
        let shared = try await createShare(fileId: fileId, name: file.deletingPathExtension().lastPathComponent)
        guard let shareId = (shared["share"] as? [String: Any])?["id"] as? String else {
            throw AmforaError(status: 0, message: "Amfora did not return the new share.")
        }
        let alias = AmforaAPI.token(10)
        _ = try await json(AmforaAPI.alias(cfg, shareId: shareId, alias: alias))
        return AmforaUpload(fileId: fileId, shareId: shareId, link: AmforaAPI.link(cfg, kind: kind, fileId: fileId, alias: alias, viewer: viewerLinks))
    }

    /// Removes the share first (the link dies at once), then moves the file to Amfora's trash.
    public func deleteUpload(fileId: String?, shareId: String?) async throws {
        if let shareId { try await ignoringNotFound { _ = try await self.json(AmforaAPI.deleteShare(self.cfg, id: shareId)) } }
        if let fileId { try await ignoringNotFound { _ = try await self.json(AmforaAPI.deleteFile(self.cfg, id: fileId)) } }
    }

    /// A file still being checked by the virus scan cannot be shared yet. The share ends after a week.
    func createShare(fileId: String, name: String) async throws -> [String: Any] {
        let expiration = AmforaAPI.shareEnd(from: Date())
        for attempt in 0..<12 {
            do {
                return try await json(AmforaAPI.share(cfg, fileId: fileId, name: name, expiration: expiration))
            } catch let e as AmforaError where e.status == 400 && e.message.localizedCaseInsensitiveContains("being checked") && attempt < 11 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw AmforaError(status: 0, message: "Amfora kept the file in the virus check; try sharing it later.")
    }

    func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AmforaError(status: status, message: AmforaAPI.message(from: data)) }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func retrying<T>(times: Int, when retry: (AmforaError) -> Bool, _ op: () async throws -> T) async throws -> T {
        for _ in 1..<times {
            do { return try await op() } catch let e as AmforaError where retry(e) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return try await op()
    }

    func ignoringNotFound(_ op: () async throws -> Void) async throws {
        // Amfora answers a share that is already gone with 400 "Share not found", a file with 404.
        do { try await op() } catch let e as AmforaError where e.status == 404 || e.message.localizedCaseInsensitiveContains("not found") {}
    }
}

/// Follows a redirect only to the same scheme and host, so the API key is never sent anywhere else.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url
        let same = request.url?.scheme == from?.scheme && request.url?.host == from?.host && request.url?.port == from?.port
        completionHandler(same ? request : nil)
    }
}

final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: @Sendable (Double) -> Void
    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
