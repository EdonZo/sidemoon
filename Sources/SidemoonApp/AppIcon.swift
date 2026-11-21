import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The app icon, drawn in code: the mascot's glass lens, orbit, centre core and satellite on a rounded-square body.
///
/// `SidemoonApp --render-icon <directory> [--variant a|b|c]` writes the three concepts at full size, a contact
/// sheet of every concept at Dock, Finder and menu sizes on light and dark backgrounds, the chosen variant's
/// `AppIcon.iconset`, and `AppIcon.icns` built from it with `iconutil`.
///
/// All drawing happens on a 1024-unit canvas with the origin at the top left; the context is scaled to the
/// requested pixel size. Below `Canvas.smallSide` pixels each variant switches to a bolder geometry with no
/// fine detail, so the mark still reads at 16 and 32 px.
enum AppIcon {

    enum Variant: String, CaseIterable {
        /// Raspberry: the Paper accent as the body, a cream lens with the ink mark inside.
        case a
        /// Paper: a white-to-rose page, a rose glass lens, a raspberry satellite.
        case b
        /// Moonlit: a night-plum body, a pearl lens, a tilted orbit wrapping it and a glowing moon.
        case c

        static let `default`: Variant = .c
    }

    /// The macOS app icon grid (1024 canvas, 824 body) and output settings.
    enum Canvas {
        static let side: CGFloat = 1024
        static let body: CGFloat = 824
        /// Superellipse exponent approximating the continuous-corner macOS squircle.
        static let squircleExponent: CGFloat = 5
        static let squircleSegments = 720
        static let shadowOffsetY: CGFloat = 12
        static let shadowBlur: CGFloat = 28
        static let shadowAlpha: CGFloat = 0.30
        /// Hairline that keeps a light body from melting into a light Dock or Finder window.
        static let rimWidth: CGFloat = 3
        /// At or below this many pixels the bold geometry is used.
        static let smallSide = 64
        static let conceptSide = 1024
        static let iconsetSizes = [16, 32, 128, 256, 512]
        static let iconsetScales = [1, 2]
        static let iconsetName = "AppIcon.iconset"
        static let icnsName = "AppIcon.icns"
        static let iconutilPath = "/usr/bin/iconutil"
        static let variantFlag = "--variant"
    }

    /// The contact sheet: each concept at several sizes on a light and a dark ground, plus magnified small sizes.
    enum Sheet {
        static let sizes = [512, 128, 32, 16]
        static let magnifiedSizes = [32, 16]
        static let magnification = 4
        static let gap = 32
        static let lightGround: UInt32 = 0xF2F0EDFF
        static let darkGround: UInt32 = 0x1E1E20FF
        static let name = "contact-sheet.png"
        static let conceptPrefix = "concept-"
    }

    /// Paper theme colours, mirrored from `Design.Colors` so the icon does not depend on the active theme.
    enum Ink {
        static let ink: UInt32 = 0x2A211CFF
        static let raspberry: UInt32 = 0xC2305AFF
        static let raspberryLight: UInt32 = 0xFF7D9CFF
        static let raspberryDeep: UInt32 = 0x8E1C40FF
        static let raspberryBright: UInt32 = 0xE65380FF
        static let cream: UInt32 = 0xFFF8F3FF
        static let rose: UInt32 = 0xF8DCE4FF
        static let roseDeep: UInt32 = 0xEFB9C8FF
        static let white: UInt32 = 0xFFFFFFFF
        static let plumTop: UInt32 = 0x4A2560FF
        static let plumBottom: UInt32 = 0x1C1230FF
        static let pearlEdge: UInt32 = 0xF7C9D6FF
        static let star: UInt32 = 0xFFE9D6FF
    }

    /// Light on the lens, as fractions of its radius.
    enum Glare {
        /// Where the shading's bright spot sits, up and left of centre.
        static let lightX: CGFloat = 0.35
        static let lightY: CGFloat = 0.40
        /// Radius over which the lens shades from its centre colour to its edge colour.
        static let shadeReach: CGFloat = 1.45
        /// The crescent highlight: an inset disc minus the same disc shifted down and right.
        static let inset: CGFloat = 0.05
        static let shiftX: CGFloat = 0.08
        static let shiftY: CGFloat = 0.10
    }

    /// One variant's colours.
    struct Palette {
        var bodyTop: UInt32
        var bodyBottom: UInt32
        var bodyRim: UInt32
        var lensCentre: UInt32
        var lensEdge: UInt32
        var lensRim: UInt32
        var lensShadow: UInt32
        var lensHighlight: UInt32
        var orbit: UInt32
        var core: UInt32
        var satellite: UInt32
        var satelliteHalo: UInt32
        var satelliteGlow: UInt32
        var stars: UInt32?
    }

    /// One variant's geometry on the 1024 canvas, centred at (512, 512).
    struct Geometry {
        var lensRadius: CGFloat
        var lensRimWidth: CGFloat
        var lensShadowBlur: CGFloat
        var lensShadowOffsetY: CGFloat
        var orbitRadius: CGFloat
        var orbitWidth: CGFloat
        /// Vertical squash of the orbit; 1 is the flat, face-on ring of the mascot.
        var orbitAspect: CGFloat
        /// Orbit tilt in degrees, clockwise.
        var orbitTilt: CGFloat
        var coreRadius: CGFloat
        var satelliteRadius: CGFloat
        var satelliteHaloWidth: CGFloat
        var satelliteGlowBlur: CGFloat
        /// Degrees clockwise from three o'clock, measured on the untilted ring (the mascot rests at -45).
        var satelliteAngle: CGFloat
        var highlight: Bool
        var starCount: Int
    }

    struct Style {
        var palette: Palette
        var regular: Geometry
        var small: Geometry
    }

    // MARK: - Variants

    static func style(_ variant: Variant) -> Style {
        switch variant {
        case .a:
            let palette = Palette(
                bodyTop: Ink.raspberryBright, bodyBottom: Ink.raspberryDeep, bodyRim: 0xFFFFFF26,
                lensCentre: Ink.white, lensEdge: Ink.rose, lensRim: 0xFFFFFFB3, lensShadow: 0x3A0A1E66,
                lensHighlight: 0xFFFFFFCC, orbit: Ink.ink, core: Ink.ink,
                satellite: Ink.raspberry, satelliteHalo: Ink.cream, satelliteGlow: 0x00000000, stars: nil)
            let regular = Geometry(
                lensRadius: 300, lensRimWidth: 8, lensShadowBlur: 40, lensShadowOffsetY: 18,
                orbitRadius: 178, orbitWidth: 36, orbitAspect: 1, orbitTilt: 0,
                coreRadius: 58, satelliteRadius: 56, satelliteHaloWidth: 22, satelliteGlowBlur: 0,
                satelliteAngle: -45, highlight: true, starCount: 0)
            var small = regular
            small.lensRadius = 318; small.orbitRadius = 186; small.orbitWidth = 62
            small.coreRadius = 76; small.satelliteRadius = 84; small.satelliteHaloWidth = 28
            small.highlight = false; small.lensShadowBlur = 0; small.lensShadowOffsetY = 0
            return Style(palette: palette, regular: regular, small: small)
        case .b:
            let palette = Palette(
                bodyTop: Ink.white, bodyBottom: Ink.roseDeep, bodyRim: 0x2A211C1F,
                lensCentre: 0xFDEFF3FF, lensEdge: Ink.roseDeep, lensRim: 0xFFFFFFE6, lensShadow: 0x8E1C4040,
                lensHighlight: 0xFFFFFFE6, orbit: Ink.ink, core: Ink.ink,
                satellite: Ink.raspberry, satelliteHalo: Ink.white, satelliteGlow: 0xC2305A99, stars: nil)
            let regular = Geometry(
                lensRadius: 304, lensRimWidth: 10, lensShadowBlur: 46, lensShadowOffsetY: 22,
                orbitRadius: 182, orbitWidth: 30, orbitAspect: 1, orbitTilt: 0,
                coreRadius: 54, satelliteRadius: 62, satelliteHaloWidth: 20, satelliteGlowBlur: 36,
                satelliteAngle: -45, highlight: true, starCount: 0)
            var small = regular
            small.lensRadius = 320; small.orbitRadius = 190; small.orbitWidth = 60
            small.coreRadius = 76; small.satelliteRadius = 88; small.satelliteHaloWidth = 26
            small.satelliteGlowBlur = 0; small.highlight = false; small.lensShadowBlur = 0; small.lensShadowOffsetY = 0
            return Style(palette: palette, regular: regular, small: small)
        case .c:
            let palette = Palette(
                bodyTop: Ink.plumTop, bodyBottom: Ink.plumBottom, bodyRim: 0xFFFFFF1F,
                lensCentre: Ink.cream, lensEdge: Ink.pearlEdge, lensRim: 0xFFFFFF80, lensShadow: 0xFF7D9C59,
                lensHighlight: 0xFFFFFFCC, orbit: Ink.raspberryLight, core: Ink.ink,
                satellite: Ink.cream, satelliteHalo: Ink.raspberryLight, satelliteGlow: 0xFF7D9CFF,
                stars: Ink.star)
            let regular = Geometry(
                lensRadius: 226, lensRimWidth: 6, lensShadowBlur: 70, lensShadowOffsetY: 0,
                orbitRadius: 336, orbitWidth: 30, orbitAspect: 0.40, orbitTilt: -18,
                coreRadius: 40, satelliteRadius: 50, satelliteHaloWidth: 14, satelliteGlowBlur: 56,
                satelliteAngle: 14, highlight: true, starCount: 9)
            var small = regular
            small.lensRadius = 230; small.orbitRadius = 312; small.orbitWidth = 58; small.orbitAspect = 0.50
            // No core at small sizes: a dark dot in a pale disc inside a squashed ring reads as an eye there.
            small.coreRadius = 0; small.satelliteRadius = 74; small.satelliteHaloWidth = 26
            small.satelliteGlowBlur = 0; small.lensShadowBlur = 0; small.highlight = false; small.starCount = 0
            return Style(palette: palette, regular: regular, small: small)
        }
    }

    /// Fixed star positions (fractions of the body, from its top left) and radii in canvas units.
    static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (0.16, 0.14, 7), (0.30, 0.08, 4), (0.82, 0.12, 6), (0.90, 0.30, 4), (0.10, 0.46, 4),
        (0.86, 0.86, 7), (0.70, 0.94, 4), (0.14, 0.84, 5), (0.52, 0.06, 3),
    ]

    // MARK: - Entry point

    /// Handles `--render-icon <directory> [--variant x]`.
    static func render(to directory: String, arguments: [String]) {
        var variant = Variant.default
        if let flag = arguments.firstIndex(of: Canvas.variantFlag), flag + 1 < arguments.count,
           let picked = Variant(rawValue: arguments[flag + 1].lowercased()) {
            variant = picked
        }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for concept in Variant.allCases {
            write(image(side: Canvas.conceptSide, variant: concept),
                  to: dir.appendingPathComponent("\(Sheet.conceptPrefix)\(concept.rawValue).png"))
        }
        write(contactSheet(), to: dir.appendingPathComponent(Sheet.name))

        let iconset = dir.appendingPathComponent(Canvas.iconsetName, isDirectory: true)
        try? FileManager.default.removeItem(at: iconset)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in Canvas.iconsetSizes {
            for scale in Canvas.iconsetScales {
                let suffix = scale == 1 ? "" : "@\(scale)x"
                write(image(side: size * scale, variant: variant),
                      to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        let icns = dir.appendingPathComponent(Canvas.icnsName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Canvas.iconutilPath)
        process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
        try? process.run()
        process.waitUntilExit()
        print("Icon variant \(variant.rawValue) written to \(dir.path)")
    }

    // MARK: - Drawing

    static func image(side: Int, variant: Variant) -> CGImage? {
        guard let ctx = context(width: side, height: side) else { return nil }
        let scale = CGFloat(side) / Canvas.side
        let s = style(variant)
        draw(in: ctx, scale: scale, palette: s.palette, geometry: side <= Canvas.smallSide ? s.small : s.regular)
        return ctx.makeImage()
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func draw(in ctx: CGContext, scale: CGFloat, palette p: Palette, geometry g: Geometry) {
        let pixelHeight = CGFloat(ctx.height)
        ctx.saveGState()
        // Top-left origin in canvas units. Shadow offsets ignore the CTM, so they are converted by hand.
        ctx.translateBy(x: 0, y: pixelHeight)
        ctx.scaleBy(x: scale, y: -scale)
        func shadow(_ offsetY: CGFloat, _ blur: CGFloat, _ color: UInt32) {
            ctx.setShadow(offset: CGSize(width: 0, height: -offsetY * scale), blur: blur * scale, color: cg(color))
        }

        let centre = CGPoint(x: Canvas.side / 2, y: Canvas.side / 2)
        let bodyRect = CGRect(x: (Canvas.side - Canvas.body) / 2, y: (Canvas.side - Canvas.body) / 2,
                              width: Canvas.body, height: Canvas.body)
        let body = squircle(in: bodyRect)

        // Body with the standard drop shadow.
        ctx.saveGState()
        shadow(Canvas.shadowOffsetY, Canvas.shadowBlur, alpha(0x000000FF, Canvas.shadowAlpha))
        ctx.addPath(body)
        ctx.setFillColor(cg(p.bodyBottom))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        linear(ctx, p.bodyTop, p.bodyBottom, from: CGPoint(x: centre.x, y: bodyRect.minY), to: CGPoint(x: centre.x, y: bodyRect.maxY))

        if let starColor = p.stars {
            ctx.setFillColor(cg(starColor))
            for star in stars.prefix(g.starCount) {
                let c = CGPoint(x: bodyRect.minX + star.x * Canvas.body, y: bodyRect.minY + star.y * Canvas.body)
                ctx.fillEllipse(in: CGRect(x: c.x - star.r, y: c.y - star.r, width: star.r * 2, height: star.r * 2))
            }
        }

        let tilted = g.orbitAspect < 1
        let orbitTransform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: g.orbitTilt * .pi / 180)
            .scaledBy(x: 1, y: g.orbitAspect)
        func orbitPath(fromDegrees start: CGFloat, toDegrees end: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: g.orbitRadius, startAngle: start * .pi / 180, endAngle: end * .pi / 180,
                        clockwise: false, transform: orbitTransform)
            return path
        }
        func strokeOrbit(_ path: CGPath) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(cg(p.orbit))
            ctx.setLineWidth(g.orbitWidth)
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // A tilted orbit passes behind the lens across its upper half (canvas y grows downwards).
        if tilted { strokeOrbit(orbitPath(fromDegrees: 180, toDegrees: 360)) }

        // The lens.
        let lensRect = CGRect(x: centre.x - g.lensRadius, y: centre.y - g.lensRadius, width: g.lensRadius * 2, height: g.lensRadius * 2)
        if g.lensShadowBlur > 0 {
            ctx.saveGState()
            shadow(g.lensShadowOffsetY, g.lensShadowBlur, p.lensShadow)
            ctx.setFillColor(cg(p.lensEdge))
            ctx.fillEllipse(in: lensRect)
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addEllipse(in: lensRect)
        ctx.clip()
        let lightSource = CGPoint(x: centre.x - g.lensRadius * Glare.lightX, y: centre.y - g.lensRadius * Glare.lightY)
        radial(ctx, p.lensCentre, p.lensEdge, centre: lightSource, radius: g.lensRadius * Glare.shadeReach)
        if g.highlight {
            // A soft crescent of reflected light across the upper left.
            let inset = g.lensRadius * Glare.inset
            let glare = CGMutablePath()
            glare.addEllipse(in: lensRect.insetBy(dx: inset, dy: inset))
            let cut = CGMutablePath()
            cut.addEllipse(in: lensRect.insetBy(dx: inset, dy: inset)
                .offsetBy(dx: g.lensRadius * Glare.shiftX, dy: g.lensRadius * Glare.shiftY))
            ctx.saveGState()
            ctx.addPath(glare)
            ctx.addPath(cut)
            ctx.clip(using: .evenOdd)
            ctx.addPath(glare)
            ctx.clip()
            linear(ctx, p.lensHighlight, p.lensHighlight & 0xFFFFFF00,
                   from: CGPoint(x: lensRect.minX, y: lensRect.minY), to: CGPoint(x: centre.x, y: centre.y))
            ctx.restoreGState()
        }
        ctx.restoreGState()
        ctx.setStrokeColor(cg(p.lensRim))
        ctx.setLineWidth(g.lensRimWidth)
        ctx.strokeEllipse(in: lensRect.insetBy(dx: g.lensRimWidth / 2, dy: g.lensRimWidth / 2))

        // The orbit in front: the whole ring when flat, the lower half when tilted.
        strokeOrbit(tilted ? orbitPath(fromDegrees: 0, toDegrees: 180) : orbitPath(fromDegrees: 0, toDegrees: 360))

        // The centre core.
        ctx.setFillColor(cg(p.core))
        ctx.fillEllipse(in: CGRect(x: centre.x - g.coreRadius, y: centre.y - g.coreRadius, width: g.coreRadius * 2, height: g.coreRadius * 2))

        // The satellite, with a halo that separates it from the ring and an optional glow.
        let angle = g.satelliteAngle * .pi / 180
        let dot = CGPoint(x: g.orbitRadius * cos(angle), y: g.orbitRadius * sin(angle)).applying(orbitTransform)
        let haloR = g.satelliteRadius + g.satelliteHaloWidth
        ctx.setFillColor(cg(p.satelliteHalo))
        ctx.fillEllipse(in: CGRect(x: dot.x - haloR, y: dot.y - haloR, width: haloR * 2, height: haloR * 2))
        ctx.saveGState()
        if g.satelliteGlowBlur > 0 { shadow(0, g.satelliteGlowBlur, p.satelliteGlow) }
        ctx.setFillColor(cg(p.satellite))
        ctx.fillEllipse(in: CGRect(x: dot.x - g.satelliteRadius, y: dot.y - g.satelliteRadius,
                                   width: g.satelliteRadius * 2, height: g.satelliteRadius * 2))
        ctx.restoreGState()
        ctx.restoreGState()  // body clip

        // Hairline rim on the body.
        ctx.addPath(body)
        ctx.setStrokeColor(cg(p.bodyRim))
        ctx.setLineWidth(Canvas.rimWidth)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A superellipse filling `rect`: the continuous-corner rounded square of macOS icons.
    private static func squircle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2
        let power = 2 / Canvas.squircleExponent
        for i in 0..<Canvas.squircleSegments {
            let t = CGFloat(i) / CGFloat(Canvas.squircleSegments) * 2 * .pi
            let c = cos(t), s = sin(t)
            let point = CGPoint(x: rect.midX + a * copysign(pow(abs(c), power), c),
                                y: rect.midY + b * copysign(pow(abs(s), power), s))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func linear(_ ctx: CGContext, _ from: UInt32, _ to: UInt32, from start: CGPoint, to end: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [cg(from), cg(to)] as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ ctx: CGContext, _ inner: UInt32, _ outer: UInt32, centre: CGPoint, radius: CGFloat) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [cg(inner), cg(outer)] as CFArray, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    }

    private static func cg(_ rgba: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    private static func alpha(_ rgba: UInt32, _ value: CGFloat) -> UInt32 {
        (rgba & 0xFFFFFF00) | UInt32((value * 255).rounded())
    }

    // MARK: - Contact sheet

    /// Rows are concepts; each row shows every sheet size on the light ground, then on the dark ground,
    /// then the smallest sizes magnified without smoothing.
    private static func contactSheet() -> CGImage? {
        let g = Sheet.gap
        let half = Sheet.sizes.reduce(0, +) + g * (Sheet.sizes.count + 1)
        let magnified = Sheet.magnifiedSizes.reduce(0, +) * Sheet.magnification + g * (Sheet.magnifiedSizes.count + 1)
        let rowHeight = (Sheet.sizes.max() ?? 0) + g * 2
        let width = half * 2 + magnified * 2
        let height = rowHeight * Variant.allCases.count
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.setFillColor(cg(Sheet.lightGround))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(cg(Sheet.darkGround))
        ctx.fill(CGRect(x: half, y: 0, width: half, height: height))
        ctx.fill(CGRect(x: half * 2 + magnified, y: 0, width: magnified, height: height))
        ctx.interpolationQuality = .none

        for (row, variant) in Variant.allCases.enumerated() {
            // CG's origin is bottom left; rows run top to bottom.
            let top = height - rowHeight * (row + 1)
            let midY = top + rowHeight / 2
            for ground in 0..<2 {
                var x = half * ground + g
                for size in Sheet.sizes {
                    if let icon = image(side: size, variant: variant) {
                        ctx.draw(icon, in: CGRect(x: x, y: midY - size / 2, width: size, height: size))
                    }
                    x += size + g
                }
            }
            for ground in 0..<2 {
                var x = half * 2 + magnified * ground + g
                for size in Sheet.magnifiedSizes {
                    let shown = size * Sheet.magnification
                    if let icon = image(side: size, variant: variant) {
                        ctx.draw(icon, in: CGRect(x: x, y: midY - shown / 2, width: shown, height: shown))
                    }
                    x += shown + g
                }
            }
        }
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
