import AppKit

/// The app icon's pull-request glyph as a menu-bar template image, so macOS
/// tints it like any other menu-bar icon. Same geometry as Scripts/icon.swift
/// (a 1024pt canvas); keep the two in sync.
enum MenuBarIcon {
    static let image: NSImage = {
        let lineWidth: CGFloat = 50 // the app icon uses 46; a touch heavier reads better at 16pt
        let pad = (lineWidth - 46) / 2
        // The glyph's bounds on the icon canvas, including the stroke.
        let box = NSRect(x: 285 - pad, y: 227 - pad, width: 454 + 2 * pad, height: 570 + 2 * pad)
        let height: CGFloat = 16
        let size = NSSize(width: ceil(height * box.width / box.height), height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            let scale = rect.height / box.height
            let transform = NSAffineTransform()
            transform.translateX(by: (rect.width - box.width * scale) / 2, yBy: 0)
            transform.scale(by: scale)
            transform.translateX(by: -box.minX, yBy: -box.minY)
            transform.concat()
            NSColor.black.set()

            let r: CGFloat = 62
            let left: CGFloat = 370, right: CGFloat = 654, top: CGFloat = 712, bottom: CGFloat = 312
            func ring(_ x: CGFloat, _ y: CGFloat) {
                let path = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                path.lineWidth = lineWidth
                path.stroke()
            }
            func stroke(_ build: (NSBezierPath) -> Void) {
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                build(path)
                path.stroke()
            }

            ring(left, top)
            ring(left, bottom)
            stroke { $0.move(to: NSPoint(x: left, y: top - r)); $0.line(to: NSPoint(x: left, y: bottom + r)) }
            ring(right, bottom)
            stroke {
                $0.move(to: NSPoint(x: right, y: bottom + r))
                $0.line(to: NSPoint(x: right, y: top - 60))
                $0.curve(to: NSPoint(x: right - 60, y: top), controlPoint1: NSPoint(x: right, y: top - 27), controlPoint2: NSPoint(x: right - 27, y: top))
                $0.line(to: NSPoint(x: 512, y: top))
            }
            stroke {
                $0.move(to: NSPoint(x: 564, y: top + 52))
                $0.line(to: NSPoint(x: 512, y: top))
                $0.line(to: NSPoint(x: 564, y: top - 52))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PRty Time"
        return image
    }()
}
