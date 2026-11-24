import AppKit
import CapioCore
import SwiftUI

/// Capio's own notification, top right: upload progress, then the link with actions. No system permission needed.
@MainActor
final class Toast: ObservableObject {
    static let shared = Toast()

    enum Phase: Equatable {
        case uploading(CaptureKind, Double)
        case link(String)
        case saved(String, String)
        case info(String, String)
        case updated(String)
        case error(String, String)
    }

    @Published private(set) var phase: Phase = .info("", "")
    @Published private(set) var thumbnail: NSImage?
    private(set) var record: CaptureRecord?
    var onDeleteUpload: ((CaptureRecord) -> Void)?
    var onDelete: ((CaptureRecord) -> Void)?
    var onShowInFinder: ((CaptureRecord) -> Void)?
    var hovering = false { didSet { if !hovering, isFinal { scheduleHide(after: 3) } } }
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private var isFinal: Bool {
        if case .uploading = phase { return false }
        return true
    }

    func showUploading(kind: CaptureKind, thumbnail: NSImage?, record: CaptureRecord) {
        self.thumbnail = thumbnail
        self.record = record
        present(.uploading(kind, 0.02), hideAfter: nil)
    }

    func progress(_ p: Double, record id: UUID) {
        guard record?.id == id, case .uploading(let kind, _) = phase else { return }
        phase = .uploading(kind, min(max(p, 0.02), 1))
    }

    func showLink(_ link: String, record: CaptureRecord) {
        guard self.record?.id == record.id else { return }
        present(.link(link), hideAfter: 8)
    }

    func showSaved(title: String, detail: String, thumbnail: NSImage?, record: CaptureRecord) {
        self.thumbnail = thumbnail
        self.record = record
        present(.saved(title, detail), hideAfter: 6)
    }

    func showInfo(_ title: String, detail: String) {
        thumbnail = nil
        record = nil
        present(.info(title, detail), hideAfter: 5)
    }

    /// After an update put Capio back: the new version, and a way to the release notes.
    func showUpdated(version: String) {
        thumbnail = nil
        record = nil
        present(.updated(version), hideAfter: 10)
    }

    func showWorking(_ title: String) {
        thumbnail = nil
        record = nil
        present(.info(title, "This takes a moment for long recordings."), hideAfter: nil)
    }

    func showError(_ title: String, detail: String) {
        thumbnail = nil
        present(.error(title, detail), hideAfter: 10)
    }

    /// Snapshot mode: set what the toast shows without putting it on screen.
    func demo(_ next: Phase, thumbnail: NSImage?, record: CaptureRecord? = nil) {
        phase = next
        self.thumbnail = thumbnail
        self.record = record
    }

    /// Whether the toast still belongs to this capture (a newer capture takes it over).
    func isShowing(_ id: UUID) -> Bool { record?.id == id }

    func hide() {
        hideTask?.cancel()
        hovering = false
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
    }

    private func present(_ next: Phase, hideAfter: Double?) {
        phase = next
        hovering = false
        let p = panel ?? makePanel()
        panel = p
        guard let host = p.contentView else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let frame = ToastPlacement.frame(size: host.fittingSize, screen: screen.frame, visible: screen.visibleFrame,
                                         safeTop: screen.safeAreaInsets.top, menuBar: NSApp.mainMenu?.menuBarHeight ?? 0)
        if !p.isVisible || p.alphaValue < 1 {
            p.setFrame(frame.offsetBy(dx: 30, dy: 0), display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                p.animator().setFrame(frame, display: true)
                p.animator().alphaValue = 1
            }
        } else {
            p.setFrame(frame, display: true)
        }
        if let hideAfter { scheduleHide(after: hideAfter) } else { hideTask?.cancel() }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: ToastView(model: self))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }
}

struct ToastView: View {
    @ObservedObject var model: Toast

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: Theme.appIcon).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) { message }
                Spacer(minLength: 0)
                if let thumb = model.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 68, height: 44).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.black.opacity(0.25), lineWidth: 0.5))
                }
            }
            if case .link(let link) = model.phase {
                Text(link).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                actions(link)
            } else if case .saved = model.phase, model.record != nil {
                savedActions
            } else if case .updated(let version) = model.phase {
                ToastButton(title: "What's New") {
                    model.hide()
                    if let url = URL(string: "https://github.com/Solutionmax/capio/releases/tag/v\(version)") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(12)
        .frame(width: 372, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.black.opacity(0.2), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            // Always in the tree, so the keyboard and VoiceOver can reach it; only shown under the pointer.
            Button { model.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain).help("Close").accessibilityLabel("Close").offset(x: -6, y: -6).opacity(hover ? 1 : 0)
        }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .padding(EdgeInsets(top: ToastPlacement.cardInset, leading: 24, bottom: 30, trailing: 12))
        .onHover { hover = $0; model.hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: model.phase)
    }

    @ViewBuilder private var message: some View {
        switch model.phase {
        case .uploading(let kind, let p):
            Text("Uploading your \(kind == .screenshot ? "screenshot" : kind == .gif ? "GIF" : "screencast")…")
                .font(.system(size: 14, weight: .semibold))
            ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accentColor).frame(width: 190)
        case .link:
            Text("Link copied, ready to paste").font(.system(size: 14, weight: .semibold))
            Text("Paste it anywhere with ⌘V").font(.system(size: 12)).foregroundStyle(.secondary)
        case .saved(let title, let detail), .info(let title, let detail):
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .updated(let version):
            Text("Capio is updated to \(version)").font(.system(size: 14, weight: .semibold))
            Text("Your captures and settings are where you left them.").font(.system(size: 12)).foregroundStyle(.secondary)
        case .error(let title, let detail):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.palette).foregroundStyle(Color.white, Color.orange)
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actions(_ link: String) -> some View {
        HStack(spacing: 6) {
            ToastButton(title: "Open Link") {
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            }
            ToastButton(title: "Copy Again") { Clipboard.copyText(link) }
            ToastButton(title: "Delete Link", destructive: true) {
                if let r = model.record { model.onDeleteUpload?(r) }
            }
        }
    }

    /// A capture that stayed on this Mac. A link is made from the overview (right click, Create External Link).
    private var savedActions: some View {
        HStack(spacing: 6) {
            ToastButton(title: "Show in Finder") {
                if let r = model.record { model.onShowInFinder?(r) }
            }
            ToastButton(title: "Delete", destructive: true) {
                guard let r = model.record else { return }
                model.hide()
                model.onDelete?(r)
            }
        }
    }
}

struct ToastButton: View {
    let title: String
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.13 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
