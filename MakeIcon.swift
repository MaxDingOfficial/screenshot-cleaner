import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let specifications = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]
for (size, name) in specifications {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 195, yRadius: 195)
    NSColor(calibratedRed: 0.10, green: 0.40, blue: 0.36, alpha: 1).setFill(); background.fill()
    let frame = NSBezierPath(roundedRect: NSRect(x: 257, y: 280, width: 510, height: 438), xRadius: 46, yRadius: 46)
    frame.lineWidth = 26; NSColor.white.withAlphaComponent(0.94).setStroke(); frame.stroke()
    NSColor.white.withAlphaComponent(0.14).setFill(); frame.fill()
    let horizon = NSBezierPath(); horizon.move(to: NSPoint(x: 283, y: 411)); horizon.line(to: NSPoint(x: 411, y: 552)); horizon.line(to: NSPoint(x: 515, y: 455)); horizon.line(to: NSPoint(x: 611, y: 565)); horizon.line(to: NSPoint(x: 739, y: 416)); horizon.line(to: NSPoint(x: 739, y: 326)); horizon.line(to: NSPoint(x: 283, y: 326)); horizon.close()
    NSColor.white.withAlphaComponent(0.90).setFill(); horizon.fill()
    NSBezierPath(ovalIn: NSRect(x: 590, y: 609, width: 54, height: 54)).fill()
    for (x, y, directionX, directionY) in [(205.0, 770.0, 1.0, -1.0), (819.0, 770.0, -1.0, -1.0), (205.0, 229.0, 1.0, 1.0), (819.0, 229.0, -1.0, 1.0)] {
        let corner = NSBezierPath(); corner.move(to: NSPoint(x: x + 78 * directionX, y: y)); corner.line(to: NSPoint(x: x, y: y)); corner.line(to: NSPoint(x: x, y: y + 78 * directionY)); corner.lineWidth = 23; corner.lineCapStyle = .round; corner.lineJoinStyle = .round; NSColor.white.withAlphaComponent(0.75).setStroke(); corner.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
