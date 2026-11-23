import AppKit
import CapioCore
import ImageIO
import UniformTypeIdentifiers
import Vision

enum Exporter {
    /// Crops the frozen picture to the selection and burns the drawings in, at full pixel size.
    static func render(_ image: CGImage, selection s: CGRect, scale: CGFloat, annotations: [Annotation]) -> CGImage? {
        let px = SelectionMath.pixelRect(s, scale: scale)
        guard px.width >= 1, px.height >= 1, let base = image.cropping(to: px) else { return nil }
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: base.width, height: base.height)
        ctx.draw(base, in: CGRect(origin: .zero, size: size))
        guard !annotations.isEmpty else { return ctx.makeImage() }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: size.width / s.width, y: size.height / s.height)
        ctx.translateBy(x: -s.minX, y: -s.minY)
        ctx.clip(to: s)
        AnnotationRenderer.draw(annotations, in: ctx)
        return ctx.makeImage()
    }

    /// PNG with the Retina density set, so previews show it at its real size.
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// PNG or JPEG, as chosen in Settings.
    static func data(_ image: CGImage, scale: CGFloat, format: ImageFormat) -> Data? {
        guard let quality = format.jpegQuality else { return png(image, scale: scale) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                                 kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// One pixel a point: a Retina capture scaled down by its display scale. Other captures stay as they are.
    static func sized(_ image: CGImage, scale: CGFloat, size: ImageSize) -> (image: CGImage, scale: CGFloat) {
        guard size == .normal, scale > 1 else { return (image, scale) }
        let small = GIFMaker.scaleDown(image, maxWidth: Int((CGFloat(image.width) / scale).rounded()))
        // Scaling can fail; the full picture then keeps its own scale.
        return small.width < image.width ? (small, 1) : (image, scale)
    }

    /// The scale a saved picture was written with (its density over 72), so a Normal one is not shown at half size.
    static func scale(of source: CGImageSource) -> CGFloat? {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi >= 72 else { return nil }
        return CGFloat(dpi / 72)
    }

    static func nsImage(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
}

enum OCR {
    static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch {
            log.error("text recognition failed: \(error.localizedDescription)")
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// Captures on disk, the history index, and the trip to Amfora.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var records: [CaptureRecord]
    private let store: HistoryStore

    init() {
        store = HistoryStore(indexURL: Prefs.historyURL)
        records = store.records
        if let aside = store.setAside { log.error("history was unreadable, moved to \(aside.path)") }
        stampLegacyLinks()
    }

    /// Links made before 0.5 get their week from now, instead of all being taken down at the first start.
    private func stampLegacyLinks() {
        let now = Date()
        let old = store.records.filter { $0.link != nil && $0.uploadedAt == nil }
        guard !old.isEmpty else { return }
        commit { for r in old { try store.replace(r.stampingLegacyLink(now)) } }
    }

    func url(for r: CaptureRecord) -> URL { Prefs.folder.appendingPathComponent(r.fileName) }
    func exists(_ r: CaptureRecord) -> Bool { FileManager.default.fileExists(atPath: url(for: r).path) }

    func saveScreenshot(_ image: CGImage, scale: CGFloat) {
        let folder = Prefs.folder
        let format = Prefs.imageFormat
        let size = Prefs.imageSize
        let now = Date()
        Task {
            // Encoding a 5K picture takes a moment: off the main thread, so the screen does not stall.
            let result: Result<(Data, String, CGImage, CGFloat), Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let out = Exporter.sized(image, scale: scale, size: size)
                    guard let data = Exporter.data(out.image, scale: out.scale, format: format) else {
                        throw ScreenRecorder.Failure(errorDescription: "The picture could not be made.")
                    }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = CaptureNaming.fileName(kind: .screenshot, ext: format.fileExtension, date: now) {
                        FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                    }
                    try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    return (data, name, out.image, out.scale)
                }
            }.value
            switch result {
            case .success(let (data, name, out, outScale)):
                saved(data: data, format: format, name: name, image: out, scale: outScale, full: image, date: now)
            case .failure(let error):
                Toast.shared.showError("Could not save the screenshot", detail: "\(error.localizedDescription) Check the folder in Settings.")
            }
        }
    }

    /// `full` is the capture before any scaling down: text is read from that, more pixels read better.
    private func saved(data: Data, format: ImageFormat, name: String, image: CGImage, scale: CGFloat, full: CGImage, date now: Date) {
        let record = CaptureRecord(fileName: name, kind: .screenshot, createdAt: now, bytes: Int64(data.count),
                                   pixelWidth: image.width, pixelHeight: image.height)
        commit { try store.add(record) }
        let picture = Exporter.nsImage(image, scale: scale)
        Clipboard.copyImage(data: data, format: format, image: picture)
        if Prefs.screenshotSound { Sounds.shutter() }
        afterSave(record, thumbnail: picture)
        recognizeText(record, image: full)
    }

    /// A finished screencast or GIF: into the folder, file on the clipboard (pastes as an attachment), then the link.
    func saveRecording(from temp: URL, kind: CaptureKind, duration: Double, pixelSize: (Int, Int)) {
        let folder = Prefs.folder
        let now = Date()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = CaptureNaming.fileName(kind: kind, date: now) {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            let dest = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temp, to: dest)
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let record = CaptureRecord(fileName: name, kind: kind, createdAt: now, bytes: bytes,
                                       pixelWidth: pixelSize.0, pixelHeight: pixelSize.1, duration: duration)
            commit { try store.add(record) }
            Clipboard.copyFile(dest)
            Task {
                let thumb = await Thumbnails.load(dest, kind: kind)
                afterSave(record, thumbnail: thumb)
            }
        } catch {
            Toast.shared.showError("Could not save the recording", detail: "\(error.localizedDescription) It is still at \(temp.path).")
        }
    }

    /// A new capture stays on this Mac, unless "Always create an external link" is on.
    private func afterSave(_ record: CaptureRecord, thumbnail: NSImage?) {
        if Prefs.uploadEnabled { upload(record, thumbnail: thumbnail); return }
        Toast.shared.showSaved(title: "\(Self.title(record.kind)) saved", detail: "On this Mac, copied to the clipboard.",
                               thumbnail: thumbnail, record: record)
    }

    static func title(_ kind: CaptureKind) -> String {
        switch kind {
        case .screenshot: return "Screenshot"
        case .screencast: return "Screencast"
        case .gif: return "GIF"
        }
    }

    /// Captures whose link is being made right now: no second upload, no delete until it is done.
    private var uploading: Set<UUID> = []

    /// Makes the external link: upload to Amfora, link on the clipboard. The share ends after a week.
    func upload(_ record: CaptureRecord, thumbnail: NSImage?) {
        guard !uploading.contains(record.id) else { return }
        guard let cfg = Prefs.amfora else {
            Toast.shared.showSaved(title: "\(Self.title(record.kind)) saved",
                                   detail: "On this Mac, copied to the clipboard. Add your Amfora key in Settings to get a link.",
                                   thumbnail: thumbnail, record: record)
            return
        }
        uploading.insert(record.id)
        Toast.shared.showUploading(kind: record.kind, thumbnail: thumbnail, record: record)
        let file = url(for: record)
        Task {
            defer { uploading.remove(record.id) }
            let client = AmforaClient(cfg: cfg)
            do {
                let id = record.id
                let up = try await client.upload(file: file, kind: record.kind, viewerLinks: Prefs.viewerLinks) { p in
                    Task { @MainActor in Toast.shared.progress(p, record: id) }
                }
                guard let latest = store.record(id: record.id) else {
                    // Gone from the history while uploading: take the new link down again.
                    try? await client.deleteUpload(fileId: up.fileId, shareId: up.shareId)
                    return
                }
                commit { try store.replace(latest.uploaded(link: up.link, fileId: up.fileId, shareId: up.shareId)) }
                // A newer capture owns the clipboard now; the link stays in the history.
                guard Toast.shared.isShowing(record.id) else { return }
                Clipboard.copyText(up.link)
                Toast.shared.showLink(up.link, record: record)
            } catch {
                log.error("upload failed: \(error.localizedDescription)")
                Toast.shared.showError("Upload failed", detail: "\(error.localizedDescription) The file is saved and on your clipboard.")
            }
        }
    }

    /// The Amfora that holds this link, or nil with the reason shown.
    private func server(for record: CaptureRecord) -> AmforaConfig? {
        guard let cfg = Prefs.amfora else {
            Toast.shared.showError("No Amfora key", detail: "Add your key in Settings first; the link would stay online.")
            return nil
        }
        guard record.linkIsOn(cfg.base) else {
            Toast.shared.showError("Link on another server", detail: "This link was made on another Amfora address than the one in Settings.")
            return nil
        }
        return cfg
    }

    func deleteUpload(_ record: CaptureRecord) {
        guard let current = store.record(id: record.id), current.link != nil, let cfg = server(for: current) else { return }
        Task {
            do {
                try await AmforaClient(cfg: cfg).deleteUpload(fileId: current.amforaFileId, shareId: current.amforaShareId)
                if let latest = store.record(id: current.id), latest.amforaShareId == current.amforaShareId {
                    commit { try store.replace(latest.withoutUpload()) }
                }
                Toast.shared.showInfo("Link deleted", detail: "The link no longer works. The capture is still on this Mac.")
            } catch {
                Toast.shared.showError("Could not delete the link", detail: error.localizedDescription)
            }
        }
    }

    /// The file to the Trash and out of the history. A link goes first, so nothing is left behind in Amfora.
    func delete(_ record: CaptureRecord) {
        guard !uploading.contains(record.id) else {
            Toast.shared.showInfo("Still making the link", detail: "Delete it again once the link is ready.")
            return
        }
        // The caller may hold an old copy (the toast does): only the history knows whether there is a link now.
        guard let current = store.record(id: record.id) else { return }
        guard current.link != nil else { deleteLocally(current); return }
        guard let cfg = server(for: current) else { return }
        Task {
            do {
                try await AmforaClient(cfg: cfg).deleteUpload(fileId: current.amforaFileId, shareId: current.amforaShareId)
                guard let latest = store.record(id: current.id) else { return }
                // The link is dead now, even if the Trash refuses the file.
                commit { try store.replace(latest.withoutUpload()) }
                deleteLocally(latest)
            } catch {
                Toast.shared.showError("Could not delete the link", detail: "\(error.localizedDescription) The capture is still here.")
            }
        }
    }

    private var expiring = false

    /// Links live a week: then the share and the file leave Amfora; the capture stays on this Mac.
    /// Quiet; what fails is tried again on the next round. Links on another server are left alone.
    func removeExpiredLinks(now: Date = Date()) {
        let due = HistoryStore.expiredLinks(store.records, now: now).filter { !uploading.contains($0.id) }
        guard !expiring, !due.isEmpty, let cfg = Prefs.amfora else { return }
        expiring = true
        Task {
            defer { expiring = false }
            let client = AmforaClient(cfg: cfg)
            for r in due where r.linkIsOn(cfg.base) {
                do {
                    try await client.deleteUpload(fileId: r.amforaFileId, shareId: r.amforaShareId)
                    // A link made again in the meantime is a new one; leave it.
                    guard let latest = store.record(id: r.id), latest.amforaShareId == r.amforaShareId else { continue }
                    commit { try store.replace(latest.withoutUpload()) }
                } catch {
                    log.error("expired link not removed yet: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Moves the file to the Trash and forgets it.
    private func deleteLocally(_ record: CaptureRecord) {
        do {
            if exists(record) { try FileManager.default.trashItem(at: url(for: record), resultingItemURL: nil) }
            commit { try store.remove(id: record.id) }
        } catch {
            Toast.shared.showError("Could not move it to the Trash", detail: error.localizedDescription)
        }
    }

    private func recognizeText(_ record: CaptureRecord, image: CGImage) {
        Task.detached(priority: .utility) {
            let text = OCR.text(in: image)
            guard !text.isEmpty else { return }
            await MainActor.run {
                guard let latest = self.store.record(id: record.id) else { return }
                self.commit { try self.store.replace(latest.with(ocrText: text)) }
            }
        }
    }

    private func commit(_ change: () throws -> Void) {
        do { try change() } catch {
            log.error("history write failed: \(error.localizedDescription)")
            Toast.shared.showError("Could not update the history", detail: error.localizedDescription)
        }
        records = store.records
    }
}
