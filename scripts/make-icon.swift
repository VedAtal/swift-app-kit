// Renders an app icon into an .iconset folder (setup.sh turns it into AppIcon.icns): a white
// SF Symbol on a rounded square with a top-to-bottom gradient. Every app uses this, so the icons
// look like a set.
// Usage: swift make-icon.swift <output.iconset> <symbol> "<top r g b>" "<bottom r g b>"
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset> <symbol> \"<top r g b>\" \"<bottom r g b>\"\n".utf8))
    exit(1)
}
let outputDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let symbolName = arguments[2]

/// "0.36 0.52 1.0" → a color.
func color(_ rgb: String) -> NSColor {
    let parts = rgb.split(separator: " ").compactMap { Double($0) }
    guard parts.count == 3 else {
        FileHandle.standardError.write(Data("make-icon: expected \"r g b\" from 0 to 1, got \"\(rgb)\"\n".utf8))
        exit(1)
    }
    return NSColor(calibratedRed: parts[0], green: parts[1], blue: parts[2], alpha: 1)
}

let top = color(arguments[3])
let bottom = color(arguments[4])

let sizes: [(name: String, pixels: Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Same proportions as Apple's macOS icon grid: ~10% margin, ~22% corner radius.
    let size = CGFloat(pixels)
    let body = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.1, dy: size * 0.1)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.5, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in sizes {
    try render(pixels: pixels).write(to: outputDir.appendingPathComponent("icon_\(name).png"))
}
