// Renders the real app screens (light + dark) for design review and the README. Run scripts/screenshots.sh.
//   plain:  <out>/<screen>[-dark].png              content only, for quick review
//   framed: <out>/framed/<screen>-{light,dark}.png  as a macOS window (rounded corners, traffic lights, shadow)
//   gif:    <out>/framed/permission-{light,dark}.gif the permission guide's animation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct Snapshots {
    static let size = NSSize(width: 640, height: 520)

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "snapshots-out")
        let framed = out.appendingPathComponent("framed")
        try? FileManager.default.createDirectory(at: framed, withIntermediateDirectories: true)

        let screens: [(String, AppModel.Screen)] = [
            ("1-intel", .intel), ("2-nogame", .noGame), ("3-rosetta", .rosetta),
            ("4-ask-access", .askAccess(.documents)), ("5-access-denied", .accessDenied(.documents)),
            ("6-install", .install), ("7-working", .working("Installing")), ("8-home", .home),
            ("9-preparing", .preparing), ("9b-steam", .steam(signIn: true)), ("10-playing", .playing),
            ("11-crash", .failed("crash")), ("12-error", .failed("Downloading .NET failed. Check your internet connection.")),
        ]
        for (name, screen) in screens {
            for dark in [false, true] {
                guard let rep = render(screen, dark: dark, at: 1.2) else { print("failed \(name)"); continue }
                write(rep, to: out.appendingPathComponent(name + (dark ? "-dark" : "") + ".png"))
                write(frame(rep, dark: dark), to: framed.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
            print("wrote \(name)")
        }
        // Animated permission guide: one loop of the switch being turned on.
        for dark in [false, true] {
            var frames: [CGImage] = []
            let period = 2.6, fps = 15.0
            let start = Date().timeIntervalSinceReferenceDate
            let phase0 = start.truncatingRemainder(dividingBy: period)
            for i in 0..<Int(period * fps) {
                let target = start - phase0 + period + Double(i) / fps   // aligned to the loop start
                let wait = target - Date().timeIntervalSinceReferenceDate
                guard let rep = render(.accessDenied(.documents), dark: dark, at: max(0.05, wait)) else { continue }
                frames.append(downscale(frame(rep, dark: dark), by: 0.5))
            }
            writeGIF(frames, delay: 1 / fps, to: framed.appendingPathComponent("permission-\(dark ? "dark" : "light").gif"))
        }
        print("wrote gifs")
    }

    // MARK: Rendering

    @MainActor static func model(for screen: AppModel.Screen) -> AppModel {
        let m = AppModel()
        m.screen = screen
        // The real game icon when SNAPSHOT_GAME_APP points at BloonsTD6.app, else a neutral placeholder.
        if let app = ProcessInfo.processInfo.environment["SNAPSHOT_GAME_APP"] {
            m.gameIcon = NSWorkspace.shared.icon(forFile: app)
        } else {
            m.gameIcon = placeholderIcon
        }
        m.gameVersion = "57.2"
        // Popular public mods from the Mod Browser.
        m.mods = ["Btd6ModHelper.dll", "UsefulUtilities.dll", "PathsPlusPlus.dll", "AbilityChoice.dll",
                  "MegaKnowledge.dll", "AutoNudge.dll"].map { Engine.Mod(file: $0) }
        m.progress = 0.8; m.progressLabel = "Installing .NET"
        m.prepSteps[0].done = true; m.prepSteps[1].done = true
        return m
    }

    /// Renders a screen in a real (off-screen) window, after letting layout and animations run for `wait` seconds.
    @MainActor static func render(_ screen: AppModel.Screen, dark: Bool, at wait: Double) -> NSBitmapImageRep? {
        let view = ContentView().environmentObject(model(for: screen))
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// Puts a rendered screen in a macOS-style window: rounded corners, traffic lights, hairline border, soft shadow.
    static func frame(_ rep: NSBitmapImageRep, dark: Bool) -> CGImage {
        let scale = CGFloat(rep.pixelsWide) / size.width
        let pad: CGFloat = 40 * scale, radius: CGFloat = 16 * scale
        let w = CGFloat(rep.pixelsWide) + pad * 2, h = CGFloat(rep.pixelsHigh) + pad * 2
        let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: pad, y: pad, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.28))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: dark ? 0.12 : 1, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.draw(rep.cgImage!, in: rect)
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.18 : 0.12)); ctx.setLineWidth(1 * scale); ctx.strokePath()
        // Traffic lights (12 pt circles, 20 pt apart, 20 pt from the top-left corner).
        let colors: [CGColor] = [CGColor(red: 1, green: 0.373, blue: 0.341, alpha: 1), CGColor(red: 0.996, green: 0.737, blue: 0.180, alpha: 1),
                                 CGColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
        for (i, c) in colors.enumerated() {
            let cx = rect.minX + (20 + CGFloat(i) * 20) * scale, cy = rect.maxY - 20 * scale
            ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: cx - 6 * scale, y: cy - 6 * scale, width: 12 * scale, height: 12 * scale))
        }
        return ctx.makeImage()!
    }

    static let placeholderIcon: NSImage = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
        NSColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 20, dy: 20), xRadius: 50, yRadius: 50).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 110, weight: .bold).applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            sym.draw(in: NSRect(x: (256 - sym.size.width) / 2, y: (256 - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
        }
        return true
    }

    static func downscale(_ img: CGImage, by f: CGFloat) -> CGImage {
        let w = Int(CGFloat(img.width) * f), h = Int(CGFloat(img.height) * f)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    // MARK: Output

    static func write(_ rep: NSBitmapImageRep, to url: URL) { try? rep.representation(using: .png, properties: [:])?.write(to: url) }
    static func write(_ img: CGImage, to url: URL) { write(NSBitmapImageRep(cgImage: img), to: url) }

    static func writeGIF(_ frames: [CGImage], delay: Double, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }
}
