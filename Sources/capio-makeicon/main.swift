import CapioCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// `swift run capio-makeicon <dir>.iconset` writes the PNG sizes iconutil wants.
guard CommandLine.arguments.count == 2 else { print("usage: capio-makeicon <dir>.iconset"); exit(2) }
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let img = CapioIcon.image(pixels: px),
              let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { print("could not draw \(name)"); exit(1) }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { print("could not write \(name)"); exit(1) }
    }
}
print("icon written to \(dir.path)")
