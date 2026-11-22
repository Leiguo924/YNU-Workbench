import AppKit

enum WorkbenchMark {
    static func draw(in rect: CGRect, primary: NSColor, accent: NSColor) {
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / 20)
        func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.transform(using: transform as AffineTransform)
            path.lineWidth *= rect.width / 20
            color.setStroke()
            path.stroke()
        }

        let ridge = NSBezierPath()
        ridge.move(to: NSPoint(x: 2.7, y: 8.4))
        ridge.line(to: NSPoint(x: 7.2, y: 14.1))
        ridge.curve(to: NSPoint(x: 8.6, y: 14.1),
                    controlPoint1: NSPoint(x: 7.6, y: 14.6), controlPoint2: NSPoint(x: 8.2, y: 14.6))
        ridge.line(to: NSPoint(x: 11.2, y: 10.8))
        ridge.line(to: NSPoint(x: 12.6, y: 12.5))
        ridge.curve(to: NSPoint(x: 14, y: 12.5),
                    controlPoint1: NSPoint(x: 13, y: 13), controlPoint2: NSPoint(x: 13.6, y: 13))
        ridge.line(to: NSPoint(x: 17.3, y: 8.4))
        stroke(ridge, color: primary, width: 1.8)

        let desk = NSBezierPath()
        desk.move(to: NSPoint(x: 4.1, y: 5.4))
        desk.line(to: NSPoint(x: 15.9, y: 5.4))
        stroke(desk, color: accent, width: 1.65)
    }

    static var menuImage: NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { rect in
            draw(in: rect, primary: .black, accent: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "云大工作台"
        return image
    }
}
