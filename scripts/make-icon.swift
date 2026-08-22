#!/usr/bin/env swift
//
// Draws the app icon and writes the asset catalog.
//
//   ./scripts/make-icon.swift            regenerate Sources/Resources/Assets.xcassets
//   ./scripts/make-icon.swift --icns     also write dist/OurWhisper.icns
//
// The icon is code rather than a checked-in design file for one reason: there is no designer on
// this project and no licence for one. Code can be re-rendered at a new size, recoloured, and
// reviewed in a diff, none of which a flattened PNG can. The PNGs it produces *are* committed, so
// a clone builds without running this.
//
// Each size is drawn at its own scale rather than downsampled from 1024. A 58-point stroke
// downsampled to 16 pixels turns to mush; drawn natively at 16 it stays a clean, readable shape.
//
// The mark: three arcs opening outwards from a solid core, each turned a little further than the
// last. Sound leaving a mouth, read abstractly. Deliberately not a microphone — a microphone says
// "recording", and what this app does with the recording is the interesting part.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

/// Cool plate, warm mark. The contrast is what keeps the shape legible at 16 pixels, where hue
/// differences survive and brightness differences do not.
private enum Palette {
    static let plateTop: UInt32 = 0x3A2160
    static let plateBottom: UInt32 = 0x120B22
    static let outerArc: UInt32 = 0xFF7A45
    static let innerArc: UInt32 = 0xFFB07A
    static let core: UInt32 = 0xFFF0E2
}

private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// MARK: - Drawing

/// Every measurement below is a fraction of the canvas, so one routine serves 16 pixels and 1024.
private func drawIcon(in context: CGContext, size: CGFloat) {
    let unit = size / 1024

    // macOS icons do not fill their canvas: they sit on a rounded plate with air around it, and
    // the system lines that plate up with every other icon in the Dock. 100/1024 and a corner
    // radius of 0.2237 of the side are Apple's proportions.
    let inset = 100 * unit
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = plate.width * 0.2237
    let path = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 34 * unit, color: rgb(0x000000, 0.30))
    context.addPath(path)
    context.setFillColor(rgb(Palette.plateBottom))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [rgb(Palette.plateTop), rgb(Palette.plateBottom)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }

    // A highlight down from the top edge, the way Apple's own plates catch light. Without it the
    // plate reads as flat card stock next to the icons either side of it.
    if let sheen = CGGradient(
        colorsSpace: space,
        colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.maxY - plate.height * 0.45),
            options: []
        )
    }
    context.restoreGState()

    context.saveGState()
    context.translateBy(x: size / 2, y: size / 2)
    context.setLineCap(.round)

    // Turning each arc further than the one inside it is what makes this read as spreading rather
    // than as a target or a loading spinner.
    let arcs: [(radius: CGFloat, width: CGFloat, sweep: CGFloat, turn: CGFloat, colour: UInt32)] = [
        (330, 68, .pi * 1.35, .pi * 0.60, Palette.outerArc),
        (226, 62, .pi * 1.00, .pi * 0.30, Palette.innerArc),
    ]

    for arc in arcs {
        context.saveGState()
        context.rotate(by: arc.turn)
        context.setLineWidth(arc.width * unit)
        context.setStrokeColor(rgb(arc.colour))
        context.addArc(
            center: .zero,
            radius: arc.radius * unit,
            startAngle: -arc.sweep / 2,
            endAngle: arc.sweep / 2,
            clockwise: false
        )
        context.strokePath()
        context.restoreGState()
    }

    let core = 62 * unit
    context.setFillColor(rgb(Palette.core))
    context.addEllipse(in: CGRect(x: -core, y: -core, width: core * 2, height: core * 2))
    context.fillPath()
    context.restoreGState()
}

private func render(pixels: Int) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create a \(pixels)x\(pixels) bitmap context")
    }
    drawIcon(in: context, size: CGFloat(pixels))
    guard let image = context.makeImage() else { fatalError("could not render \(pixels)x\(pixels)") }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

// MARK: - Asset catalog

/// point size and scale, which is what the catalog is indexed by; the pixel count follows.
private let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let iconSet = root
    .appendingPathComponent("Sources/Resources/Assets.xcassets/AppIcon.appiconset")

try! FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var entries: [String] = []
for variant in variants {
    let pixels = variant.points * variant.scale
    let name = "icon_\(variant.points)x\(variant.points)\(variant.scale == 2 ? "@2x" : "").png"
    writePNG(render(pixels: pixels), to: iconSet.appendingPathComponent(name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(variant.scale)x",
          "size" : "\(variant.points)x\(variant.points)"
        }
    """)
    print("  \(name)  (\(pixels)px)")
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
try! contents.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// A bare `Assets.xcassets` with only an app icon in it still needs its own Contents.json, or the
// compiler treats the directory as an unknown resource and silently ships nothing.
let catalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! catalogContents.write(
    to: root.appendingPathComponent("Sources/Resources/Assets.xcassets/Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("✓ Sources/Resources/Assets.xcassets/AppIcon.appiconset")

// MARK: - Optional .icns

// The DMG volume icon and the README screenshot want a single file rather than a catalog.
if CommandLine.arguments.contains("--icns") {
    let dist = root.appendingPathComponent("dist")
    let iconset = dist.appendingPathComponent("OurWhisper.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for variant in variants {
        let pixels = variant.points * variant.scale
        let name = "icon_\(variant.points)x\(variant.points)\(variant.scale == 2 ? "@2x" : "").png"
        writePNG(render(pixels: pixels), to: iconset.appendingPathComponent(name))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = [
        "-c", "icns", iconset.path,
        "-o", dist.appendingPathComponent("OurWhisper.icns").path,
    ]
    try! iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

    try? FileManager.default.removeItem(at: iconset)
    print("✓ dist/OurWhisper.icns")
}
