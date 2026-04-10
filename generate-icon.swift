// SPDX-License-Identifier: MIT
import AppKit

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let driveW = s * 0.64, driveH = s * 0.40
    let driveX = (s - driveW) / 2, driveY = s * 0.18
    let radius = s * 0.06

    let drivePath = CGPath(roundedRect: CGRect(x: driveX, y: driveY, width: driveW, height: driveH),
                           cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.04, color: CGColor(gray: 0, alpha: 0.3))
    ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
    ctx.addPath(drivePath); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(drivePath); ctx.clip()
    let colors = [CGColor(gray: 0.45, alpha: 1), CGColor(gray: 0.30, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: s/2, y: driveY + driveH), end: CGPoint(x: s/2, y: driveY), options: [])
    ctx.restoreGState()

    ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 1)); ctx.setLineWidth(s * 0.012)
    ctx.addPath(drivePath); ctx.strokePath()

    let ledR = s * 0.03
    ctx.setFillColor(CGColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: driveX + driveW - s * 0.10 - ledR, y: driveY + s * 0.08 - ledR, width: ledR * 2, height: ledR * 2))

    let centerX = s / 2, signalY = driveY + driveH + s * 0.08
    ctx.setLineCap(.round)
    for i in 0..<3 {
        let r = s * 0.06 + CGFloat(i) * s * 0.065
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1.0 - CGFloat(i) * 0.25))
        ctx.setLineWidth(s * 0.025)
        ctx.addArc(center: CGPoint(x: centerX, y: signalY), radius: r, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }
    let dotR = s * 0.025
    ctx.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: centerX - dotR, y: signalY - dotR, width: dotR * 2, height: dotR * 2))

    image.unlockFocus()
    return image
}

let iconsetPath = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
] as [(String, CGFloat)] {
    let img = renderIcon(size: size)
    guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
          let png = bmp.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name).png"))
}
