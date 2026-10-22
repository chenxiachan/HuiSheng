import AppKit

// Shared family palette with ThoughtDAG / TextFold: warm white, violet and amber.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

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
    NSGradient(starting: color(0xFFFFFF), ending: color(0xF0EDFA))!.draw(in: background, angle: -70)
    let rim = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 210, yRadius: 210)
    color(0xFFFFFF, alpha: 0.9).setStroke(); rim.lineWidth = 3; rim.stroke()
    let heights: [CGFloat] = [115, 220, 390, 510, 325, 200, 95]
    for (index, height) in heights.enumerated() {
        let x = CGFloat(242 + index * 90)
        let wave = NSBezierPath(roundedRect: NSRect(x: x - 21, y: 512 - height / 2 - 21, width: 42, height: height + 42), xRadius: 21, yRadius: 21)
        let alpha: CGFloat = index == 0 ? 0.4 : index == 1 ? 0.65 : 1
        let top = index == 6 ? color(0xF2A45F) : color(0x8175F0, alpha: alpha)
        let bottom = index == 6 ? color(0xD8742D) : color(0x5847D7, alpha: alpha)
        NSGradient(starting: bottom, ending: top)!.draw(in: wave, angle: 90)
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
