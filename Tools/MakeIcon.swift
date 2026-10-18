// Renders the app icon (1024×1024 PNG) with CoreGraphics. Usage: MakeIcon out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-square background with a warm gradient (macOS icon grid: 824pt body, 100pt inset).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(path)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 1.00, green: 0.78, blue: 0.30, alpha: 1).cgColor,
    NSColor(red: 0.96, green: 0.45, blue: 0.22, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// White page with text lines, one highlighted, plus sound waves.
let page = CGRect(x: 250, y: 230, width: 400, height: 540)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(CGPath(roundedRect: page, cornerWidth: 36, cornerHeight: 36, transform: nil))
ctx.fillPath()
for i in 0..<7 {
    let y = page.maxY - 95 - CGFloat(i) * 62
    let width: CGFloat = i == 6 ? 190 : 300
    if i == 3 {
        ctx.setFillColor(NSColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1).cgColor)
        ctx.fill(CGRect(x: page.minX + 40, y: y - 14, width: 320, height: 50))
    }
    ctx.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: page.minX + 50, y: y, width: width, height: 22),
                       cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.fillPath()
}
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineCap(.round)
for (i, radius) in [70.0, 130.0, 190.0].enumerated() {
    ctx.setLineWidth(38 - CGFloat(i) * 4)
    ctx.addArc(center: CGPoint(x: 640, y: 500), radius: radius, startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
    ctx.strokePath()
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
