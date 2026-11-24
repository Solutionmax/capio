import AppKit
import AVFoundation
import CapioCore
import ImageIO
import SwiftUI

/// What a tile can do; the app delegate fills these in.
struct HistoryActions {
    var open: (CaptureRecord) -> Void
    var reveal: (CaptureRecord) -> Void
    var copyFile: (CaptureRecord) -> Void
    var copyLink: (CaptureRecord) -> Void
    var openLink: (CaptureRecord) -> Void
    var upload: (CaptureRecord) -> Void
    var pin: (CaptureRecord) -> Void
    var copyText: (CaptureRecord) -> Void
    var delete: (CaptureRecord) -> Void
    var deleteUpload: (CaptureRecord) -> Void
    var openFolder: () -> Void
    var settings: () -> Void
}

struct HistoryView: View {
    enum Filter: Hashable { case all, kind(CaptureKind) }
    enum Sort: String, CaseIterable { case date = "Date", size = "Size" }

    @ObservedObject var library: Library
    let actions: HistoryActions
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .date

    /// Only captures still in the folder. Hidden, not forgotten: a file put back (Trash, other folder, drive) shows again,
    /// and a link on a hidden capture still comes down after its week.
    // Limit: one stat per capture per render, fine for thousands; a folder watcher if the popover ever stays open.
    private var onDisk: [CaptureRecord] { library.records.filter(library.exists) }

    private var items: [CaptureRecord] {
        let kind: CaptureKind? = { if case .kind(let k) = filter { return k }; return nil }()
        let found = HistoryStore.filter(onDisk, kind: kind, query: query)
        return sort == .size ? found.sorted { $0.bytes > $1.bytes } : found
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search text in captures", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                Menu {
                    Picker("Sort by", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26, height: 30).help("Sort")
                Button { actions.settings() } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.borderless).frame(width: 26, height: 30).help("Settings")
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 10))

            Picker("", selection: $filter) {
                Text("All").tag(Filter.all)
                Text("Screenshots").tag(Filter.kind(.screenshot))
                Text("Screencasts").tag(Filter.kind(.screencast))
                Text("GIFs").tag(Filter.kind(.gif))
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 10)

            if items.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 10) {
                        ForEach(items) { r in
                            Tile(record: r, url: library.url(for: r))
                                .onTapGesture(count: 2) { actions.open(r) }
                                .contextMenu { menu(for: r) }
                        }
                    }
                    .padding(EdgeInsets(top: 2, leading: 12, bottom: 12, trailing: 12))
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button { actions.openFolder() } label: { Label("Open Capio Folder", systemImage: "folder") }
                    .buttonStyle(.plain).lineLimit(1).help(Prefs.folderDisplay)
                Spacer()
                Text(summary)
            }
            .font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).frame(height: 36)
        }
        .frame(width: 388, height: 540)
    }

    private var summary: String {
        let shown = onDisk
        let online = shown.filter { $0.link != nil }.count
        return "\(shown.count) captures · \(online) online"
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: Theme.appIcon).resizable().frame(width: 44, height: 44).opacity(0.9)
            Text(query.isEmpty ? "No captures yet" : "Nothing matches “\(query)”").font(.system(size: 14, weight: .semibold))
            Text(query.isEmpty ? "Press ⌃⌘2 and drag over what you want to capture." : "Search looks in names, links and the text in your screenshots.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Plain text entries. Only Create External Link sends a capture to Amfora.
    @ViewBuilder private func menu(for r: CaptureRecord) -> some View {
        Button("Open File") { actions.open(r) }
        Button("Show in Finder") { actions.reveal(r) }
        Button("Copy File") { actions.copyFile(r) }
        Divider()
        if r.link != nil {
            Button("Copy Link") { actions.copyLink(r) }
            Button("Open Link") { actions.openLink(r) }
            Button("Delete External Link") { actions.deleteUpload(r) }
        } else {
            Button("Create External Link") { actions.upload(r) }
        }
        if r.kind == .screenshot {
            Divider()
            Button("Pin to Screen") { actions.pin(r) }
            Button("Copy Text") { actions.copyText(r) }.disabled((r.ocrText ?? "").isEmpty)
        }
        Divider()
        Button("Delete", role: .destructive) { actions.delete(r) }
    }
}

struct Tile: View {
    let record: CaptureRecord
    let url: URL
    @State private var image: NSImage?
    @State private var hover = false
    @State private var when = ""

    /// Recordings say what they are; a screenshot needs no badge.
    private var badge: String? {
        switch record.kind {
        case .screenshot: return nil
        case .gif: return "GIF"
        case .screencast: return record.duration.map(CaptureNaming.duration) ?? "MP4"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Color.primary.opacity(0.05)
                .frame(maxWidth: .infinity).frame(height: 104)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                }
                .overlay {
                    if record.kind == .screencast {
                        Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(Color(white: 0.11))
                            .frame(width: 34, height: 34).background(Color.white.opacity(0.92), in: Circle())
                    }
                }
                .clipped()
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) {
                    if let badge {
                        Text(badge).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(height: 16).background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                    }
                }
                .overlay(shape.stroke(hover ? Theme.accentColor : Color.black.opacity(0.2), lineWidth: hover ? 2.5 : 0.5))

            HStack(spacing: 4) {
                Text(when).lineLimit(1)
                Spacer(minLength: 0)
                if record.link != nil {
                    Image(systemName: "link").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.accentColor).help("Uploaded")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 2).frame(height: 24)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help("\(record.fileName) · \(CaptureNaming.size(record.bytes))")
        .task(id: url) {
            when = CaptureNaming.when(record.createdAt)
            image = await Thumbnails.load(url, kind: record.kind)
        }
    }
}

enum Thumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func load(_ url: URL, kind: CaptureKind) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let image: NSImage? = await Task.detached(priority: .utility) {
            if kind == .screencast {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 480, height: 480)
                guard let cg = try? await gen.image(at: .zero).image else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
