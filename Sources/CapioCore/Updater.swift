import CryptoKit
import Foundation
import Security

/// The newest release as Capio's update feed describes it.
public struct UpdateInfo: Equatable, Sendable {
    public let version: String
    public let notes: [String]
    public let archive: URL
    public let signature: String
    public let size: Int

    public init(version: String, notes: [String], archive: URL, signature: String, size: Int) {
        self.version = version; self.notes = notes; self.archive = archive; self.signature = signature; self.size = size
    }
}

public enum UpdateFailure: Error, LocalizedError, Equatable {
    case notConfigured, unavailable, badFeed, badSignature, invalidArchive, notWritable, stale
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates are not set up for this build."
        case .unavailable: return "Could not reach the update server. Try again later."
        case .badFeed: return "The update feed could not be read. Try again later, or download the update from GitHub."
        case .badSignature: return "The download did not pass the signature check and was thrown away."
        case .invalidArchive: return "The download did not contain a valid Capio update."
        case .notWritable: return "Capio cannot replace itself here. Move it to Applications and try again."
        case .stale: return "The downloaded update is no longer there. Check for updates again."
        }
    }
}

/// Signed updates from the GitHub release. An archive is installed only when it is signed with Capio's release key and
/// the app inside carries the same code signature as the running one, so Screen Recording stays allowed.
///
/// Feed format: `{"version":"0.7.1","notes":["…"],"url":"https://…/Capio-0.7.1.zip","signature":"base64","size":123}`
public struct Updater: Sendable {
    public let feed: URL
    public let publicKey: Curve25519.Signing.PublicKey
    public let currentVersion: String
    /// The running app's designated requirement; the update must satisfy it.
    public let requirement: String
    static let maxFeed = 262_144, maxArchive = 200_000_000
    static let folderPrefix = "capio-update-"
    static let feedKey = "CapioUpdateFeed", publicKeyKey = "CapioUpdatePublicKey"

    public init?(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let key = bundle.object(forInfoDictionaryKey: Self.publicKeyKey) as? String,
              let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let feed = (environment["CAPIO_UPDATE_FEED"] ?? bundle.object(forInfoDictionaryKey: Self.feedKey) as? String).flatMap(URL.init(string:)),
              Self.allowed(feed),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              // A build signed ad hoc is only like itself: no update could ever match it, so it does not look for one.
              let requirement = Self.ownRequirement(), requirement.contains("certificate") else { return nil }
        self.init(feed: feed, publicKey: publicKey, currentVersion: version, requirement: requirement)
    }

    public init(feed: URL, publicKey: Curve25519.Signing.PublicKey, currentVersion: String, requirement: String) {
        self.feed = feed; self.publicKey = publicKey; self.currentVersion = currentVersion; self.requirement = requirement
    }

    /// https anywhere; plain http only inside the home network or on this Mac, where the signature still protects the download.
    public static func allowed(_ url: URL) -> Bool {
        if url.scheme == "https" { return url.host != nil }
        guard url.scheme == "http", let host = url.host else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        // Only real private IPv4 addresses, so a name like 10.example.com does not count as the home network.
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        let ip = UInt32(bigEndian: address.s_addr), a = ip >> 24, b = (ip >> 16) & 0xff
        return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b))
    }

    /// Dotted comparison where a release beats its own betas, and the word of a prerelease counts before its number:
    /// 0.7.0 > 0.7.0-rc.1 > 0.7.0-beta.2 > 0.7.0-beta.1 > 0.7.0-alpha.3.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func split(_ value: String) -> ([Int], [Int]?) {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let pieces = trimmed.split(separator: "-", maxSplits: 1)
            let numbers = pieces.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            guard pieces.count > 1 else { return (numbers, nil) }
            let word = pieces[1].split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
            let pre = [["alpha": 0, "beta": 1, "rc": 2][word] ?? 1] + pieces[1].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return (numbers, pre)
        }
        func compare(_ a: [Int], _ b: [Int]) -> Int {
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
                if x != y { return x > y ? 1 : -1 }
            }
            return 0
        }
        let (a, preA) = split(candidate), (b, preB) = split(current)
        let base = compare(a, b)
        if base != 0 { return base > 0 }
        switch (preA, preB) {
        case (nil, nil): return false
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(x), .some(y)): return compare(x, y) > 0
        }
    }

    public static func parse(_ data: Data) -> UpdateInfo? { try? parsed(data) }

    /// The feed's release, or `badFeed`: too large, not JSON, a link that is not allowed, a signature that is not one.
    static func parsed(_ data: Data) throws -> UpdateInfo {
        guard data.count <= maxFeed, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? String, !version.isEmpty, version.count <= 40,
              let link = (root["url"] as? String).flatMap(URL.init(string:)), allowed(link),
              let signature = root["signature"] as? String, signature.count <= 200 else { throw UpdateFailure.badFeed }
        let notes = (root["notes"] as? [String] ?? []).prefix(12).map { String($0.prefix(200)) }
        return UpdateInfo(version: version, notes: Array(notes), archive: link, signature: signature, size: root["size"] as? Int ?? 0)
    }

    public static func verify(_ archive: Data, signature: String, key: Curve25519.Signing.PublicKey) -> Bool {
        guard let raw = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 64 else { return false }
        return key.isValidSignature(raw, for: archive)
    }

    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": "Capio/\(currentVersion)"]
        return config
    }

    /// A newer version, or nil when this build is current. A feed that can not be read is a failure (`badFeed`), never
    /// "you have the newest": the user would read that while the feed is broken.
    public func check() async throws -> UpdateInfo? {
        switch await Self.fetch(feed, limit: Self.maxFeed, configuration: configuration()) {
        case .done(let data):
            let info = try Self.parsed(data)
            return Self.isNewer(info.version, than: currentVersion) ? info : nil
        case .tooLarge: throw UpdateFailure.badFeed
        case .failed: throw UpdateFailure.unavailable
        }
    }

    /// Downloads with progress (straight to a file, never past the size limit), verifies the signature, unpacks and checks the
    /// app. Returns the verified bundle; its temporary folder goes again on every failure, and with the install otherwise.
    public func prepare(_ info: UpdateInfo, bundleIdentifier: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        Self.clearLeftovers()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: folder) } }
        let zip = folder.appendingPathComponent("update.zip")
        switch await Self.fetch(info.archive, limit: Self.maxArchive, to: zip, configuration: configuration(), progress: progress) {
        case .done: break
        case .tooLarge: throw UpdateFailure.invalidArchive
        case .failed: throw UpdateFailure.unavailable
        }
        progress(1)
        // The signature covers the whole archive at once: mapped from the file, not copied into memory.
        guard let archive = try? Data(contentsOf: zip, options: .alwaysMapped), Self.verify(archive, signature: info.signature, key: publicKey) else { throw UpdateFailure.badSignature }
        // ditto and the checks wait on processes for seconds: on a thread of their own, never one of the few in the cooperative pool.
        let (id, current, key, requirement) = (bundleIdentifier, currentVersion, publicKey, requirement)
        let app = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: { try Self.unpack(zip, in: folder, bundleIdentifier: id, version: info.version, newerThan: current, key: key, requirement: requirement) }))
            }
        }
        keep = true
        return app
    }

    /// Folders an update left behind when Capio quit or crashed halfway: gone after a day.
    static func clearLeftovers(now: Date = Date()) {
        let fm = FileManager.default, temp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix(folderPrefix) {
            let url = temp.appendingPathComponent(name)
            if let made = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, now.timeIntervalSince(made) > 86_400 { try? fm.removeItem(at: url) }
        }
    }

    static func unpack(_ zip: URL, in folder: URL, bundleIdentifier: String, version expected: String, newerThan current: String, key: Curve25519.Signing.PublicKey, requirement: String) throws -> URL {
        let unpacked = folder.appendingPathComponent("app")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else { throw UpdateFailure.invalidArchive }
        try? FileManager.default.removeItem(at: zip)
        // One app in the zip, whatever its name.
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: unpacked.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { throw UpdateFailure.invalidArchive }
        let app = unpacked.appendingPathComponent(apps[0])
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = accepts(plist, bundleIdentifier: bundleIdentifier, newerThan: current, key: key),
              version == expected,   // the app is the version the feed announced, not another signed release
              signed(app, satisfying: requirement) else { throw UpdateFailure.invalidArchive }
        // It really starts on this Mac: a broken download never replaces the working copy.
        guard let executable = executableName(of: app),
              output(app.appendingPathComponent("Contents/MacOS/" + executable).path, ["--version"]) == version else { throw UpdateFailure.invalidArchive }
        return app
    }

    /// The new app's version when its Info.plist is Capio's, newer, and still trusts this app's update key. The key is what
    /// guards every later update; its feed may move to another server, so that only has to be a web address.
    public static func accepts(_ plist: NSDictionary, bundleIdentifier: String, newerThan current: String, key: Curve25519.Signing.PublicKey) -> String? {
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = plist["CFBundleShortVersionString"] as? String, isNewer(version, than: current),
              let next = (plist[feedKey] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(next.scheme ?? ""), next.host != nil,
              (plist[publicKeyKey] as? String).flatMap({ Data(base64Encoded: $0) }) == key.rawRepresentation else { return nil }
        return version
    }

    /// The running app's designated requirement as text, or nil for an unsigned binary.
    public static func ownRequirement() -> String? {
        var code: SecCode?, fixed: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &fixed) == errSecSuccess, let fixed else { return nil }
        return requirement(of: fixed)
    }

    /// The designated requirement of the app at `url`.
    public static func requirement(ofApp url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return requirement(of: code)
    }

    private static func requirement(of code: SecStaticCode) -> String? {
        var requirement: SecRequirement?, text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// True when the app at `url` is intact, in every architecture, and signed the way `requirement` asks: for a build signed
    /// with Capio's certificate that is the same identifier and the same certificate.
    public static func signed(_ url: URL, satisfying requirement: String) -> Bool {
        var code: SecStaticCode?, wanted: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &wanted) == errSecSuccess, let wanted else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, wanted) == errSecSuccess
    }

    /// Puts the verified update next to `target` while Capio still runs, then leaves a script behind that swaps the two
    /// with renames once `pid` is gone. With `relaunch` Capio opens again; without it (Install on Quit) it stays closed.
    /// The update's temporary folder goes on every way out.
    public static func scheduleInstall(update: URL, replacing target: URL, pid: Int32, relaunch: Bool) throws {
        let fm = FileManager.default
        defer { if let folder = temporaryFolder(of: update) { try? fm.removeItem(at: folder) } }
        guard fm.fileExists(atPath: update.path) else { throw UpdateFailure.stale }
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: target.path) else { throw UpdateFailure.notWritable }
        let staged = staged(for: target)
        try? fm.removeItem(at: staged)
        guard run("/usr/bin/ditto", [update.path, staged.path]) else {
            try? fm.removeItem(at: staged)
            throw UpdateFailure.notWritable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", installScript(replacing: target, pid: pid, relaunch: relaunch)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Where the complete new app waits, in the same folder as the one it replaces, so the swap is two renames.
    public static func staged(for target: URL) -> URL { URL(fileURLWithPath: target.path + ".capio-new") }

    /// The folder `prepare` made (the unpacked app sits two levels below it); nil for an app anywhere else, which is never removed.
    static func temporaryFolder(of update: URL) -> URL? {
        let folder = update.deletingLastPathComponent().deletingLastPathComponent()
        return folder.lastPathComponent.hasPrefix(folderPrefix) ? folder : nil
    }

    /// The script behind `scheduleInstall`; tests give it another `open`, a shorter wait and their own lock.
    /// At every moment a complete app exists under the target's name or as its `.capio-old`; a run that finds only the old
    /// copy puts it back first.
    public static func installScript(replacing target: URL, pid: Int32, relaunch: Bool, open: String = "/usr/bin/open", settle: Int = 15,
                                     lock: String = FileManager.default.temporaryDirectory.appendingPathComponent("capio-installing").path) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let app = quote(target.path), old = quote(target.path + ".capio-old"), bad = quote(target.path + ".capio-bad")
        let new = quote(staged(for: target).path), lock = quote(lock), open = relaunch ? quote(open) : ":"
        // After the swap the target folder holds the new app, so its executable name counts.
        let binary = quote(running(target.path + "/Contents/MacOS/" + (executableName(of: staged(for: target)) ?? "Capio")))
        // With a relaunch: if the new app is not running after `settle` seconds it did not start properly and the old one
        // comes back. Without one there is nothing to watch, so the old copy goes once the new one is in place.
        let after = relaunch ? """
            if [ $ok = 1 ]; then \(open) \(app) --args --updated; else \(open) \(app); exit 0; fi
            sleep \(settle)
            if [ -d \(old) ]; then
              if /usr/bin/pgrep -qf \(binary); then rm -rf \(old); else mv \(app) \(bad) && mv \(old) \(app); rm -rf \(bad); \(open) \(app); fi
            fi
            """ : "if [ $ok = 1 ]; then rm -rf \(old); fi"
        return """
        n=0; while kill -0 \(pid) 2>/dev/null; do n=$((n+1)); [ $n -gt 600 ] && { rm -rf \(new); exit 0; }; sleep 0.2; done
        if ! mkdir \(lock) 2>/dev/null; then
          if [ -n "$(find \(lock) -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir \(lock); mkdir \(lock) || { \(open) \(app); exit 0; }; else \(open) \(app); exit 0; fi
        fi
        trap \(quote("rmdir " + lock)) EXIT
        if [ ! -d \(app) ] && [ -d \(old) ]; then mv \(old) \(app); fi
        ok=0
        if [ -d \(new) ] && [ -d \(app) ]; then
          rm -rf \(old)
          if mv \(app) \(old); then
            if mv \(new) \(app); then ok=1; else mv \(old) \(app); fi
          fi
        fi
        rm -rf \(new)
        \(after)
        """
    }

    /// The binary's path as a pgrep pattern (an extended regex) that matches it literally: an app at "Capio (1).app", as a
    /// browser names a second download, is found too instead of rolled back while it runs.
    static func running(_ binary: String) -> String {
        binary.map { "\\.[]()*+?{}|^$".contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    static func executableName(of app: URL) -> String? {
        guard let name = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleExecutable"] as? String,
              !name.isEmpty, !name.contains("/"), name != ".." else { return nil }
        return name
    }

    /// The trimmed output of a tool that exits cleanly within a few seconds, or nil.
    static func output(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

extension Updater {
    enum Fetched: Equatable { case done(Data), tooLarge, failed }

    /// One GET, kept in memory or written to `file` as it arrives (then `done` carries no data), and stopped as soon as it grows
    /// past `limit`: a server that sends more than it should never fills the memory or the disk. Progress from the length the
    /// server announced, once per whole percent. A cancelled task stops the download.
    static func fetch(_ url: URL, limit: Int, to file: URL? = nil, configuration: URLSessionConfiguration,
                      progress: (@Sendable (Double) -> Void)? = nil) async -> Fetched {
        var output: FileHandle?
        if let file {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: file) else { return .failed }
            output = handle
        }
        defer { try? output?.close() }
        let download = CappedDownload(limit: limit, file: output, progress: progress)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                download.start(url, configuration: configuration) { continuation.resume(returning: $0) }
            }
        } onCancel: { download.cancel() }
    }
}

/// The delegate behind `Updater.fetch`: counts every byte as it comes and stops the download past the limit. URLSession calls it
/// on one serial queue of its own, so its counters need no lock; only starting and cancelling come from elsewhere.
final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int, file: FileHandle?, progress: (@Sendable (Double) -> Void)?
    private var done: ((Updater.Fetched) -> Void)?
    private var data = Data(), received = 0, expected: Int64 = 0, finished = false, percent = -1
    private let lock = NSLock()
    private var task: URLSessionDataTask?, cancelled = false

    init(limit: Int, file: FileHandle?, progress: (@Sendable (Double) -> Void)?) {
        self.limit = limit; self.file = file; self.progress = progress
    }

    func start(_ url: URL, configuration: URLSessionConfiguration, done: @escaping (Updater.Fetched) -> Void) {
        self.done = done
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: url)
        lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
        task.resume()
        if stop { task.cancel() }   // cancelled before it began
        session.finishTasksAndInvalidate()
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    /// A redirect (GitHub sends a release file on to its storage) may only lead to an address that is allowed itself.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Updater.allowed) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { finish(.failed); completionHandler(.cancel); return }
        if response.expectedContentLength > Int64(limit) { finish(.tooLarge); completionHandler(.cancel); return }
        expected = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished else { return }
        received += chunk.count
        guard received <= limit else { finish(.tooLarge); dataTask.cancel(); return }
        if let file {
            guard (try? file.write(contentsOf: chunk)) != nil else { finish(.failed); dataTask.cancel(); return }
        } else { data.append(chunk) }
        guard expected > 0 else { return }
        let fraction = min(0.99, Double(received) / Double(expected))
        if Int(fraction * 100) != percent { percent = Int(fraction * 100); progress?(fraction) }   // not thousands of refreshes a second
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil ? .done(data) : .failed)
    }

    private func finish(_ outcome: Updater.Fetched) {
        guard !finished else { return }
        finished = true
        done?(outcome)
    }
}
