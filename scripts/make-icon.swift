// Renders Driveway's app icon (1024×1024 PNG) from the gradient in Packaging/Icon/gradient-source.png.
// Usage: swift scripts/make-icon.swift <gradient.png> <out.png> [charcoal|navy|white]
// The shape follows the macOS icon grid: an 824-point rounded square centred on a 1024 canvas.
import AppKit

let args = CommandLine.arguments
guard (3...4).contains(args.count), let gradient = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <gradient.png> <out.png> [charcoal|navy|white]\n".data(using: .utf8)!)
    exit(64)
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The drive's colours: its top, its darker front face, and the line between them.
struct Glyph { var top: NSColor; var face: NSColor; var seam: NSColor }
let glyphs: [String: Glyph] = [
    "charcoal": Glyph(top: rgb(0x2E2E33), face: rgb(0x222226), seam: rgb(0x46464D)),
    "navy": Glyph(top: rgb(0x1E2D4A), face: rgb(0x16223A), seam: rgb(0x34476B)),
    "white": Glyph(top: .white, face: rgb(0xF2EDE6), seam: rgb(0xF7D9B4)),
]
guard let glyph = glyphs[args.count == 4 ? args[3] : "navy"] else {
    FileHandle.standardError.write("glyph colour must be charcoal, navy or white\n".data(using: .utf8)!)
    exit(64)
}

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Soft shadow under the tile, as macOS draws for its own icons.
NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowOffset = NSSize(width: 0, height: -10)
tileShadow.shadowBlurRadius = 22
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
tileShadow.set()
NSColor(calibratedRed: 0.86, green: 0.55, blue: 0.13, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

// The gradient, scaled to cover the tile (yellow at the top, orange at the bottom).
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
let src = gradient.size
let scale = max(tile.width / src.width, tile.height / src.height)
let drawn = NSSize(width: src.width * scale, height: src.height * scale)
gradient.draw(
    in: NSRect(x: tile.midX - drawn.width / 2, y: tile.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
    from: .zero, operation: .copy, fraction: 1)
// A faint light from above.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// The drive: a dark (or white) body with a front face, a seam and an orange status light.
let body = NSRect(x: 512 - 280, y: 512 - 150, width: 560, height: 300)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 72, yRadius: 72)
NSGraphicsContext.saveGraphicsState()
let glyphShadow = NSShadow()
glyphShadow.shadowOffset = NSSize(width: 0, height: -14)
glyphShadow.shadowBlurRadius = 34
glyphShadow.shadowColor = NSColor(calibratedRed: 0.45, green: 0.18, blue: 0.0, alpha: 0.40)
glyphShadow.set()
glyph.top.setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
// The lower face, a shade darker, like the front of an external drive.
glyph.face.setFill()
NSRect(x: body.minX, y: body.minY, width: body.width, height: 118).fill()
glyph.seam.setFill()
NSRect(x: body.minX, y: body.minY + 118, width: body.width, height: 8).fill()
NSGraphicsContext.restoreGraphicsState()

let led = NSRect(x: body.maxX - 112, y: body.minY + 38, width: 44, height: 44)
rgb(0xF29A2E).setFill()
NSBezierPath(ovalIn: led).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: args[2])) } catch { print(error); exit(1) }
