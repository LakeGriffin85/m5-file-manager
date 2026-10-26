import AppKit
let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
func render(_ pixels: Int, to name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
        pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Icon-Kontext fehlt") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let bg = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
    NSColor(calibratedRed: 0.055, green: 0.13, blue: 0.18, alpha: 1).setFill()
    bg.fill()
    let board = NSBezierPath(roundedRect: NSRect(x: 205, y: 244, width: 614, height: 536), xRadius: 72, yRadius: 72)
    NSColor(calibratedRed: 0.2, green: 0.85, blue: 0.69, alpha: 1).setFill()
    board.fill()
    let screen = NSBezierPath(roundedRect: NSRect(x: 244, y: 371, width: 536, height: 368), xRadius: 37, yRadius: 37)
    NSColor(calibratedRed: 0.07, green: 0.19, blue: 0.23, alpha: 1).setFill()
    screen.fill()
    let text: NSString = "M5"
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 218, weight: .bold), .foregroundColor: NSColor.white]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024-size.width)/2, y: 418), withAttributes: attributes)
    for x in [365, 505, 645] {
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 286, width: 34, height: 34)).fill()
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon konnte nicht erzeugt werden") }
    try data.write(to: target.appendingPathComponent(name))
}
for points in [16,32,128,256,512] {
    try render(points, to: "icon_\(points)x\(points).png")
    try render(points * 2, to: "icon_\(points)x\(points)@2x.png")
}
