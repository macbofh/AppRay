#!/usr/bin/env swift

// Draws the app icon and fills Resources/Assets.xcassets/AppIcon.appiconset.
//
// The mark is drawn from scratch rather than composed from SF Symbols, because
// the SF Symbols licence does not allow their use in app icons.
//
//   swift scripts/generate_icon.swift

import AppKit
import Foundation

let sizes: [(dimension: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

/// Apple's macOS icon grid: an 824pt mark on a 1024pt canvas.
func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: CGSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    let unit = side / 1_024
    let inset = 100 * unit
    let plate = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

    NSGraphicsContext.current?.imageInterpolation = .high

    // Plate
    let plateShape = NSBezierPath(roundedRect: plate, xRadius: 185 * unit, yRadius: 185 * unit)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.30, green: 0.36, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.44, green: 0.25, blue: 0.78, alpha: 1),
    ])
    gradient?.draw(in: plateShape, angle: -90)

    // Shield
    let shieldWidth = 430 * unit
    let shieldHeight = 520 * unit
    let centre = CGPoint(x: side / 2, y: side / 2 + 12 * unit)
    let top = centre.y + shieldHeight / 2
    let bottom = centre.y - shieldHeight / 2
    let left = centre.x - shieldWidth / 2
    let right = centre.x + shieldWidth / 2
    let shoulder = top - shieldHeight * 0.34

    let shield = NSBezierPath()
    shield.move(to: CGPoint(x: centre.x, y: top))
    shield.line(to: CGPoint(x: right, y: top - shieldHeight * 0.16))
    shield.line(to: CGPoint(x: right, y: shoulder))
    shield.curve(
        to: CGPoint(x: centre.x, y: bottom),
        controlPoint1: CGPoint(x: right, y: bottom + shieldHeight * 0.22),
        controlPoint2: CGPoint(x: centre.x + shieldWidth * 0.30, y: bottom)
    )
    shield.curve(
        to: CGPoint(x: left, y: shoulder),
        controlPoint1: CGPoint(x: centre.x - shieldWidth * 0.30, y: bottom),
        controlPoint2: CGPoint(x: left, y: bottom + shieldHeight * 0.22)
    )
    shield.line(to: CGPoint(x: left, y: top - shieldHeight * 0.16))
    shield.close()

    NSColor.white.withAlphaComponent(0.96).setFill()
    shield.fill()

    // Keyhole: what the app is really about — who is allowed through.
    let keyRadius = 62 * unit
    let keyCentre = CGPoint(x: centre.x, y: centre.y + 46 * unit)
    let hole = NSBezierPath(
        ovalIn: CGRect(
            x: keyCentre.x - keyRadius,
            y: keyCentre.y - keyRadius,
            width: keyRadius * 2,
            height: keyRadius * 2
        )
    )
    let stemWidth = 54 * unit
    let stem = NSBezierPath(
        roundedRect: CGRect(
            x: keyCentre.x - stemWidth / 2,
            y: keyCentre.y - 176 * unit,
            width: stemWidth,
            height: 176 * unit
        ),
        xRadius: stemWidth / 2,
        yRadius: stemWidth / 2
    )
    hole.append(stem)

    NSGraphicsContext.current?.compositingOperation = .destinationOut
    NSColor.black.setFill()
    hole.fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver

    return image
}

func png(of image: NSImage, pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root.appending(path: "Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var entries: [String] = []
for (dimension, scale) in sizes {
    let pixels = dimension * scale
    let name = scale == 1 ? "icon_\(dimension)x\(dimension).png" : "icon_\(dimension)x\(dimension)@2x.png"
    guard let data = png(of: drawIcon(side: CGFloat(pixels)), pixels: pixels) else {
        fatalError("Could not render \(name)")
    }
    try data.write(to: iconSet.appending(path: name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(dimension)x\(dimension)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: iconSet.appending(path: "Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("Wrote \(sizes.count) icons to \(iconSet.path)")
