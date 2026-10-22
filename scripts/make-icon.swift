import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let variants = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]
for (size, name) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let transform = AffineTransform(scale: Double(size) / 1024)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 218, yRadius: 218)
    NSGradient(starting: NSColor(red: 0.12, green: 0.46, blue: 0.38, alpha: 1),
        ending: NSColor(red: 0.06, green: 0.27, blue: 0.24, alpha: 1))!.draw(in: background, angle: -70)
    let heights: [CGFloat] = [115, 220, 390, 510, 325, 200, 95]
    for (index, height) in heights.enumerated() {
        let x = CGFloat(242 + index * 90)
        let wave = NSBezierPath(); wave.lineWidth = 42; wave.lineCapStyle = .round
        wave.move(to: NSPoint(x: x, y: 512 - height / 2)); wave.line(to: NSPoint(x: x, y: 512 + height / 2))
        NSColor(red: 0.88, green: 0.98, blue: 0.88, alpha: index == 6 ? 0.6 : 1).setStroke(); wave.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
