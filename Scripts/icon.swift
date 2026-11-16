// Draws the app icon into an .iconset folder: `swift Scripts/icon.swift <dir>.iconset`,
// then `iconutil -c icns <dir>.iconset`. `make icon` does both.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Draws on a 1024pt canvas (macOS icon grid: 824pt tile, 100pt margin).
func draw() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.75, blue: 0.40, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.47, blue: 0.24, alpha: 1))!
        .draw(in: shape, angle: -90)

    // Pull-request glyph: a branch on the left, and a line from the right
    // commit that bends back towards the top-left with an arrow.
    NSColor.white.set()
    let width: CGFloat = 46, r: CGFloat = 62
    func ring(_ x: CGFloat, _ y: CGFloat) {
        let ring = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        ring.lineWidth = width
        ring.stroke()
    }
    func stroke(_ build: (NSBezierPath) -> Void) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        build(path)
        path.stroke()
    }
    let left: CGFloat = 370, right: CGFloat = 654, top: CGFloat = 712, bottom: CGFloat = 312

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
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
