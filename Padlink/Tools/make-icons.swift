#!/usr/bin/env swift
// Draws Padlink's app icons and writes every size both platforms need.
//
// Icons are generated rather than committed as hand-made art so that a colour
// or shape change is a one-line edit and a rerun, not a round trip through an
// image editor. Run from the `Padlink` directory:
//
//     swift Tools/make-icons.swift
//
// The design: a rounded surface (the iPad, the thing you touch) with a pointer
// sitting on it (the Mac, the thing that moves). That is the whole product in
// one picture, and it survives being shrunk to 16 points, which a literal
// drawing of two devices would not.

import AppKit
import Foundation

// MARK: - Palette

// Indigo to blue. Dark enough that the white glyph holds its contrast on a
// light desktop, saturated enough not to look grey in the Dock.
let topColor = CGColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1)
let bottomColor = CGColor(red: 0.16, green: 0.44, blue: 0.90, alpha: 1)

// MARK: - Drawing

/// Draws the icon into a bitmap of `size` points square.
///
/// `fullBleed` is the one real difference between the platforms. iOS masks the
/// icon itself, so the artwork must fill the square edge to edge or the system
/// mask will cut a rounded rectangle out of an already rounded one. macOS does
/// no masking, so the icon has to draw its own rounded rectangle, inset to
/// leave the margin every other Dock icon has.
func drawIcon(size: CGFloat, fullBleed: Bool) -> CGImage {
    let scale: CGFloat = 1
    let pixels = Int(size * scale)
    let space = CGColorSpaceCreateDeviceRGB()
    // No alpha channel for iOS. App Store submission rejects an icon that has
    // one, even when every pixel in it is fully opaque, so it is the presence
    // of the channel that matters and not the contents. macOS needs alpha,
    // because the corners outside its rounded plate really are transparent.
    let alpha: CGImageAlphaInfo = fullBleed ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: alpha.rawValue
    )!

    // A context without alpha starts black, which would show through anywhere
    // the plate does not cover. It covers everything at full bleed, but that is
    // a fact about today's design, not a guarantee.
    if fullBleed {
        ctx.setFillColor(bottomColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The plate: the coloured shape everything else sits on.
    //
    // iOS gets a plain square with square corners. The system rounds and masks
    // it at display time, so rounding it here would round it twice, and iOS
    // rejects an icon with any transparency at all, which is what the corners
    // outside a rounded path would be.
    let inset: CGFloat = fullBleed ? 0 : size * 0.085
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // 22.37% of the width is Apple's continuous-corner ratio. A plain rounded
    // rect is close enough at icon sizes and needs no bezier by hand.
    let radius = fullBleed ? 0 : plate.width * 0.2237
    let platePath = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    )!
    // Top-left to bottom-right, so the light reads as coming from above.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    ctx.restoreGState()

    // The surface: a rounded outline standing for the trackpad area.
    //
    // Drawn as a stroke rather than a fill so the gradient stays visible
    // through it. At 16 points the stroke is under a pixel and effectively
    // disappears, which is intended: the pointer alone still reads.
    let padInset = plate.width * 0.20
    let pad = plate.insetBy(dx: padInset, dy: padInset * 1.12)
    let padRadius = pad.height * 0.16
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
    ctx.setLineWidth(max(1, plate.width * 0.035))
    ctx.addPath(CGPath(
        roundedRect: pad, cornerWidth: padRadius, cornerHeight: padRadius, transform: nil
    ))
    ctx.strokePath()
    ctx.restoreGState()

    // The pointer, drawn from a unit path so it scales exactly.
    //
    // Sits inside the surface rather than crossing its edge. Crossing would say
    // more about what the app does, but it costs legibility at 16 points, where
    // the outline is already under a pixel wide and a glyph broken across it
    // reads as noise. The small sizes are the ones seen most often.
    let arrow: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.00),
        CGPoint(x: 0.00, y: 0.74),
        CGPoint(x: 0.20, y: 0.56),
        CGPoint(x: 0.32, y: 0.86),
        CGPoint(x: 0.46, y: 0.80),
        CGPoint(x: 0.33, y: 0.51),
        CGPoint(x: 0.58, y: 0.49),
    ]
    let arrowHeight = plate.height * 0.50
    let arrowWidth = arrowHeight * 0.58
    // The tip starts inside the surface and the tail runs out past its
    // bottom-right corner, so the pointer visibly crosses the edge.
    let originX = plate.midX - arrowWidth * 0.02
    let originY = plate.midY + arrowHeight * 0.42

    let path = CGMutablePath()
    for (index, point) in arrow.enumerated() {
        // The unit path is measured with y running down, the way a pointer is
        // normally described. CoreGraphics runs y up, hence the subtraction.
        let p = CGPoint(x: originX + point.x * arrowWidth, y: originY - point.y * arrowHeight)
        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()

    // A soft shadow lifts the pointer off the surface. Skipped below 64 points:
    // at that scale the blur is wider than the glyph and only muddies it.
    ctx.saveGState()
    if size >= 64 {
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.012),
            blur: size * 0.03,
            color: CGColor(gray: 0, alpha: 0.35)
        )
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Writing

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icons", code: 1)
    }
    try data.write(to: url)
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)

/// macOS wants every size as its own file. iOS takes a single 1024 and resizes.
let macSizes: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

// MARK: macOS

let macIcon = root.appendingPathComponent("PadlinkMac/Assets.xcassets/AppIcon.appiconset")
try fm.createDirectory(at: macIcon, withIntermediateDirectories: true)

var macEntries: [[String: String]] = []
for (points, scale) in macSizes {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try write(drawIcon(size: CGFloat(pixels), fullBleed: false), to: macIcon.appendingPathComponent(name))
    macEntries.append([
        "size": "\(points)x\(points)",
        "idiom": "mac",
        "filename": name,
        "scale": "\(scale)x",
    ])
}

// MARK: iOS

let padIcon = root.appendingPathComponent("PadlinkPad/Assets.xcassets/AppIcon.appiconset")
try fm.createDirectory(at: padIcon, withIntermediateDirectories: true)
try write(drawIcon(size: 1024, fullBleed: true), to: padIcon.appendingPathComponent("icon_1024.png"))

// MARK: Contents.json

func contents(_ images: [[String: String]]) throws -> Data {
    let payload: [String: Any] = [
        "images": images,
        "info": ["version": 1, "author": "make-icons.swift"],
    ]
    return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
}

try contents(macEntries).write(to: macIcon.appendingPathComponent("Contents.json"))
try contents([[
    "filename": "icon_1024.png",
    "idiom": "universal",
    "platform": "ios",
    "size": "1024x1024",
]]).write(to: padIcon.appendingPathComponent("Contents.json"))

// An asset catalog with no top-level Contents.json still compiles, but Xcode
// treats it as untracked and will rewrite it on first open. Writing it here
// keeps the generated tree stable.
let catalogInfo = try JSONSerialization.data(
    withJSONObject: ["info": ["version": 1, "author": "make-icons.swift"]],
    options: [.prettyPrinted, .sortedKeys]
)
for catalog in ["PadlinkMac/Assets.xcassets", "PadlinkPad/Assets.xcassets"] {
    try catalogInfo.write(to: root.appendingPathComponent(catalog + "/Contents.json"))
}

print("Wrote \(macSizes.count) macOS icons and 1 iOS icon.")
