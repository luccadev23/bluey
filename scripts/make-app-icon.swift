import CoreGraphics
import ImageIO
import Foundation

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Top-left origin, like the Pencil canvas.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}
func gradient(_ hexes: [UInt32], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: hexes.map { color($0) } as CFArray, locations: locs)!
}
func roundedPath(_ r: CGRect, tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat) -> CGPath {
    let p = CGMutablePath(); let k: CGFloat = 0.5523
    p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + tr), control1: CGPoint(x: r.maxX - tr * (1 - k), y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + tr * (1 - k)))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
    p.addCurve(to: CGPoint(x: r.maxX - br, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - br * (1 - k)), control2: CGPoint(x: r.maxX - br * (1 - k), y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - bl), control1: CGPoint(x: r.minX + bl * (1 - k), y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - bl * (1 - k)))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
    p.addCurve(to: CGPoint(x: r.minX + tl, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + tl * (1 - k)), control2: CGPoint(x: r.minX + tl * (1 - k), y: r.minY))
    p.closeSubpath(); return p
}

// Background: deep indigo fading to ink.
ctx.drawLinearGradient(gradient([0x2B2F8F, 0x17151F], [0, 1]), start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

let k: CGFloat = 2.1, top: CGFloat = 405, lift: CGFloat = 90
func X(_ x: CGFloat) -> CGFloat { 512 + (x - 195) * k }
func Y(_ y: CGFloat) -> CGFloat { top + (y - 300) * k }

// Body: wider than the icon, so only the dome shows and the sides are cropped, like on the phone.
let body = CGRect(x: X(-50), y: top, width: 490 * k, height: 620 * k)
ctx.saveGState()
ctx.addPath(roundedPath(body, tl: 250 * k, tr: 230 * k, br: 220 * k, bl: 240 * k)); ctx.clip()
ctx.drawLinearGradient(gradient([0xA9BCFF, 0x6C86F5, 0x4254D6, 0x2B2F8F], [0, 0.34, 0.68, 1]),
                       start: CGPoint(x: body.minX + 0.25 * body.width, y: body.minY + 0.067 * body.height),
                       end: CGPoint(x: body.minX + 0.75 * body.width, y: body.minY + 0.933 * body.height),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Soft shine on the top-left of his head, plus the glossy sparkle.
ctx.drawRadialGradient(CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.5), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                       startCenter: CGPoint(x: body.minX + 147 * k, y: body.minY + 75 * k), startRadius: 0,
                       endCenter: CGPoint(x: body.minX + 147 * k, y: body.minY + 75 * k), endRadius: 146 * k, options: [])
ctx.restoreGState()

// Eyes.
for cx in [120.0, 270.0] {
    let ex = X(CGFloat(cx)), ey = Y(474) - lift
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: ex - 62 * k, y: ey - 54 * k, width: 124 * k, height: 108 * k))
    let r = 30 * k, px = ex + 10, py = ey + 8
    ctx.setFillColor(color(0x17151F))
    ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: px - 0.58 * r, y: py - 0.72 * r, width: 0.56 * r, height: 0.56 * r))
}

// Mouth: a half-moon, tilted a little.
let mw = 74 * k, mh = 36 * k
let mc = CGPoint(x: X(158) + mw / 2, y: Y(584) - lift + mh / 2)
ctx.saveGState()
ctx.translateBy(x: mc.x, y: mc.y); ctx.rotate(by: 3 * .pi / 180)
ctx.addPath(roundedPath(CGRect(x: -mw / 2, y: -mh / 2, width: mw, height: mh), tl: 8, tr: 8, br: min(mw / 2, mh), bl: min(mw / 2, mh)))
ctx.setFillColor(color(0x1C1F66)); ctx.fillPath()
ctx.restoreGState()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote", out.path)
