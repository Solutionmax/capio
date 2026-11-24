import AppKit
import CapioCore
import SwiftUI

/// Looks for a new Capio when the app starts and once a day, and walks the user through installing it.
@MainActor
final class UpdateController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case checking
        case available(UpdateInfo)
        case downloading(UpdateInfo, Double)
        case ready(UpdateInfo)
        case upToDate
        case failed(String, String)
    }

    @Published private(set) var phase: Phase = .checking
    /// The line under the version in Settings.
    @Published private(set) var status = ""
    /// True while the user selects an area or records; nothing pops up or restarts then.
    var isBusy: () -> Bool = { false }

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    private let updater = Updater()
    private var window: NSWindow?
    private var work: Task<Void, Never>?
    private var found: UpdateInfo?
    private var prepared: (info: UpdateInfo, app: URL)?
    private var installOnQuit = false
    private var started = Date()
    private var nextTry = Date.distantPast

    private static let day: TimeInterval = 86_400, retry: TimeInterval = 3_600, tick: UInt64 = 300

    override init() {
        super.init()
        refreshStatus()
    }

    /// Called once at launch: says so after an update, then checks now and every day.
    func start() {
        if CommandLine.arguments.contains("--updated") {
            Toast.shared.showUpdated(version: current)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            var first = true
            while let self, !Task.isCancelled {
                let due = first || Date().timeIntervalSince(Prefs.lastUpdateCheck ?? .distantPast) >= Self.day
                // Nothing new is looked for while a download runs or a checked update waits to be installed.
                if due, Prefs.autoCheck, Date() >= self.nextTry, self.work == nil, self.prepared == nil, self.window?.isVisible != true, !self.isBusy() {
                    first = false
                    await self.check(manual: false)
                }
                try? await Task.sleep(nanoseconds: Self.tick * 1_000_000_000)
            }
        }
    }

    /// From the menu and Check Now: always answers, also with "up to date" or what went wrong.
    func checkNow() {
        if let prepared { show(.ready(prepared.info)); return }
        // A download is under way, also one that started by itself: show that one.
        if work != nil, case .downloading = phase { show(phase); return }
        show(.checking)
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        guard let updater else {
            if manual { show(.failed("Could not check for updates", UpdateFailure.notConfigured.localizedDescription)) }
            return
        }
        do {
            let info = try await updater.check()
            Prefs.lastUpdateCheck = Date()
            found = info
            refreshStatus()
            guard let info else {
                if manual { show(.upToDate) }
                return
            }
            if manual { show(.available(info)); return }
            guard Prefs.skippedVersion != info.version else { return }
            if Prefs.autoInstall { download(info, silent: true) } else { show(.available(info)) }
        } catch {
            nextTry = Date().addingTimeInterval(Self.retry)
            log.error("update check failed: \(error.localizedDescription)")
            if manual { show(.failed("Could not check for updates", error.localizedDescription)) }
        }
    }

    // MARK: buttons

    func install() {
        guard case .available(let info) = phase else { return }
        download(info, silent: false)
    }

    func skip() {
        if case .available(let info) = phase { Prefs.skippedVersion = info.version }
        close()
    }

    func close() {
        window?.close()
    }

    func cancelDownload() {
        work?.cancel()
        work = nil
        window?.close()
    }

    func relaunch() {
        guard let prepared else { return }
        self.prepared = nil
        do {
            try Updater.scheduleInstall(update: prepared.app, replacing: Bundle.main.bundleURL, pid: ProcessInfo.processInfo.processIdentifier, relaunch: true)
            NSApp.terminate(nil)
        } catch {
            show(.failed("The update could not be installed", error.localizedDescription))
        }
    }

    func installWhenQuitting() {
        installOnQuit = true
        close()
    }

    /// Install on Quit: the swap happens once Capio is gone, and Capio stays closed.
    func willTerminate() {
        guard installOnQuit, let prepared else { return }
        self.prepared = nil
        try? Updater.scheduleInstall(update: prepared.app, replacing: Bundle.main.bundleURL, pid: ProcessInfo.processInfo.processIdentifier, relaunch: false)
    }

    // MARK: download

    private func download(_ info: UpdateInfo, silent: Bool) {
        guard let updater, work == nil, prepared == nil else { return }
        started = Date()
        if silent { phase = .downloading(info, 0) } else { show(.downloading(info, 0)) }
        work = Task { [weak self] in
            do {
                let app = try await updater.prepare(info, bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.solutionmax.capio") { fraction in
                    Task { @MainActor in
                        guard let self, case .downloading(let now, _) = self.phase, now == info else { return }
                        self.phase = .downloading(info, fraction)
                    }
                }
                // Cancelled at the last moment: the download goes, and whoever cancelled already let go of `work`.
                guard let self, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent())
                    return
                }
                self.work = nil
                self.prepared = (info, app)
                self.refreshStatus()
                // By itself only when nobody is looking at the window; otherwise the user picks the moment.
                guard silent, self.window?.isVisible != true else { self.show(.ready(info)); return }
                // Never restart under a selection or a recording.
                while self.isBusy() { try? await Task.sleep(nanoseconds: 5 * 1_000_000_000) }
                // The user may have opened the window meanwhile and chosen Install on Quit.
                guard !self.installOnQuit, self.window?.isVisible != true, self.prepared?.info == info else { return }
                self.relaunch()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.work = nil
                log.error("update failed: \(error.localizedDescription)")
                if !silent || self.window?.isVisible == true { self.show(.failed("The update could not be installed", error.localizedDescription)) }
            }
        }
    }

    /// "about 4 seconds" from how fast the download went so far; empty until there is something to go on.
    func timeLeft(at fraction: Double) -> String {
        let elapsed = Date().timeIntervalSince(started)
        guard fraction > 0.05, elapsed > 0.5 else { return "" }
        let left = Int((elapsed * (1 - fraction) / fraction).rounded(.up))
        return left >= 90 ? "about \(left / 60) minutes" : "about \(max(left, 1)) second\(left > 1 ? "s" : "")"
    }

    // MARK: window

    private func show(_ next: Phase) {
        phase = next
        refreshStatus()
        let w = window ?? makeWindow()
        window = w
        NSApp.activate()
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: UpdateView(model: self))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.title = "Software Update"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        return w
    }

    /// The red button during a download is Cancel; everywhere else it is Remind Me Later.
    func windowWillClose(_ notification: Notification) {
        if case .downloading = phase { work?.cancel(); work = nil }
        refreshStatus()
    }

    private func refreshStatus() {
        if let prepared { status = "Capio \(prepared.info.version) is ready to install"; return }
        if let found { status = "Capio \(found.version) is available"; return }
        guard updater != nil else { status = "Updates are not set up for this build"; return }
        guard let checked = Prefs.lastUpdateCheck else { status = "Not checked yet"; return }
        let time = checked.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(checked) ? "today" : Calendar.current.isDateInYesterday(checked) ? "yesterday" : checked.formatted(date: .abbreviated, time: .omitted)
        status = "Up to date · checked \(day) at \(time)"
    }

    /// Snapshot mode: set what the window shows without a check.
    func demo(_ next: Phase) { phase = next }
}

struct UpdateView: View {
    @ObservedObject var model: UpdateController
    @AppStorage(Prefs.Key.autoInstall) private var autoInstall = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: Theme.appIcon).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .tint(Theme.accentColor)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .checking:
            title("Checking for updates…")
            ProgressView().progressViewStyle(.linear)
        case .available(let info):
            title("A new version of Capio is available")
            text("Capio \(info.version) is out. You have \(model.current). It takes a few seconds and Capio opens again where you were.")
            Text("\(Self.megabytes(info.size)) · signed by SolutionMAX").font(.system(size: 11.5)).foregroundStyle(.secondary)
            if !info.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's new in \(info.version)").font(.system(size: 12, weight: .semibold))
                    ForEach(info.notes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(Theme.accentColor).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            Text(note).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Toggle("Install updates automatically from now on", isOn: $autoInstall).toggleStyle(.checkbox).font(.system(size: 12))
            HStack {
                Button("Skip This Version") { model.skip() }
                Spacer()
                Button("Remind Me Later") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Install Update") { model.install() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        case .downloading(let info, let fraction):
            title("Downloading Capio \(info.version)")
            ProgressView(value: fraction).progressViewStyle(.linear)
            HStack {
                Text(info.size > 0 ? "\(Self.megabytes(Int(Double(info.size) * fraction))) of \(Self.megabytes(info.size))" : "\(Int(fraction * 100)) %")
                Spacer()
                Text(model.timeLeft(at: fraction))
            }
            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelDownload() }.keyboardShortcut(.cancelAction)
            }
        case .ready(let info):
            title("Capio \(info.version) is ready to install")
            VStack(alignment: .leading, spacing: 4) {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                Label("Signature checked", systemImage: "checkmark.circle.fill")
            }
            .font(.system(size: 12)).symbolRenderingMode(.palette).foregroundStyle(Color.white, Color.green)
            .labelStyle(TintedLabel())
            text("Capio closes, puts the new version in place and opens again.")
            HStack {
                Spacer()
                Button("Install on Quit") { model.installWhenQuitting() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { model.relaunch() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        case .upToDate:
            title("Capio is up to date")
            text("\(model.current) is the newest version.")
            ok
        case .failed(let what, let why):
            title(what)
            text(why)
            ok
        }
    }

    private var ok: some View {
        HStack {
            Spacer()
            Button("OK") { model.close() }.keyboardShortcut(.defaultAction)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }

    private func text(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

/// A label whose text keeps the normal colour while the icon takes the palette.
private struct TintedLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title.foregroundStyle(Color.primary)
        }
    }
}
