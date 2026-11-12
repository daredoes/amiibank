import AppKit

// Usage: swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// 1024px opaque app icon: coral gradient with a white NFC glyph over three "slot" bars.
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let gradient = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1.0, green: 0.45, blue: 0.28, alpha: 1),
                                                    CGColor(red: 0.85, green: 0.18, blue: 0.22, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: .zero, options: [])
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
for i in 0 ..< 3 {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 232, y: 190 + i * 92, width: 560, height: 60), cornerWidth: 30, cornerHeight: 30, transform: nil))
}
ctx.fillPath()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let config = NSImage.SymbolConfiguration(pointSize: 360, weight: .semibold).applying(.init(paletteColors: [.white]))
let glyph = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let g = glyph.size
glyph.draw(in: NSRect(x: (CGFloat(size) - g.width) / 2, y: 500, width: g.width, height: g.height))
NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
