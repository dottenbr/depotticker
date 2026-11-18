import AppKit

// Draws the app icon: a green tile with one white rising line.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// `ios` as second argument draws a full-bleed square, as iOS applies its own mask.
let fullBleed = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "ios"
let inset: CGFloat = fullBleed ? 0 : 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: tile, cornerWidth: fullBleed ? 0 : 185, cornerHeight: fullBleed ? 0 : 185, transform: nil)

ctx.saveGState()
if !fullBleed {
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
}
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let background = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.24, green: 0.86, blue: 0.47, alpha: 1).cgColor,
    NSColor(red: 0.06, green: 0.60, blue: 0.33, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// One bold rising line.
let values: [CGFloat] = [0.22, 0.52, 0.38, 0.80]
let left = tile.minX + 170, right = tile.maxX - 170
let bottom = tile.minY + 190, height = tile.height - 380
let line = CGMutablePath()
for (index, value) in values.enumerated() {
    let point = CGPoint(x: left + (right - left) * CGFloat(index) / CGFloat(values.count - 1), y: bottom + height * value)
    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
}
ctx.addPath(line)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(64)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.restoreGState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
