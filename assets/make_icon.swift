// Generates AppIcon.icns: macOS-style rounded rectangle, dark gradient,
// white gauge symbol (the same SF Symbol the menu bar shows).
//
//   swift assets/make_icon.swift assets/AppIcon.icns
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    // Apple's icon grid: content square inset ~10%, corner radius ~22.5% of it.
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!
        .draw(in: path, angle: -90)

    if let sym = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                         accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let tinted = sym.withSymbolConfiguration(cfg) {
            let size = tinted.size
            let scale = (rect.width * 0.60) / max(size.width, size.height)
            let w = size.width * scale, h = size.height * scale
            tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("bgviewer-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in entries {
    let png = render(px).representation(using: .png, properties: [:])!
    try png.write(to: tmp.appendingPathComponent("\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", outPath]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(outPath)")
