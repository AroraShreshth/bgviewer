// Converts square icon artwork (e.g. assets/icon_art.png) into AppIcon.icns,
// applying the macOS icon grid: transparent canvas, ~10% margin, squircle mask.
//
//   swift assets/png_to_icns.swift assets/icon_art.png assets/AppIcon.icns [assets/icon.png]
//
// The optional third argument also exports a single 256px squircled PNG
// (used at the top of the README).
import AppKit

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: swift png_to_icns.swift <art.png> <out.icns> [preview.png]\n".data(using: .utf8)!)
    exit(2)
}
let artPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let previewPath = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil

guard let art = NSImage(contentsOfFile: artPath) else { fatalError("can't read \(artPath)") }

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let s = CGFloat(px)
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    path.addClip()
    art.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("bgviewer-icns-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in entries {
    try render(px).representation(using: .png, properties: [:])!
        .write(to: tmp.appendingPathComponent("\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", outPath]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }

if let previewPath {
    try render(256).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: previewPath))
}
print("wrote \(outPath)\(previewPath.map { " + \($0)" } ?? "")")
