// Renders AppIcon.iconset: swiftc scripts/make_icon.swift -o make_icon && ./make_icon out/AppIcon.iconset
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    let c1 = NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.98, alpha: 1)
    let c2 = NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.70, alpha: 1)
    NSGradient(starting: c1, ending: c2)!.draw(in: shape, angle: 45)

    // two arrows: → on top, ← below
    NSColor.white.setStroke()
    let p = NSBezierPath()
    p.lineWidth = 64 * s
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    let l = body.minX + 210 * s, r = body.maxX - 210 * s, head = 110 * s
    let y1 = body.midY + 120 * s, y2 = body.midY - 120 * s
    p.move(to: NSPoint(x: l, y: y1)); p.line(to: NSPoint(x: r, y: y1))
    p.move(to: NSPoint(x: r - head, y: y1 + head)); p.line(to: NSPoint(x: r, y: y1)); p.line(to: NSPoint(x: r - head, y: y1 - head))
    p.move(to: NSPoint(x: r, y: y2)); p.line(to: NSPoint(x: l, y: y2))
    p.move(to: NSPoint(x: l + head, y: y2 + head)); p.line(to: NSPoint(x: l, y: y2)); p.line(to: NSPoint(x: l + head, y: y2 - head))
    p.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("iconset written to \(out.path)")
