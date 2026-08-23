#!/usr/bin/env swift
//
// Draws the app icon and writes the asset catalog.
//
//   ./scripts/make-icon.swift            regenerate Sources/Resources/Assets.xcassets
//                                        and docs/images/icon.png, which the README opens with
//   ./scripts/make-icon.swift --icns     also write dist/OurWhisper.icns
//
// Two marks come out of this, the app icon and the menu bar glyph, and they are here together
// because they are the same frog and have to stay the same frog.
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
// a wave on the left and settles, over the whole right half, into a line — speech going in ragged,
// text coming out clean. Deliberately not a microphone. A microphone says "recording", and what this
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
    let headLine: CGFloat
    let eyeLine: CGFloat
    let nostrilLine: CGFloat
    let mouthLine: CGFloat
}

private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func curve(_ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat, _ x: CGFloat, _ y: CGFloat) -> Face.Curve {
    Face.Curve(to: point(x, y), c1: point(c1x, c1y), c2: point(c2x, c2y))
}

/// The mouth: a wave that swells, fades, and runs out into a long, almost level line.
///
/// It is one function of x sampled into cubics, not a run of hand-placed arcs, and that is the
/// whole point of it. Every earlier version chained one cubic per lobe, and two neighbouring cubics
/// only meet smoothly when their amplitudes and widths are in the same ratio — which a wave whose
/// entire subject is *changing* amplitude can never satisfy. So there was a small corner at every
/// zero crossing, and the one where the wave met the straight line was merely the worst of them,
/// because the line's slope was zero and the last lobe's was not. Fixing that one join by hand only
/// moved the problem along; the shape had to stop being a chain.
///
/// A sampled function has no joins to match. `curves` walks the mouth, takes the slope at each
/// sample, and hands the *same* slope to the segment on either side of it, so the stroke is smooth
/// by construction from the left cheek to the right. Wave, fade and flat run are one curve.
private struct Mouth {
    /// Left cheek to right cheek. Every face currently gives both the same height, so the line
    /// finishes exactly where the wave set out and the mouth reads level across the face. The two
    /// are kept separate anyway because they were not always equal: an earlier mouth needed a degree
    /// of lift to stop a dead-level line reading as a second stroke butted onto the wave, and that
    /// is a real hazard whenever the fade is not smooth. This one's is, so it does not need the
    /// trick. If a height ever differs again, the centre line *eases* between the two rather than
    /// tilting — the stroke leaves one cheek and arrives at the other level, with the angle in the
    /// middle where the wave is not.
    let start: CGPoint
    let end: CGPoint

    /// The tallest crest, measured off the centre line.
    let amplitude: CGFloat

    /// Full waves before the envelope closes — two lobes to a cycle.
    let cycles: CGFloat

    /// How much of the mouth the wave gets before it has faded to nothing. The rest is the line.
    let span: CGFloat

    /// The envelope, `t^onset * (1 - t)^decay` normalised to peak at 1. `onset` under 1 brings the
    /// first crest in already half grown; over 1 starts it smaller and peaks later. `decay` above 2
    /// lands the fade with its slope *and* its bend already at zero, which is what lets the wave
    /// disappear into the line rather than stop at it.
    let onset: CGFloat
    let decay: CGFloat
}

extension Mouth {
    private var envelopePeak: CGFloat {
        let t = onset / (onset + decay)
        return pow(t, onset) * pow(1 - t, decay)
    }

    /// The height of the stroke a fraction `u` of the way along the mouth.
    private func height(at u: CGFloat) -> CGFloat {
        let centre = start.y + (end.y - start.y) * (u * u * (3 - 2 * u))
        guard u < span else { return centre }
        let t = u / span
        let envelope = pow(t, onset) * pow(1 - t, decay) / envelopePeak
        return centre - amplitude * envelope * sin(2 * .pi * cycles * t)
    }

    /// Seven or so cubics to a lobe, which is well past the point of being able to see the
    /// difference between this and the sine it is standing in for.
    private var segments: Int { 96 }

    var curves: [Face.Curve] {
        let width = end.x - start.x

        // One slope per sample, shared by the segment on each side of it. That sharing is the
        // smoothness: whatever this returns, the two cubics meeting here leave and arrive along the
        // same line. Reading it off the curve either side rather than differentiating by hand keeps
        // it honest when the envelope changes.
        func slope(at u: CGFloat) -> CGFloat {
            let step: CGFloat = 0.0005
            let low = max(0, u - step), high = min(1, u + step)
            return (height(at: high) - height(at: low)) / ((high - low) * width)
        }

        var curves: [Face.Curve] = []
        var from = start
        var fromSlope = slope(at: 0)
        for step in 1...segments {
            let u = CGFloat(step) / CGFloat(segments)
            let to = point(start.x + width * u, height(at: u))
            let toSlope = slope(at: u)
            let handle = (to.x - from.x) / 3
            curves.append(curve(
                from.x + handle, from.y + fromSlope * handle,
                to.x - handle, to.y - toSlope * handle,
                to.x, to.y
            ))
            from = to
            fromSlope = toSlope
        }
        return curves
    }
}

/// Small, then the tallest at the third lobe, then down to nothing by x 566 — the wave is visibly
/// over by the time it passes under the nose, and gone before the right nostril. Raising `cycles`
/// or `span` on their own crowds or stretches the lobes; they move together.
private let detailedMouth = Mouth(
    start: point(186, 614),
    end: point(842, 614),
    amplitude: 66,
    cycles: 4,
    span: 0.58,
    onset: 0.9,
    decay: 2.3
)

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
    mouthStart: detailedMouth.start,
    mouthCurves: detailedMouth.curves,
    headLine: 19,
    eyeLine: 17,
    nostrilLine: 13,
    mouthLine: 16
)

/// Below 32 pixels the detailed mouth closes up into a smear and the nostrils land on the same
/// pixel as the eyes, so the small sizes get their own drawing: half the cycles over a shorter span,
/// no nostrils, and lines heavy enough to survive rasterisation. Two cycles is what fits — at 32
/// pixels a lobe of the detailed wave is a pixel and a half wide, and a wave you cannot count the
/// lobes of is just a thick line.
private let simplifiedMouth = Mouth(
    start: point(214, 616),
    end: point(822, 616),
    amplitude: 80,
    cycles: 2,
    span: 0.42,
    onset: 1,
    decay: 2.3
)

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
    mouthStart: simplifiedMouth.start,
    mouthCurves: simplifiedMouth.curves,
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

    // One stroke, wave to line — see `Mouth`, which is why there is nothing here to special-case.
    let mouth = CGMutablePath()
    mouth.move(to: at(face.mouthStart))
    for c in face.mouthCurves {
        mouth.addCurve(to: at(c.to), control1: at(c.c1), control2: at(c.c2))
    }
    context.addPath(mouth)
    context.setLineWidth(face.mouthLine * unit)
    context.strokePath()

    context.restoreGState()
}

// MARK: - Menu bar glyph

/// Everything the glyph puts on the canvas, in 1024 space, including the outer half of every
/// stroke. The menu bar drawing is fitted to its canvas rather than laid out in it, and a fit
/// that measured the centre line would clip the outside of the head by half a line.
extension Face {
    var bounds: CGRect {
        let path = CGMutablePath()
        path.move(to: headStart)
        for c in head { path.addCurve(to: c.to, control1: c.c1, control2: c.c2) }
        var box = path.boundingBoxOfPath.insetBy(dx: -headLine / 2, dy: -headLine / 2)
        for centre in eyeCentres {
            let r = eyeRadius + eyeLine / 2
            box = box.union(CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
        }
        return box
    }
}

/// The menu bar mark: the same face, drawn as an outline with nothing filled in.
///
/// It is a *template* image, which is the whole reason there is one drawing and not two. macOS
/// keeps only the alpha channel of a template and paints the shape itself — dark on a light menu
/// bar, light on a dark one, inverted again while the menu is open, and correct under Increase
/// Contrast. A checked-in light PNG and dark PNG would get all four of those wrong, and the first
/// one worst: the menu bar's appearance follows the desktop picture, not the appearance setting
/// in System Settings, so a dark wallpaper under Light Mode would take the light artwork and
/// disappear into the bar.
///
/// The shape is `simplified`'s, so the two marks read as the same animal. The line weights are
/// not, and cannot be: 34/1024 is a confident stroke at 512 pixels and a third of a pixel at 18,
/// which the rasteriser renders as grey haze. These land near 1.4 pixels at 18 and 2.8 at 36.
private let menuBarMouth = Mouth(
    start: point(206, 620),
    end: point(830, 620),
    amplitude: 84,
    cycles: 2,
    span: 0.44,
    onset: 1,
    decay: 2.3
)

private let menuBarFace = Face(
    headStart: simplified.headStart,
    head: simplified.head,
    eyeCentres: simplified.eyeCentres,
    eyeRadius: 96,
    pupilCentres: simplified.pupilCentres,
    pupilRadius: 30,
    nostrils: [],
    mouthStart: menuBarMouth.start,
    mouthCurves: menuBarMouth.curves,
    headLine: 62,
    eyeLine: 46,
    nostrilLine: 0,
    mouthLine: 52
)

/// At 18 pixels the whole face is fourteen pixels tall. An eye becomes a four-pixel ring with a
/// one-pixel hole, which rasterises to a grey blob, and four lobes of mouth land inside four pixels.
/// So the unscaled menu bar gets solid eyes and a single cycle — the same trade the icon makes
/// below 32 pixels, one size further down. One cycle rather than none because the envelope still
/// has to open and close for the wave to fade rather than stop, and at this size the second lobe is
/// a quarter of the first and shows as little more than the angle the line leaves at.
private let menuBarSmallMouth = Mouth(
    start: point(214, 628),
    end: point(822, 628),
    amplitude: 88,
    cycles: 1,
    span: 0.32,
    onset: 1,
    decay: 2.3
)

private let menuBarSmallFace = Face(
    headStart: simplified.headStart,
    head: simplified.head,
    eyeCentres: simplified.eyeCentres,
    eyeRadius: 46,
    pupilCentres: [point(352, 340), point(672, 340)],
    pupilRadius: 46,
    nostrils: [],
    mouthStart: menuBarSmallMouth.start,
    mouthCurves: menuBarSmallMouth.curves,
    headLine: 44,
    eyeLine: 0,
    nostrilLine: 0,
    mouthLine: 38
)

/// Black on nothing. A template's colour is never used, but the alpha is, so anti-aliased edges
/// have to come from the shape rather than from a grey fill.
private func drawMenuBarGlyph(in context: CGContext, size: CGFloat) {
    let face = size <= 18 ? menuBarSmallFace : menuBarFace
    let box = face.bounds

    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Fitted, not inset. The frog is half again as wide as it is tall, so drawing it to the
    // icon's proportions would leave a third of an 18-point square empty and the mark would read
    // smaller than every SF Symbol beside it.
    let scale = min(size / box.width, size / box.height)
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(
        x: (size - box.width * scale) / 2,
        y: (size - box.height * scale) / 2
    )
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)

    context.setStrokeColor(rgb(Palette.ink))
    context.setFillColor(rgb(Palette.ink))

    let head = CGMutablePath()
    head.move(to: face.headStart)
    for c in face.head { head.addCurve(to: c.to, control1: c.c1, control2: c.c2) }
    head.closeSubpath()
    context.addPath(head)
    context.setLineWidth(face.headLine)
    context.strokePath()

    // A ring where there is room for a hole, a dot where there is not.
    for (centre, pupil) in zip(face.eyeCentres, face.pupilCentres) {
        if face.eyeLine > 0 {
            let r = face.eyeRadius
            context.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            context.setLineWidth(face.eyeLine)
            context.strokePath()
        }
        let r = face.pupilRadius
        context.addEllipse(in: CGRect(x: pupil.x - r, y: pupil.y - r, width: r * 2, height: r * 2))
        context.fillPath()
    }

    let mouth = CGMutablePath()
    mouth.move(to: face.mouthStart)
    for c in face.mouthCurves { mouth.addCurve(to: c.to, control1: c.c1, control2: c.c2) }
    context.addPath(mouth)
    context.setLineWidth(face.mouthLine)
    context.strokePath()
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

private func renderMenuBar(pixels: Int) -> CGImage {
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
    drawMenuBarGlyph(in: context, size: CGFloat(pixels))
    guard let image = context.makeImage() else { fatalError("could not render the menu bar glyph at \(pixels)") }
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

// MARK: - Menu bar image set

// 18 points is what a status item is given, and macOS has no 3x display, so this is the whole set.
// `template-rendering-intent` is the load-bearing line: without it the artwork ships as literal
// black pixels and vanishes on a dark menu bar.
private let menuBarSet = root
    .appendingPathComponent("Sources/Resources/Assets.xcassets/MenuBarIcon.imageset")
try! FileManager.default.createDirectory(at: menuBarSet, withIntermediateDirectories: true)

var menuBarEntries: [String] = []
for scale in [1, 2] {
    let pixels = 18 * scale
    let name = "menubar_18x18\(scale == 2 ? "@2x" : "").png"
    writePNG(renderMenuBar(pixels: pixels), to: menuBarSet.appendingPathComponent(name))
    menuBarEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x"
        }
    """)
    print("  \(name)  (\(pixels)px)")
}

let menuBarContents = """
{
  "images" : [
\(menuBarEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}

"""
try! menuBarContents.write(to: menuBarSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("✓ Sources/Resources/Assets.xcassets/MenuBarIcon.imageset")

// MARK: - README

// The README opens with the icon, and that copy used to be made by hand — which is how it ended up
// a redesign behind the app. Writing it here is the only thing that keeps the two in step.
private let docsImages = root.appendingPathComponent("docs/images")
try! FileManager.default.createDirectory(at: docsImages, withIntermediateDirectories: true)
writePNG(render(pixels: 512), to: docsImages.appendingPathComponent("icon.png"))
print("✓ docs/images/icon.png")

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
