import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, alpha: 1)
}

func bubble(_ ctx: CGContext, _ r: CGRect, _ hex: UInt32) {
    ctx.setFillColor(color(hex))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 78, cornerHeight: 78, transform: nil))
    ctx.fillPath()
    ctx.move(to: CGPoint(x: r.minX + 71, y: r.minY + 32)); ctx.addLine(to: CGPoint(x: r.minX + 65, y: r.minY - 53))
    ctx.addQuadCurve(to: CGPoint(x: r.minX + 154, y: r.minY + 23), control: CGPoint(x: r.minX + 67, y: r.minY - 64))
    ctx.closePath(); ctx.fillPath()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let n = size * scale
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(n) / 1024, y: CGFloat(n) / 1024)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 207, cornerHeight: 207, transform: nil))
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(0x275c61), color(0x122e43)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 246, y: 942), end: CGPoint(x: 780, y: 85), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
        bubble(ctx, CGRect(x: 414, y: 291, width: 397, height: 256), 0x87cec3)
        bubble(ctx, CGRect(x: 218, y: 448, width: 412, height: 294), 0xf2fcf8)
        ctx.setFillColor(color(0x275c61))
        for x in [332, 408, 484] { ctx.fillEllipse(in: CGRect(x: x, y: 572, width: 39, height: 39)) }
        let bitmap = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
