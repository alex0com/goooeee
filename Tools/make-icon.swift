// Draws the goooeee app icon and writes every size into the asset catalog.
//
//     swift Tools/make-icon.swift            # from the repository root
//     swift Tools/make-icon.swift out.png    # only the 1024 px master, to another file
//
// The icon: a chat bubble made of goo ("gooey" GUI), dripping, with three dots for the "ooo" (and
// a model that is typing), on an indigo rounded square. It follows Apple's macOS icon grid: a
// 1024 px canvas with an 824 px body, so macOS shows it without an extra frame.

import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// A rounded square with continuous (squircle-like) corners, as macOS icons use.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let k: CGFloat = 1.28 // how far the curve starts from the corner, relative to the radius
    let r = radius
    let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
    path.move(to: CGPoint(x: minX + r * k, y: maxY))
    path.addLine(to: CGPoint(x: maxX - r * k, y: maxY))
    path.addCurve(to: CGPoint(x: maxX, y: maxY - r * k), control1: CGPoint(x: maxX - r * 0.35, y: maxY), control2: CGPoint(x: maxX, y: maxY - r * 0.35))
    path.addLine(to: CGPoint(x: maxX, y: minY + r * k))
    path.addCurve(to: CGPoint(x: maxX - r * k, y: minY), control1: CGPoint(x: maxX, y: minY + r * 0.35), control2: CGPoint(x: maxX - r * 0.35, y: minY))
    path.addLine(to: CGPoint(x: minX + r * k, y: minY))
    path.addCurve(to: CGPoint(x: minX, y: minY + r * k), control1: CGPoint(x: minX + r * 0.35, y: minY), control2: CGPoint(x: minX, y: minY + r * 0.35))
    path.addLine(to: CGPoint(x: minX, y: maxY - r * k))
    path.addCurve(to: CGPoint(x: minX + r * k, y: maxY), control1: CGPoint(x: minX, y: maxY - r * 0.35), control2: CGPoint(x: minX + r * 0.35, y: maxY))
    path.closeSubpath()
    return path
}

/// The goo: a rounded bubble with a tail at the lower left and drips from its lower edge, merged
/// into one outline so the rim has no seams.
func gooPath() -> CGPath {
    let bubble = CGRect(x: 222, y: 430, width: 580, height: 372)
    let radius: CGFloat = 186
    var goo = CGPath(roundedRect: bubble, cornerWidth: radius, cornerHeight: radius, transform: nil)

    /// The bubble's lower edge at `x`, following the rounded corners.
    func edge(_ x: CGFloat) -> CGFloat {
        let left = bubble.minX + radius, right = bubble.maxX - radius
        let dx = x < left ? left - x : (x > right ? x - right : 0)
        return bubble.minY + radius - sqrt(max(0, radius * radius - dx * dx))
    }

    // Tail: a thick, rounded tongue of goo out of the lower left.
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 286, y: 520))
    tail.addCurve(to: CGPoint(x: 236, y: 372), control1: CGPoint(x: 282, y: 452), control2: CGPoint(x: 262, y: 404))
    tail.addCurve(to: CGPoint(x: 268, y: 350), control1: CGPoint(x: 222, y: 354), control2: CGPoint(x: 246, y: 340))
    tail.addCurve(to: CGPoint(x: 440, y: 452), control1: CGPoint(x: 330, y: 380), control2: CGPoint(x: 390, y: 420))
    tail.addLine(to: CGPoint(x: 400, y: 520))
    tail.closeSubpath()
    goo = goo.union(tail)

    // Drips: a flared top that meets the edge, a straight run and a round end.
    func drip(x: CGFloat, width: CGFloat, length: CGFloat) -> CGPath {
        let half = width / 2
        let flare = width * 1.05
        let top = edge(x)
        let end = top - length
        let d = CGMutablePath()
        // Each flare leaves the edge along it, like a fillet, then turns down into the drip.
        d.move(to: CGPoint(x: x - half - flare, y: edge(x - half - flare)))
        d.addQuadCurve(to: CGPoint(x: x - half, y: top - flare), control: CGPoint(x: x - half, y: edge(x - half)))
        d.addLine(to: CGPoint(x: x - half, y: end + half))
        d.addArc(center: CGPoint(x: x, y: end + half), radius: half, startAngle: .pi, endAngle: 0, clockwise: false)
        d.addLine(to: CGPoint(x: x + half, y: top - flare))
        d.addQuadCurve(to: CGPoint(x: x + half + flare, y: edge(x + half + flare)), control: CGPoint(x: x + half, y: edge(x + half)))
        d.addLine(to: CGPoint(x: x, y: top + 60))
        d.closeSubpath()
        return d
    }
    goo = goo.union(drip(x: 468, width: 54, length: 150))
    goo = goo.union(drip(x: 572, width: 40, length: 92))
    goo = goo.union(drip(x: 664, width: 58, length: 200))

    // A drop that has just fallen.
    goo = goo.union(CGPath(ellipseIn: CGRect(x: 637, y: 134, width: 54, height: 62), transform: nil))
    return goo
}

func drawIcon(in context: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let background = squircle(body, radius: 185)

    // Shadow under the whole icon, as macOS draws for its own icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(background)
    context.setFillColor(color(0x1A1240))
    context.fillPath()
    context.restoreGState()

    // Background: deep indigo, lighter at the top.
    context.saveGState()
    context.addPath(background)
    context.clip()
    context.drawLinearGradient(
        linearGradient([color(0x4B2C9E), color(0x2A1866), color(0x140B33)], [0, 0.55, 1]),
        start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: []
    )
    // A soft glow behind the goo.
    context.drawRadialGradient(
        linearGradient([color(0x39FF9C, 0.28), color(0x39FF9C, 0)], [0, 1]),
        startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: []
    )
    // Thin light edge at the top.
    context.addPath(background)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()

    let goo = gooPath()

    // Goo shadow on the background.
    context.saveGState()
    context.addPath(background)
    context.clip()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: color(0x05010F, 0.55))
    context.addPath(goo)
    context.setFillColor(color(0x15C46E))
    context.fillPath()
    context.restoreGState()

    // Goo body: bright at the top, deeper green below.
    context.saveGState()
    context.addPath(goo)
    context.clip()
    context.drawLinearGradient(
        linearGradient([color(0xB8FFD2), color(0x4CEB8F), color(0x13B062), color(0x0A7A44)], [0, 0.35, 0.75, 1]),
        start: CGPoint(x: 512, y: 810), end: CGPoint(x: 512, y: 160), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // Darker rim inside the edge, so it reads as thick goo.
    context.addPath(goo)
    context.setStrokeColor(color(0x066B3A, 0.55))
    context.setLineWidth(18)
    context.strokePath()
    context.restoreGState()

    // Gloss: a highlight across the upper left of the bubble and on the drips.
    context.saveGState()
    context.addPath(goo)
    context.clip()
    let gloss = CGMutablePath()
    gloss.addEllipse(in: CGRect(x: 268, y: 668, width: 330, height: 112))
    context.addPath(gloss)
    context.clip()
    context.drawLinearGradient(
        linearGradient([color(0xFFFFFF, 0.85), color(0xFFFFFF, 0.05)], [0, 1]),
        start: CGPoint(x: 400, y: 780), end: CGPoint(x: 420, y: 668), options: []
    )
    context.restoreGState()
    context.setFillColor(color(0xFFFFFF, 0.55))
    for spot in [CGRect(x: 652, y: 282, width: 14, height: 36), CGRect(x: 458, y: 354, width: 12, height: 30), CGRect(x: 650, y: 160, width: 13, height: 20)] {
        context.fillEllipse(in: spot)
    }

    // The three dots ("ooo"), cut into the goo.
    for x in [392.0, 512.0, 632.0] {
        let dot = CGRect(x: x - 42, y: 574, width: 84, height: 84)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 6, color: color(0xFFFFFF, 0.45))
        context.setFillColor(color(0x1A0F45))
        context.fillEllipse(in: dot)
        context.restoreGState()
        // Inner shadow at the top of each hole.
        context.saveGState()
        context.addEllipse(in: dot)
        context.clip()
        context.drawLinearGradient(
            linearGradient([color(0x000000, 0.55), color(0x000000, 0)], [0, 1]),
            start: CGPoint(x: x, y: dot.maxY), end: CGPoint(x: x, y: dot.midY), options: []
        )
        context.restoreGState()
    }
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    graphics.flushGraphics()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let arguments = CommandLine.arguments.dropFirst()
if let output = arguments.first {
    try write(render(size: 1024), to: URL(fileURLWithPath: output))
    print("Wrote \(output)")
    exit(0)
}

let iconSet = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
guard FileManager.default.fileExists(atPath: iconSet.path) else {
    FileHandle.standardError.write(Data("Run this from the repository root.\n".utf8))
    exit(1)
}
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(render(size: points * scale), to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes to \(iconSet.path)")
