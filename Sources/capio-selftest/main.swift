import CapioCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// Assert based self test (XCTest needs full Xcode). `swift run capio-selftest`; exits 1 on the first failure.
var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !ok() { print("FAIL line \(line): \(what)"); exit(1) }
}

// MARK: geometry
let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
check(SelectionMath.rect(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50), in: screen) == CGRect(x: 100, y: 50, width: 200, height: 150), "drag up-left normalises")
check(SelectionMath.rect(from: CGPoint(x: 900, y: 500), to: CGPoint(x: 1200, y: 900), in: screen) == CGRect(x: 900, y: 500, width: 100, height: 100), "drag clamps to screen")
let sel = CGRect(x: 100, y: 100, width: 200, height: 100)
check(SelectionMath.handle(at: CGPoint(x: 103, y: 98), on: sel) == .topLeft, "corner grip found")
check(SelectionMath.handle(at: CGPoint(x: 200, y: 200), on: sel) == .bottom, "edge grip found")
check(SelectionMath.handle(at: CGPoint(x: 200, y: 150), on: sel) == nil, "inside is no grip")
check(SelectionMath.resize(sel, handle: .right, to: CGPoint(x: 350, y: 999), in: screen) == CGRect(x: 100, y: 100, width: 250, height: 100), "right grip moves only the right edge")
check(SelectionMath.resize(sel, handle: .left, to: CGPoint(x: 400, y: 0), in: screen) == CGRect(x: 300, y: 100, width: 100, height: 100), "dragging past the other edge flips")
check(SelectionMath.move(sel, by: CGVector(dx: 2000, dy: -500), in: screen) == CGRect(x: 800, y: 0, width: 200, height: 100), "move stays on screen")
check(SelectionMath.pixelRect(CGRect(x: 10.3, y: 5.6, width: 100.4, height: 50.2), scale: 2) == CGRect(x: 21, y: 11, width: 200, height: 101), "pixel rect rounds edges, not sizes")
check(SelectionMath.barOrigin(selection: sel, barSize: CGSize(width: 300, height: 44), bounds: screen).y == 216, "bar goes under the selection")
check(SelectionMath.barOrigin(selection: CGRect(x: 0, y: 500, width: 1000, height: 100), barSize: CGSize(width: 300, height: 44), bounds: screen).y == 440, "bar goes above when there is no room below")
check(SelectionMath.barOrigin(selection: screen, barSize: CGSize(width: 300, height: 44), bounds: screen).y == 540, "bar goes inside for a full screen selection")
check(BarLayout.slots(width: 600) == [0, 160, 370, 424, 476, 552], "bar: size left, wide Screenshot, small video and GIF, settings right")
check(BarLayout.slots(width: 1000)[1] == 346, "the capture group is centred under a wide selection")
check(BarLayout.width(for: CGRect(x: 0, y: 0, width: 120, height: 80), in: screen) == BarLayout.minWidth, "bar keeps a minimum width under a small selection")
check(BarLayout.width(for: sel.insetBy(dx: -200, dy: 0), in: screen) == 600, "bar is as wide as the selection")
check(BarLayout.width(for: screen, in: screen) == screen.width - 28, "bar stays on screen for a full screen selection")
let narrow = BarLayout.slots(width: BarLayout.minWidth)
check(narrow[0] + BarLayout.label < narrow[1] && narrow[4] + BarLayout.ghost <= narrow[5], "nothing overlaps at the minimum width")
check(Palette.indigo.luminance < 0.5 && Palette.red.luminance < 0.5 && Palette.yellow.luminance > 0.5 && Palette.green.luminance > 0.5, "text halo: light under indigo and red, dark under yellow and green")

// MARK: toast under the menu bar
let mac = CGRect(x: 0, y: 0, width: 1512, height: 982)
let toastSize = CGSize(width: 408, height: 150)
let barStays = ToastPlacement.frame(size: toastSize, screen: mac, visible: CGRect(x: 0, y: 0, width: 1512, height: 958), safeTop: 0, menuBar: 24)
check(barStays.maxY - ToastPlacement.cardInset == 982 - 24 - 12, "toast card starts 12 points under a menu bar that stays")
check(barStays.maxX == 1512 - 2, "toast keeps to the right edge")
let barHides = ToastPlacement.frame(size: toastSize, screen: mac, visible: mac, safeTop: 0, menuBar: 0)
check(barHides.maxY - ToastPlacement.cardInset == 982 - 24 - 12, "a menu bar that hides itself still counts")
let notch = ToastPlacement.frame(size: toastSize, screen: mac, visible: mac, safeTop: 38, menuBar: 24)
check(notch.maxY - ToastPlacement.cardInset == 982 - 38 - 12, "the notch counts as menu bar")
let other = CGRect(x: 1512, y: 200, width: 1920, height: 1080)
let onOther = ToastPlacement.frame(size: toastSize, screen: other, visible: CGRect(x: 1512, y: 200, width: 1920, height: 1055), safeTop: 0, menuBar: 24)
check(onOther.maxY - ToastPlacement.cardInset == 1280 - 25 - 12 && onOther.maxX == 3430, "a second screen uses its own top and right edge")

let stripSize = CGSize(width: 430, height: 40)
check(SelectionMath.stripOrigin(selection: CGRect(x: 244, y: 166, width: 524, height: 274), stripSize: stripSize, bounds: screen) == CGPoint(x: 244, y: 116), "tool strip sits above the left edge")
check(SelectionMath.stripOrigin(selection: CGRect(x: 330, y: 230, width: 300, height: 140), stripSize: stripSize, bounds: screen) == CGPoint(x: 265, y: 180), "tool strip is centred on a narrow selection")
check(SelectionMath.stripOrigin(selection: CGRect(x: 0, y: 20, width: 1000, height: 500), stripSize: stripSize, bounds: screen) == CGPoint(x: 8, y: 30), "tool strip moves inside without room above")
check(SelectionMath.stripOrigin(selection: CGRect(x: 900, y: 300, width: 100, height: 100), stripSize: stripSize, bounds: screen).x == 562, "tool strip stays on screen")

// MARK: annotations
check(Tool.forKey("O") == .obfuscate && Tool.forKey("x") == nil, "letter shortcuts")
check(!Annotation(tool: .arrow, color: Palette.indigo, points: [.zero, CGPoint(x: 3, y: 3)]).isMeaningful, "a click is no arrow")
check(Annotation(tool: .arrow, color: Palette.indigo, points: [.zero, CGPoint(x: 30, y: 0)]).isMeaningful, "a drag is an arrow")
check(!Annotation(tool: .text, color: Palette.indigo, points: [.zero], text: "  ").isMeaningful, "blank text is dropped")
let arrow = AnnotationRenderer.arrowPath(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 10))
check(arrow.contains(CGPoint(x: 108, y: 10)) && !arrow.contains(CGPoint(x: 115, y: 10)), "arrow tip ends at the target")
check(arrow.contains(CGPoint(x: 90, y: 16)) && !arrow.contains(CGPoint(x: 50, y: 18)), "head is wide, shaft is thin")

func pixel(_ ctx: CGContext, _ x: Int, _ yFromTop: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let i = yFromTop * ctx.bytesPerRow + x * 4
    return (p[i], p[i + 1], p[i + 2], p[i + 3])
}
let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
ctx.translateBy(x: 0, y: 100)
ctx.scaleBy(x: 1, y: -1)
AnnotationRenderer.draw([
    Annotation(tool: .rectangle, color: Palette.red, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)]),
    Annotation(tool: .highlight, color: Palette.yellow, points: [CGPoint(x: 120, y: 60), CGPoint(x: 190, y: 90)]),
    Annotation(tool: .number, color: Palette.indigo, points: [CGPoint(x: 150, y: 25)], number: 1),
], in: ctx)
let edge = pixel(ctx, 10, 25)
check(edge.0 > 200 && edge.1 < 90, "rectangle edge is red at the top left origin (got \(edge))")
check(pixel(ctx, 35, 25) == (255, 255, 255, 255), "rectangle is not filled")
let hl = pixel(ctx, 150, 75)
check(hl.0 > 230 && hl.2 < 200, "highlight tints yellow (got \(hl))")
let ring = pixel(ctx, 150, 13)
check(ring.0 > 200 && ring.1 > 200, "number has a white ring (got \(ring))")
let dot = pixel(ctx, 142, 25)
check(dot.2 > 200 && dot.0 < 140, "number disc is indigo (got \(dot))")
let digitWhite = (-5...5).contains { dx in (-5...5).contains { dy in let q = pixel(ctx, 150 + dx, 25 + dy); return q.0 > 230 && q.1 > 230 && q.2 > 230 } }
check(digitWhite, "number shows a white digit inside the disc")
check(AnnotationRenderer.textBounds("This amount is wrong", at: CGPoint(x: 5, y: 5)).width > 150, "text has a measurable width")

// MARK: history
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capio-selftest-\(UUID().uuidString)")
let index = dir.appendingPathComponent("history.json")
let t0 = Date(timeIntervalSince1970: 1_795_000_000)
let older = CaptureRecord(fileName: "Capio a.png", kind: .screenshot, createdAt: t0, bytes: 1000, pixelWidth: 10, pixelHeight: 10, ocrText: "Invoice Nordhaven")
let newer = CaptureRecord(fileName: "Capio b.mp4", kind: .screencast, createdAt: t0.addingTimeInterval(60), bytes: 5000, pixelWidth: 10, pixelHeight: 10, duration: 48)
do {
    let store = HistoryStore(indexURL: index)
    check(store.records.isEmpty, "fresh index is empty")
    try store.add(older)
    try store.add(newer)
    check(store.records.map(\.id) == [newer.id, older.id], "newest first")
    try store.replace(older.uploaded(link: "https://x/e/1", fileId: "1", shareId: "s", at: t0))
    let reread = HistoryStore(indexURL: index)
    check(reread.records.count == 2 && reread.record(id: older.id)?.link == "https://x/e/1", "survives a reload")
    check(reread.record(id: older.id)?.uploadedAt == t0, "the upload time survives a reload")
    check(HistoryStore.filter(reread.records, kind: nil, query: "nordhAVEN").map(\.id) == [older.id], "query searches recognised text")
    check(HistoryStore.filter(reread.records, kind: .screencast, query: "").map(\.id) == [newer.id], "kind filter")
    check(reread.record(id: older.id)?.withoutUpload().link == nil, "forgetting an upload clears the link")
    try reread.remove(id: newer.id)
    check(HistoryStore(indexURL: index).records.map(\.id) == [older.id], "remove persists")
    try Data("{not json".utf8).write(to: index)
    let broken = HistoryStore(indexURL: index)
    check(broken.records.isEmpty && broken.setAside != nil && FileManager.default.fileExists(atPath: broken.setAside!.path), "unreadable index is set aside, not overwritten")
} catch {
    check(false, "history threw \(error)")
}
try? FileManager.default.removeItem(at: dir)

// MARK: links live seven days
let week = CaptureRecord.linkLifetime
check(week == 7 * 86_400, "links live seven days")
let shared = older.uploaded(link: "https://x/v/a", fileId: "f", shareId: "s", at: t0)
check(!shared.linkExpired(now: t0.addingTimeInterval(week - 60)), "a link still works just before the seventh day ends")
check(shared.linkExpired(now: t0.addingTimeInterval(week)), "after seven days the link is due")
check(!older.linkExpired(now: t0.addingTimeInterval(30 * 86_400)), "a capture without a link never expires")
let legacy = CaptureRecord(fileName: "Capio c.gif", kind: .gif, createdAt: t0, bytes: 1, pixelWidth: 1, pixelHeight: 1,
                           link: "https://x/e/2", amforaFileId: "f2", amforaShareId: "s2")
check(legacy.uploadedAt == nil && legacy.linkExpired(now: t0.addingTimeInterval(week + 1)), "a link from before 0.5 counts from the capture date")
check(HistoryStore.expiredLinks([shared, newer, legacy], now: t0.addingTimeInterval(week + 1)).map(\.id) == [older.id, legacy.id], "only due links are picked")
check(shared.withoutUpload().uploadedAt == nil, "removing the link clears the upload time")
let stamped = legacy.stampingLegacyLink(t0.addingTimeInterval(30 * 86_400))
check(stamped.uploadedAt == t0.addingTimeInterval(30 * 86_400) && !stamped.linkExpired(now: t0.addingTimeInterval(31 * 86_400)), "a 0.4 link gets its own week once 0.5 starts")
check(shared.stampingLegacyLink(t0.addingTimeInterval(99)).uploadedAt == t0 && older.stampingLegacyLink(t0).uploadedAt == nil, "stamping leaves new links and local captures alone")
check(shared.linkIsOn(URL(string: "https://x")!) && !shared.linkIsOn(URL(string: "https://other.example")!) && !older.linkIsOn(URL(string: "https://x")!), "a link belongs to the server it was made on")
check(AmforaAPI.shareEnd(from: t0) == t0.addingTimeInterval(week), "a new share ends after seven days")
do {
    let legacyDir = FileManager.default.temporaryDirectory.appendingPathComponent("capio-legacy-\(UUID().uuidString)")
    let legacyIndex = legacyDir.appendingPathComponent("history.json")
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    let json = #"{"version":1,"records":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","fileName":"Capio d.png","kind":"screenshot","createdAt":"2026-11-20T10:00:00Z","bytes":10,"pixelWidth":2,"pixelHeight":2,"link":"https://x/e/3","amforaFileId":"f3","amforaShareId":"s3"}]}"#
    try Data(json.utf8).write(to: legacyIndex)
    let loaded = HistoryStore(indexURL: legacyIndex)
    check(loaded.records.count == 1 && loaded.setAside == nil && loaded.records[0].uploadedAt == nil, "a 0.4 history still loads")
    try? FileManager.default.removeItem(at: legacyDir)
} catch {
    check(false, "legacy history threw \(error)")
}

let name = CaptureNaming.fileName(kind: .screenshot, date: t0, isTaken: { _ in false })
check(name.hasPrefix("Capio ") && name.hasSuffix(".png") && name.contains(" at "), "file name shape: \(name)")
let taken: Set<String> = [name, name.replacingOccurrences(of: ".png", with: " (2).png")]
check(CaptureNaming.fileName(kind: .screenshot, date: t0, isTaken: taken.contains).hasSuffix(" (3).png"), "taken names get a number")
check(CaptureNaming.fileName(kind: .screenshot, ext: ImageFormat.jpegHigh.fileExtension, date: t0, isTaken: { _ in false }).hasSuffix(".jpg"), "a JPEG screenshot is named .jpg")

// MARK: quality
check(Quality.videoPixels(width: 3024, height: 1964, size: .original) == (3024, 1964), "Original keeps the area")
check(Quality.videoPixels(width: 3024, height: 1964, size: .p1080) == (1662, 1080), "1080p scales down to 1080 high, even width")
check(Quality.videoPixels(width: 3024, height: 1964, size: .p720) == (1108, 720), "720p scales down to 720 high")
check(Quality.videoPixels(width: 1048, height: 548, size: .p720) == (1048, 548), "a small area is never enlarged")
check(Quality.videoPixels(width: 1049, height: 549, size: .p1080) == (1048, 548), "odd sides become even")
check(Quality.videoPixels(width: 20, height: 1000, size: .p720) == (16, 720), "a tall narrow area keeps a width the encoder takes")
check(Quality.videoRate(width: 3840, height: 2160, wanted: 60) == 60, "4K records at 60")
check(Quality.videoRate(width: 5120, height: 2880, wanted: 60) == 30 && Quality.videoRate(width: 5120, height: 2880, wanted: 30) == 30, "5K is too large for 60 and records at 30")
check(Quality.videoHint(size: .original, fps: 60, screen: (5120, 2880)).contains("records at 30"), "the hint says when 60 is not possible")
check(!Quality.videoHint(size: .p1080, fps: 60, screen: (5120, 2880)).contains("records at"), "1080p at 60 fits on any screen")
check(Quality.videoBitRate(width: 1048, height: 548, fps: 30) == 2_000_000, "bit rate has a floor of 2 Mbps")
check(Quality.videoBitRate(width: 3024, height: 1964, fps: 30) == 17_817_408, "three bits a pixel a second")
check(Quality.videoBitRate(width: 3024, height: 1964, fps: 60) == 26_726_112, "60 frames get half as much again")
let mbs = VideoSize.allCases.map { size -> Int in
    let px = Quality.videoPixels(width: 3024, height: 1964, size: size)
    return Quality.megabytesPerMinute(bitRate: Quality.videoBitRate(width: px.width, height: px.height, fps: 30))
}
check(mbs == [134, 40, 18], "megabytes a minute for a full MacBook screen: \(mbs)")
check(Quality.videoHint(size: .p1080, fps: 30, screen: (3024, 1964)).contains("about 40 MB"), "video hint names the megabytes")
check(Quality.gifFactor(width: 800, rate: 15) == 1 && Quality.gifFactor(width: 1200, rate: 20) == 3, "GIF size next to the default")
check(Quality.gifHint(width: 800, rate: 15).hasPrefix("Fine"), "default GIF needs no warning")
check(Quality.gifHint(width: 1200, rate: 20) == "Larger file: about 3 times the size of 800 at 15.", "wide and fast GIF warns: \(Quality.gifHint(width: 1200, rate: 20))")
check(Quality.gifHint(width: 480, rate: 10) == "Smaller file: about 24% of the size of 800 at 15.", "small GIF: \(Quality.gifHint(width: 480, rate: 10))")
check(Quality.choice(12, from: Quality.gifRates, fallback: Quality.defaultGIFRate) == 15 && Quality.choice(20, from: Quality.gifRates, fallback: 15) == 20, "a stale stored number falls back")
check(ImageFormat.png.jpegQuality == nil && ImageFormat.jpegHigh.jpegQuality! > ImageFormat.jpegMedium.jpegQuality!, "JPEG High is better than Medium")
check(Quality.imageHint(format: .png, size: .normal).contains("quarter"), "Normal size says what it costs")
check(Quality.mime(fileExtension: "JPG") == "image/jpeg" && Quality.mime(fileExtension: "png") == "image/png" && Quality.mime(fileExtension: "mp4") == "video/mp4", "content type follows the file")
check(CaptureNaming.duration(48) == "0:48" && CaptureNaming.duration(3723) == "1:02:03", "durations")
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let noon = Date(timeIntervalSince1970: 1_795_262_400) // Sat 21 Nov 2026 12:00 UTC
check(CaptureNaming.when(noon.addingTimeInterval(-4_680), now: noon, calendar: utc) == "Today 10:42", "tile date: today")
check(CaptureNaming.when(noon.addingTimeInterval(-86_400 + 15_600), now: noon, calendar: utc) == "Yesterday 16:20", "tile date: yesterday")
check(CaptureNaming.when(noon.addingTimeInterval(-2 * 86_400), now: noon, calendar: utc) == "Thu 19 Nov", "tile date: this year")
check(CaptureNaming.when(noon.addingTimeInterval(-400 * 86_400), now: noon, calendar: utc) == "17 Oct 2025", "tile date: another year")

// MARK: amfora
check(AmforaConfig(address: "files.example.net", key: "amf_x")?.base.absoluteString == "https://files.example.net", "bare host gets https")
check(AmforaConfig(address: "https://files.example.net/some/page?q=1", key: "amf_x")?.base.absoluteString == "https://files.example.net", "path and query dropped")
check(AmforaConfig(address: "http://files.example.net", key: "amf_x") == nil, "plain http refused on the internet")
check(AmforaConfig(address: "http://192.168.1.20:5487", key: "amf_x") != nil, "plain http fine on the LAN")
check(AmforaConfig(address: "http://172.20.0.5", key: "amf_x") != nil, "172.16/12 is LAN")
check(AmforaConfig(address: "http://10.evil.com", key: "amf_x") == nil, "a name that starts like a LAN address is not LAN")
check(AmforaConfig(address: "http://192.168.example.org", key: "amf_x") == nil, "192.168.<name> is not LAN")
check(AmforaConfig(address: "http://172.32.0.1", key: "amf_x") == nil, "172.32 is not private")
check(AmforaConfig(address: "files.example.net", key: " ") == nil, "empty key refused")
check(AmforaConfig(address: "files.example.net", key: "amf_a\nX-Evil: 1") == nil, "key with a line break refused")
let cfg = AmforaConfig(address: "files.example.net", key: "amf_secret")!
let pre = AmforaAPI.presign(cfg, stem: "abc123", ext: "png", size: 2048)
check(pre.httpMethod == "GET" && pre.url?.absoluteString == "https://files.example.net/api/v1/files/presigned-url?filename=abc123&extension=png&size=2048", "presign request: \(pre.url!)")
check(pre.value(forHTTPHeaderField: "Authorization") == "Bearer amf_secret", "key sent as bearer")
let reg = AmforaAPI.register(cfg, name: "Capio a.png", ext: "png", size: 12, objectName: "u/1-x.png")
let regBody = try! JSONSerialization.jsonObject(with: reg.httpBody!) as! [String: Any]
check(reg.httpMethod == "POST" && regBody["objectName"] as? String == "u/1-x.png" && regBody["size"] as? Int == 12, "register body")
let sh = AmforaAPI.share(cfg, fileId: "f1", name: "n", expiration: nil)
let shBody = try! JSONSerialization.jsonObject(with: sh.httpBody!) as! [String: Any]
check(shBody["files"] as? [String] == ["f1"] && shBody["expiration"] == nil, "share body without end date")
check(AmforaAPI.alias(cfg, shareId: "s1", alias: "ab").url?.path == "/api/v1/shares/s1/alias", "alias path")
check(AmforaAPI.deleteFile(cfg, id: "f1").httpMethod == "DELETE" && AmforaAPI.deleteFile(cfg, id: "f1").httpBody == nil, "delete has no body")
check(AmforaAPI.link(cfg, kind: .screenshot, fileId: "f1", alias: "al") == "https://files.example.net/e/f1", "picture links inline")
check(AmforaAPI.link(cfg, kind: .screenshot, fileId: "f1", alias: "al", viewer: true) == "https://files.example.net/v/al"
    && AmforaAPI.link(cfg, kind: .screencast, fileId: "f1", alias: "al", viewer: true) == "https://files.example.net/v/al", "with the viewer every capture links to /v/")
check(AmforaAPI.link(cfg, kind: .screencast, fileId: "f1", alias: "al") == "https://files.example.net/s/al", "video links to the share page")
let tok = AmforaAPI.token(10)
check(tok.count == 10 && tok.allSatisfy { $0.isLetter || $0.isNumber }, "alias token is alphanumeric")
check(AmforaAPI.message(from: Data(#"{"error":"Alias already in use"}"#.utf8)) == "Alias already in use", "error text read")


// MARK: shortcuts
let ctrlCmd = Shortcut.control | Shortcut.command
let two = Shortcut(keyCode: 19, modifiers: ctrlCmd, label: "2")
check(two.display == "⌃⌘2" && Shortcut(keyCode: 1, modifiers: Shortcut.option | Shortcut.shift, label: "S").display == "⌥⇧S", "shortcut reads as macOS writes it")
check(two.isValid && !Shortcut(keyCode: 1, modifiers: Shortcut.shift, label: "S").isValid && !Shortcut(keyCode: 1, modifiers: 0, label: "S").isValid, "a shortcut needs ⌘, ⌃ or ⌥")
check(Shortcut(stored: two.stored) == two && Shortcut(stored: "43,256,,") == Shortcut(keyCode: 43, modifiers: Shortcut.command, label: ","), "shortcut survives preferences, comma key too")
check(Shortcut(stored: "x,1,2") == nil && Shortcut(stored: "19,0,2") == nil && Shortcut(stored: "999,256,2") == nil && Shortcut(stored: "") == nil, "unreadable shortcut is refused")
check(Shortcut.label(keyCode: 49, characters: " ") == "Space" && Shortcut.label(keyCode: 96, characters: "\u{F708}") == "F5" && Shortcut.label(keyCode: 1, characters: "s") == "S", "key labels")
check(Shortcut.label(keyCode: 117, characters: "\u{F728}") == "⌦" && Shortcut.label(keyCode: 116, characters: "\u{F72C}") == "Page Up", "keys without a character have a name")
check(Shortcut.label(keyCode: 200, characters: "\u{F72C}") == "" && !Shortcut(keyCode: 200, modifiers: ctrlCmd, label: "").isValid, "a key without a name is no shortcut")
check(Shortcut.carbon(cocoaFlags: (1 << 20) | (1 << 18)) == ctrlCmd && Shortcut.carbon(cocoaFlags: (1 << 16) | (1 << 19)) == Shortcut.option, "Cocoa flags to Carbon, caps lock ignored")
check(Set(ShortcutAction.allCases.map(\.id)).count == 5 && Set(ShortcutAction.allCases.map { $0.standard.keyCode }).count == 5, "five actions, five different standard keys")
let std = ShortcutSet.standard
check(ShortcutSet(stored: [:]) == std && ShortcutSet(stored: std.stored) == std && std[.area] == two, "no preferences means the standard keys")
check(std.owner(of: two, besides: .quick) == .area && std.owner(of: two, besides: .area) == nil, "double shortcut is found, not against itself")
let custom = std.setting(Shortcut(keyCode: 1, modifiers: Shortcut.option | Shortcut.shift, label: "S"), for: .area).setting(nil, for: .gif)
check(ShortcutSet(stored: custom.stored) == custom && custom[.gif] == nil && custom[.area]?.display == "⌥⇧S" && std[.gif] != nil, "changed and removed shortcuts survive, the original set is untouched")
check(ShortcutSet(stored: ["area": "garbage"])[.area] == two, "garbage falls back to the standard keys")
let clash = ShortcutSet(stored: ["window": ShortcutAction.area.standard.stored])
check(clash[.window] == two && clash[.area] == nil && clash[.quick] == ShortcutAction.quick.standard, "a standard key that is taken is not given twice")
check(SelectionMath.viewPoint(mouse: CGPoint(x: 1500, y: 100), screenFrame: CGRect(x: 1440, y: -200, width: 1000, height: 600)) == CGPoint(x: 60, y: 300), "mouse to view point on a second display")
let wins = [CGRect(x: 100, y: 100, width: 300, height: 200), CGRect(x: 0, y: 50, width: 900, height: 700)]
check(SelectionMath.pick(windows: wins, at: CGPoint(x: 150, y: 150), in: screen) == wins[0], "click takes the front window")
check(SelectionMath.pick(windows: wins, at: CGPoint(x: 50, y: 400), in: screen) == CGRect(x: 0, y: 50, width: 900, height: 550), "window is cut to the screen")
check(SelectionMath.pick(windows: wins, at: CGPoint(x: 950, y: 10), in: screen) == screen, "no window means the whole screen")

// MARK: updates
check(Updater.isNewer("0.7.1", than: "0.7.0") && !Updater.isNewer("0.7.0", than: "0.7.0") && !Updater.isNewer("0.6.9", than: "0.7.0"), "update: only a higher version counts")
check(Updater.isNewer("0.10.0", than: "0.9.9"), "update: versions compare as numbers")
check(Updater.isNewer("0.7.0", than: "0.7.0-beta.2") && Updater.isNewer("0.7.0-beta.2", than: "0.7.0-beta.1") && !Updater.isNewer("0.7.0-beta.9", than: "0.7.0"), "update: a release beats its betas")
check(Updater.allowed(URL(string: "https://github.com/x")!) && Updater.allowed(URL(string: "http://192.168.1.5/f")!), "update: https anywhere, http at home")
check(!Updater.allowed(URL(string: "http://example.org/f")!) && !Updater.allowed(URL(string: "http://192.168.example.org/f")!) && !Updater.allowed(URL(fileURLWithPath: "/tmp/f")), "update: no plain http outside, no files")
let feedText = #"{"version":"0.7.1","notes":["One","Two"],"url":"https://github.com/Solutionmax/capio/releases/download/v0.7.1/Capio-0.7.1.zip","signature":"c2ln","size":2100000}"#
let feedInfo = Updater.parse(Data(feedText.utf8))
check(feedInfo?.version == "0.7.1" && feedInfo?.notes == ["One", "Two"] && feedInfo?.size == 2_100_000 && feedInfo?.archive.lastPathComponent == "Capio-0.7.1.zip", "update: feed read")
check(Updater.parse(Data(feedText.replacingOccurrences(of: "https://github.com", with: "http://evil.example").utf8)) == nil, "update: feed with a plain http download refused")
check(Updater.parse(Data(feedText.replacingOccurrences(of: "\"signature\"", with: "\"sig\"").utf8)) == nil, "update: feed without a signature refused")
check(Updater.parse(Data("<html>not found</html>".utf8)) == nil && Updater.parse(Data(count: 300_000)) == nil, "update: a page or a huge answer is no feed")
let releaseKey = Curve25519.Signing.PrivateKey(), otherKey = Curve25519.Signing.PrivateKey()
let archive = Data("the zip".utf8)
let goodSignature = try! releaseKey.signature(for: archive).base64EncodedString()
check(Updater.verify(archive, signature: goodSignature + "\n", key: releaseKey.publicKey), "update: archive signed with the release key passes")
check(!Updater.verify(archive + Data([0]), signature: goodSignature, key: releaseKey.publicKey), "update: a changed archive fails")
check(!Updater.verify(archive, signature: goodSignature, key: otherKey.publicKey), "update: another key fails")
check(!Updater.verify(archive, signature: "bm9wZQ==", key: releaseKey.publicKey) && !Updater.verify(archive, signature: "", key: releaseKey.publicKey), "update: something that is no signature fails")
let keyText = releaseKey.publicKey.rawRepresentation.base64EncodedString()
let nextPlist: [String: Any] = ["CFBundleIdentifier": "net.solutionmax.capio", "CFBundleShortVersionString": "0.7.1",
                                "CapioUpdateFeed": "https://example.org/capio-update.json", "CapioUpdatePublicKey": keyText]
func accepted(_ change: (inout [String: Any]) -> Void = { _ in }, current: String = "0.7.0") -> String? {
    var plist = nextPlist
    change(&plist)
    return Updater.accepts(plist as NSDictionary, bundleIdentifier: "net.solutionmax.capio", newerThan: current, key: releaseKey.publicKey)
}
check(accepted() == "0.7.1", "update: Capio's own newer app accepted")
check(accepted(current: "0.7.1") == nil && accepted(current: "0.8.0") == nil, "update: same or older version refused")
check(accepted { $0["CFBundleIdentifier"] = "com.example.other" } == nil, "update: another app refused")
check(accepted { $0["CapioUpdatePublicKey"] = otherKey.publicKey.rawRepresentation.base64EncodedString() } == nil, "update: an app that trusts another key refused")
check(accepted { $0["CapioUpdateFeed"] = nil } == nil, "update: an app without a feed refused")

// The system's own Calculator stands in for a signed app: it meets its own requirement and not Capio's.
let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
if let own = Updater.requirement(ofApp: calculator) {
    check(Updater.signed(calculator, satisfying: own), "update: an app meets its own signing requirement")
    check(!Updater.signed(calculator, satisfying: #"identifier "net.solutionmax.capio""#), "update: an app signed as something else refused")
    check(!Updater.signed(URL(fileURLWithPath: "/tmp"), satisfying: own), "update: a folder that is no app refused")
} else { check(false, "update: no signing requirement read from Calculator") }

// The install script, for real, on folders of its own.
do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("capio-selftest-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let target = root.appendingPathComponent("Capio (1).app"), staged = Updater.staged(for: target)
    let old = URL(fileURLWithPath: target.path + ".capio-old")
    func bundle(_ url: URL, mark: String) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try (["CFBundleExecutable": "Capio"] as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try mark.write(to: url.appendingPathComponent("mark"), atomically: true, encoding: .utf8)
    }
    func mark() -> String? { try? String(contentsOf: target.appendingPathComponent("mark"), encoding: .utf8) }
    func leftovers() -> [String] { ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != target.lastPathComponent }.sorted() }
    func install(relaunch: Bool) {
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! gone.run(); gone.waitUntilExit()
        let script = Updater.installScript(replacing: target, pid: gone.processIdentifier, relaunch: relaunch, open: "/usr/bin/true",
                                           settle: 1, lock: root.appendingPathComponent("lock").path)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh"); sh.arguments = ["-c", script]
        try! sh.run(); sh.waitUntilExit()
    }
    try bundle(target, mark: "old")
    try bundle(staged, mark: "new")
    install(relaunch: false)
    check(mark() == "new", "update: install on quit puts the new app in place")
    check(leftovers().isEmpty, "update: old copy, staged copy and lock are gone afterwards: \(leftovers())")
    // Nothing starts here (open is /usr/bin/true), so the relaunch never shows up and the working copy must come back.
    try bundle(staged, mark: "broken")
    install(relaunch: true)
    check(mark() == "new" && leftovers().isEmpty, "update: an app that does not start is rolled back: \(leftovers())")
    // The staged copy vanished (cleaned up, disk trouble): the running app stays as it is.
    install(relaunch: false)
    check(mark() == "new" && leftovers().isEmpty, "update: without a staged copy nothing is touched")
    // A run that was killed between the two renames left only the old copy: the next run puts it back.
    try fm.moveItem(at: target, to: old)
    install(relaunch: false)
    check(mark() == "new" && leftovers().isEmpty, "update: an old copy without an app is put back")
    // Another install holds the lock: this one steps aside and leaves the app alone.
    try fm.createDirectory(at: root.appendingPathComponent("lock"), withIntermediateDirectories: true)
    try bundle(staged, mark: "second")
    install(relaunch: false)
    check(mark() == "new" && fm.fileExists(atPath: staged.path), "update: a second install waits its turn")
} catch { check(false, "update: install test could not set up: \(error)") }

print("capio-selftest: \(checks) checks passed")

// MARK: live upload (optional): `capio-selftest --amfora <address>` with the key on stdin.
// Uploads a small PNG, checks the link serves it, deletes the upload and checks the link is gone.
if let i = CommandLine.arguments.firstIndex(of: "--amfora"), i + 1 < CommandLine.arguments.count {
    let key = readLine(strippingNewline: true) ?? ""
    guard let live = AmforaConfig(address: CommandLine.arguments[i + 1], key: key) else { print("FAIL: bad address or key"); exit(1) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("Capio live test \(Int(Date().timeIntervalSince1970)).png")
    let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    check(CGImageDestinationFinalize(dest), "test PNG written")
    let done = DispatchSemaphore(value: 0)
    Task {
        defer { done.signal() }
        do {
            let client = AmforaClient(cfg: live)
            print("account: \(try await client.whoAmI())")
            let last = ProgressBox()
            let up = try await client.upload(file: file, kind: .screenshot) { p in last.value = p }
            print("link: \(up.link) (progress reached \(Int(last.value * 100))%)")
            let (body, response) = try await URLSession.shared.data(from: URL(string: up.link)!)
            let http = response as! HTTPURLResponse
            check(http.statusCode == 200, "link answers 200 (got \(http.statusCode))")
            check(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/png") == true, "link serves a PNG inline (got \(http.value(forHTTPHeaderField: "Content-Type") ?? "-"))")
            check(body.count == (try? Data(contentsOf: file))?.count, "served bytes match the upload")
            var shareReq = URLRequest(url: live.base.appendingPathComponent("api/v1/shares/\(up.shareId)"))
            shareReq.setValue("Bearer \(live.key)", forHTTPHeaderField: "Authorization")
            let shareData = try await URLSession.shared.data(for: shareReq).0
            let share = (try JSONSerialization.jsonObject(with: shareData) as? [String: Any])?["share"] as? [String: Any]
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let end = (share?["expiration"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            check(end.map { abs($0.timeIntervalSinceNow - CaptureRecord.linkLifetime) < 300 } == true,
                  "the share ends in seven days (got \(share?["expiration"] ?? "nothing"))")
            try await client.deleteUpload(fileId: up.fileId, shareId: up.shareId)
            let fresh = URLRequest(url: URL(string: up.link)!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            let after = try await URLSession.shared.data(for: fresh).1 as! HTTPURLResponse
            check(after.statusCode >= 400, "link is gone after delete (got \(after.statusCode))")
            try await client.deleteUpload(fileId: up.fileId, shareId: up.shareId)
            print("second delete is quiet")
        } catch {
            check(false, "live upload threw: \(error.localizedDescription)")
        }
    }
    done.wait()
    try? FileManager.default.removeItem(at: file)
    print("capio-selftest live: \(checks) checks passed")
}

final class ProgressBox: @unchecked Sendable { var value = 0.0 }
