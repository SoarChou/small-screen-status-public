import AppKit

// Two offset screens and one progress mark: the same silhouette is used by the
// application icon and the monochrome menu bar item.
enum BrandGlyph {
    static func draw(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 18, yBy: rect.height / 18)
        transform.concat()

        let rear = NSBezierPath(roundedRect: NSRect(x: 5.0, y: 6.1, width: 11.0, height: 9.0),
                                xRadius: 1.9, yRadius: 1.9)
        rear.lineWidth = 1.65
        color.withAlphaComponent(0.58).setStroke()
        rear.stroke()

        let front = NSBezierPath(roundedRect: NSRect(x: 2.0, y: 2.9, width: 11.0, height: 9.0),
                                 xRadius: 1.9, yRadius: 1.9)
        front.lineWidth = 1.85
        color.setStroke()
        front.stroke()

        let progress = NSBezierPath()
        progress.move(to: NSPoint(x: 4.45, y: 6.0))
        progress.line(to: NSPoint(x: 7.75, y: 6.0))
        progress.lineWidth = 1.45
        progress.lineCapStyle = .round
        progress.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 9.25, y: 5.18, width: 1.65, height: 1.65)).fill()
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { rect in
            draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }
}
