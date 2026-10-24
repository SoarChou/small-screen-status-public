import AppKit
import Foundation

@main
enum GenerateIcon {
    static func drawIcon() {
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()

        let tile = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888),
                                xRadius: 208, yRadius: 208)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.105, green: 0.145, blue: 0.145, alpha: 1),
                                  ending: NSColor(calibratedRed: 0.055, green: 0.077, blue: 0.080, alpha: 1))!
        gradient.draw(in: tile, angle: -45)
        NSColor.white.withAlphaComponent(0.085).setStroke()
        tile.lineWidth = 7
        tile.stroke()

        NSColor(calibratedRed: 0.58, green: 0.83, blue: 0.71, alpha: 0.075).setFill()
        NSBezierPath(ovalIn: NSRect(x: 215, y: 295, width: 595, height: 595)).fill()
        BrandGlyph.draw(in: NSRect(x: 183, y: 183, width: 658, height: 658),
                        color: NSColor(calibratedRed: 0.67, green: 0.88, blue: 0.76, alpha: 1))
    }

    static func png(size: Int) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        context.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 1024)
        transform.concat()
        drawIcon()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "usage: generate_icon <icns> <preview png>"])
        }
        let icon = URL(fileURLWithPath: CommandLine.arguments[1])
        let preview = URL(fileURLWithPath: CommandLine.arguments[2])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2),
                                (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try png(size: points * scale).write(to: temporary.appendingPathComponent(name))
        }
        try png(size: 1024).write(to: preview)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", temporary.path, "-o", icon.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
        }
    }
}
