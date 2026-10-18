// Renders the app icon (a balloon with a wrench, on a rounded square) into an .iconset folder.
// Usage: swift make-icon.swift <output.iconset>   then: iconutil -c icns <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 rounded square with a soft shadow.
    let inset = s * 100 / 1024, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSGradient(starting: NSColor(red: 0.30, green: 0.73, blue: 0.98, alpha: 1), ending: NSColor(red: 0.12, green: 0.42, blue: 0.86, alpha: 1))!
        .draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    func symbol(_ name: String, size: CGFloat, color: NSColor, at center: NSPoint) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let r = NSRect(x: center.x - img.size.width / 2, y: center.y - img.size.height / 2, width: img.size.width, height: img.size.height)
        img.draw(in: r)
    }
    symbol("balloon.fill", size: s * 0.42, color: NSColor(red: 0.95, green: 0.22, blue: 0.24, alpha: 1), at: NSPoint(x: s * 0.46, y: s * 0.55))
    symbol("wrench.adjustable.fill", size: s * 0.2, color: .white, at: NSPoint(x: s * 0.66, y: s * 0.32))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
