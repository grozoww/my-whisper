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
// Each size is drawn at its own scale rather than downsampled from 1024, and below 32 pixels a
// simplified drawing is used instead: fewer strokes, heavier lines, no nostrils. A 16-point line
// downsampled to 16 pixels turns to mush; drawn natively at 16 it stays a shape.
//
// The mark: a frog's face, flat and hand-inked, whose mouth is one unbroken stroke that starts as
// a wave on the left and settles into a straight line on the right — speech going in ragged, text
// coming out clean. Deliberately not a microphone. A microphone says "recording", and what this
// app does with the recording is the interesting part. The frog is the one who listens.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

/// Cool plate, warm face. The gradient runs teal to sage across the diagonal so the olive head has
/// something to sit against at both ends; a flat background left the chin edge invisible.
private enum Palette {
    static let plate: [UInt32] = [0x33707E, 0x6C9E88, 0x9CC4A4, 0xB4D2B0]
    static let plateStops: [CGFloat] = [0, 0.42, 0.78, 1]
    static let skin: UInt32 = 0x8F9E60
    static let eye: UInt32 = 0xF5F1DC
    static let ink: UInt32 = 0x15150F
}

private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// MARK: - Geometry

/// One face, at two levels of detail. Coordinates are in a 1024 square with the origin at the top
/// left, which is how the drawing was laid out; `drawIcon` flips the context to match.
private struct Face {
    struct Curve {
        let to: CGPoint
        let c1: CGPoint
        let c2: CGPoint
    }

    let headStart: CGPoint
    let head: [Curve]
    let eyeCentres: [CGPoint]
    let eyeRadius: CGFloat
    let pupilCentres: [CGPoint]
    let pupilRadius: CGFloat
    let nostrils: [(start: CGPoint, curve: Curve)]
    let mouthStart: CGPoint
    let mouthCurves: [Curve]
    let mouthEnd: CGPoint
    let headLine: CGFloat
    let eyeLine: CGFloat
    let nostrilLine: CGFloat
    let mouthLine: CGFloat
}

private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func curve(_ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat, _ x: CGFloat, _ y: CGFloat) -> Face.Curve {
    Face.Curve(to: point(x, y), c1: point(c1x, c1y), c2: point(c2x, c2y))
}

private let detailed = Face(
    headStart: point(138, 596),
    head: [
        curve(138, 486, 178, 414, 246, 372),
        curve(250, 300, 292, 254, 336, 254),
        curve(384, 254, 424, 302, 428, 368),
        curve(484, 352, 540, 352, 596, 368),
        curve(600, 302, 640, 254, 688, 254),
        curve(732, 254, 774, 300, 778, 372),
        curve(846, 414, 886, 486, 886, 596),
        curve(886, 730, 730, 826, 512, 826),
        curve(294, 826, 138, 730, 138, 596),
    ],
    eyeCentres: [point(336, 326), point(688, 326)],
    eyeRadius: 92,
    pupilCentres: [point(336, 330), point(688, 330)],
    pupilRadius: 31,
    nostrils: [
        (point(478, 470), curve(486, 480, 488, 492, 486, 500)),
        (point(550, 470), curve(542, 480, 540, 492, 542, 500)),
    ],
    mouthStart: point(186, 612),
    mouthCurves: [
        curve(204, 546, 232, 544, 246, 606),
        curve(258, 660, 288, 662, 300, 608),
        curve(310, 566, 334, 564, 344, 604),
        curve(350, 630, 370, 632, 384, 616),
    ],
    mouthEnd: point(842, 616),
    headLine: 19,
    eyeLine: 17,
    nostrilLine: 13,
    mouthLine: 16
)

/// Below 32 pixels the four-bend mouth closes up into a smear and the nostrils land on the same
/// pixel as the eyes, so the small sizes get their own drawing: two bends, no nostrils, and lines
/// heavy enough to survive rasterisation.
private let simplified = Face(
    headStart: point(150, 596),
    head: [
        curve(150, 480, 196, 404, 262, 366),
        curve(268, 292, 310, 250, 352, 250),
        curve(398, 250, 434, 300, 438, 366),
        curve(488, 352, 536, 352, 586, 366),
        curve(590, 300, 626, 250, 672, 250),
        curve(714, 250, 756, 292, 762, 366),
        curve(828, 404, 874, 480, 874, 596),
        curve(874, 726, 726, 818, 512, 818),
        curve(298, 818, 150, 726, 150, 596),
    ],
    eyeCentres: [point(352, 322), point(672, 322)],
    eyeRadius: 94,
    pupilCentres: [point(352, 326), point(672, 326)],
    pupilRadius: 38,
    nostrils: [],
    mouthStart: point(214, 616),
    mouthCurves: [
        curve(238, 540, 274, 540, 292, 612),
        curve(306, 664, 340, 664, 356, 618),
    ],
    mouthEnd: point(822, 618),
    headLine: 34,
    eyeLine: 30,
    nostrilLine: 0,
    mouthLine: 32
)

// MARK: - Drawing

/// Every measurement below is a fraction of the canvas, so one routine serves 16 pixels and 1024.
private func drawIcon(in context: CGContext, size: CGFloat) {
    let unit = size / 1024
    let face = size <= 32 ? simplified : detailed

    func at(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * unit, y: p.y * unit) }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons do not fill their canvas: they sit on a rounded plate with air around it, and
    // the system lines that plate up with every other icon in the Dock. 100/1024 and a corner
    // radius of 0.2237 of the side are Apple's proportions.
    let inset = 100 * unit
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = plate.width * 0.2237
    let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 34 * unit, color: rgb(0x000000, 0.30))
    context.addPath(platePath)
    context.setFillColor(rgb(Palette.plate[0]))
    context.fillPath()
    context.restoreGState()

    // Drawn top-left down, the way the geometry above was laid out. Everything after this point is
    // in that flipped space, including the gradient.
    context.saveGState()
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: Palette.plate.map { rgb($0) } as CFArray,
        locations: Palette.plateStops
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.minY),
            end: CGPoint(x: plate.maxX, y: plate.maxY),
            options: []
        )
    }
    context.restoreGState()

    context.setLineCap(.round)
    context.setLineJoin(.round)

    let head = CGMutablePath()
    head.move(to: at(face.headStart))
    for c in face.head {
        head.addCurve(to: at(c.to), control1: at(c.c1), control2: at(c.c2))
    }
    head.closeSubpath()

    context.addPath(head)
    context.setFillColor(rgb(Palette.skin))
    context.fillPath()
    context.addPath(head)
    context.setStrokeColor(rgb(Palette.ink))
    context.setLineWidth(face.headLine * unit)
    context.strokePath()

    for centre in face.eyeCentres {
        let c = at(centre)
        let r = face.eyeRadius * unit
        let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        context.addEllipse(in: box)
        context.setFillColor(rgb(Palette.eye))
        context.fillPath()
        context.addEllipse(in: box)
        context.setLineWidth(face.eyeLine * unit)
        context.strokePath()
    }

    context.setFillColor(rgb(Palette.ink))
    for centre in face.pupilCentres {
        let c = at(centre)
        let r = face.pupilRadius * unit
        context.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        context.fillPath()
    }

    context.setStrokeColor(rgb(Palette.ink))
    context.setLineWidth(face.nostrilLine * unit)
    for nostril in face.nostrils {
        let path = CGMutablePath()
        path.move(to: at(nostril.start))
        path.addCurve(to: at(nostril.curve.to), control1: at(nostril.curve.c1), control2: at(nostril.curve.c2))
        context.addPath(path)
        context.strokePath()
    }

    // One stroke, wave to line. Drawing it as two paths would put a visible join where the wave
    // settles, which is exactly the moment the mark is about.
    let mouth = CGMutablePath()
    mouth.move(to: at(face.mouthStart))
    for c in face.mouthCurves {
        mouth.addCurve(to: at(c.to), control1: at(c.c1), control2: at(c.c2))
    }
    mouth.addLine(to: at(face.mouthEnd))
    context.addPath(mouth)
    context.setLineWidth(face.mouthLine * unit)
    context.strokePath()

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
