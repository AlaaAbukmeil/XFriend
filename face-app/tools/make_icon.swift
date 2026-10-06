// Renders the Desk Buddy app icon (the robot's eyes) and fills the asset catalog.
//   swift face-app/tools/make_icon.swift
// Output: face-app/Resources/Assets.xcassets/AppIcon.appiconset/*.png

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

let eyeColor = NSColor(red: 0.36, green: 0.88, blue: 0.95, alpha: 1)

func render(size: CGFloat) -> Data {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: 824 pt body centered in a 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Dark screen gradient, like the face app's background with a little depth.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.11, green: 0.13, blue: 0.18, alpha: 1).cgColor,
        NSColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Two eyes, same proportions as EyesView (height = 1.2 x width, corner 0.32).
    let eyeW: CGFloat = 196, eyeH: CGFloat = eyeW * 1.2, gap: CGFloat = eyeW * 0.55
    let centerY: CGFloat = 540
    for x in [512 - gap / 2 - eyeW, 512 + gap / 2] {
        let eye = CGRect(x: x, y: centerY - eyeH / 2, width: eyeW, height: eyeH)
        let path = CGPath(roundedRect: eye, cornerWidth: eyeW * 0.32, cornerHeight: eyeW * 0.32, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60, color: eyeColor.withAlphaComponent(0.8).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(eyeColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// (point size, scale) pairs required for a macOS app icon.
let macSizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (pt, scale) in macSizes {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try render(size: CGFloat(pt * scale)).write(to: iconSet.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!
    .write(to: iconSet.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(macSizes.count) icons to \(iconSet.path)")
