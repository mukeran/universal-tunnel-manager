import AppKit

enum TunnelIcon {
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { rect in
            drawGlyph(in: rect, upper: .black, lower: .black)
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func drawGlyph(in rect: NSRect, upper: NSColor, lower: NSColor) {
        let scale = min(rect.width / 20, rect.height / 16)
        let origin = NSPoint(x: rect.midX - 10 * scale, y: rect.midY - 8 * scale)

        for (color, reversed) in [(upper, false), (lower, true)] {
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: origin.x + (reversed ? 20 - x : x) * scale,
                        y: origin.y + (reversed ? 16 - y : y) * scale)
            }

            color.set()
            let source = point(2.4, 11.25)
            let radius = 1.55 * scale
            NSBezierPath(ovalIn: NSRect(x: source.x - radius, y: source.y - radius,
                                        width: 2 * radius, height: 2 * radius)).fill()

            let arrow = NSBezierPath()
            arrow.move(to: point(5.65, 11.25))
            arrow.line(to: point(17.45, 11.25))
            arrow.move(to: point(14.4, 14.3))
            arrow.line(to: point(17.45, 11.25))
            arrow.line(to: point(14.4, 8.2))
            arrow.lineWidth = 1.6 * scale
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
        }
    }
}
