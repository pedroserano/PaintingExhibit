import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision
import simd
import UniformTypeIdentifiers

enum ProcessingError: LocalizedError {
    case noImage, renderFailed, writeFailed

    var errorDescription: String? {
        switch self {
        case .noImage: return "The photo could not be read."
        case .renderFailed: return "The painting could not be rendered."
        case .writeFailed: return "The result could not be saved."
        }
    }
}

/// A point in normalized image coordinates (0...1, bottom-left origin, as Vision and Core Image use).
struct NormPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Corners someone set by hand (top-left, top-right, bottom-right, bottom-left, in the photo with lens
/// distortion `lensK` undone), used in place of the automatic crop.
struct ManualCrop: Codable, Hashable {
    var quad: [NormPoint]
    var lensK: Double?
}

/// The non-destructive edit recipe for one painting. The photo in Photos is never changed;
/// the exhibit image is drawn from the original with these values, and can be redrawn at any time.
struct ProcessingSettings: Codable, Hashable {
    /// The painting (outer frame edge) in the photo: top-left, top-right, bottom-right, bottom-left.
    var paintingQuad: [NormPoint]?
    /// Lens distortion found in the photo and undone before anything else (division model, radius relative to
    /// half the photo's diagonal). Negative: barrel, as from a fish-eye or wide-angle lens. Nil: none found.
    var lensK: Double?
    /// The painting's true width ÷ height, worked out from the corners and the lens, so a painting
    /// photographed from one side or from below isn't squashed. Nil: use the corners' own shape.
    var aspect: Double?
    /// The canvas inside the frame, in the flattened painting. Nil when no frame was found.
    var canvasQuad: [NormPoint]?
    /// Whether the frame is shown (canvasQuad is then not applied).
    var keptFrame: Bool

    /// Linear-light wall colour just outside each side of the frame.
    var wallLeft: SIMD3<Float>?
    var wallRight: SIMD3<Float>?
    var wallTop: SIMD3<Float>?
    var wallBottom: SIMD3<Float>?

    /// No longer used (was how far the wall was trusted for white balance); kept so saved recipes still load.
    var lightStrength: Float
    var whiteBalance: SIMD3<Float>
    var gainLeft: Float
    var gainRight: Float
    var gainTop: Float
    var gainBottom: Float

    /// Exposure, computed on first render. Nil means "work it out again" (e.g. after the frame choice changes).
    var blackPoint: Float?
    var exposure: Float?

    var cropFound: Bool { paintingQuad != nil }
    var frameFound: Bool { canvasQuad != nil }
    var frameRemoved: Bool { frameFound && !keptFrame }
    var unevenLightFixed: Bool { [gainLeft, gainRight, gainTop, gainBottom].contains { abs($0 - 1) > 0.005 } }
}

/// Crops a painting out of a museum photo and corrects its lighting,
/// using the wall around the painting as the reference.
///
/// `analyze` works out the recipe (`ProcessingSettings`); `render` draws the painting from
/// the original photo with a recipe. Nothing is ever written back to Photos.
///
/// Analysis:
/// 1. Find the painting (frame) as a rectangle and flatten its perspective.
/// 2. Look inside that for the canvas edge, so the frame can be dropped.
/// 3. Sample the wall just outside the frame on each side:
///    - its average colour gives the colour of the light (white balance),
///    - the difference between sides gives the spotlight falloff.
/// Rendering applies the white balance and the inverse falloff to the canvas,
/// then gently sets exposure from the painting's own brightness range.
enum PaintingProcessor {
    static let maxDimension: CGFloat = 2400

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    fileprivate static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false
    ])

    // MARK: Entry points

    /// Works out the recipe for a photo, draws the painting with it and writes the image to `url`.
    /// Returns the recipe, with the exposure it settled on filled in.
    /// With `manual`, the corners someone set by hand are used instead of finding the painting.
    static func analyzeAndRender(imageData: Data, keepFrame: Bool, manual: ManualCrop? = nil,
                                 writeTo url: URL) throws -> ProcessingSettings {
        var (base, baseCG) = try prepare(imageData)
        // Straighten bent lines first: the frame is found and cropped far more reliably once its edges are straight.
        let lensK = manual.map { $0.lensK } ?? estimateLens(in: baseCG)
        if let lensK, let undone = undistort(base, k: lensK) { (base, baseCG) = undone }
        var settings = analyze(base: base, baseCG: baseCG, keepFrame: keepFrame,
                               focal35: lensK == nil ? focalLength35(of: imageData) : nil, forcedQuad: manual?.quad)
        settings.lensK = lensK
        return try render(base: base, settings: settings, writeTo: url)
    }

    /// The photo as the recipe's corners refer to it (orientation applied, lens distortion `lensK` undone),
    /// shrunk to `maxDimension`, for setting the corners by hand.
    static func preparedPhoto(imageData: Data, lensK: Double?, maxDimension: CGFloat = 1600) throws -> CGImage {
        var (base, baseCG) = try prepare(imageData)
        if let lensK, let undone = undistort(base, k: lensK) { (base, baseCG) = undone }
        let scale = min(1, maxDimension / max(base.extent.width, base.extent.height))
        guard scale < 1 else { return baseCG }
        let small = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            throw ProcessingError.renderFailed
        }
        return cg
    }

    /// The final crop as a quad in the (lens-corrected) photo: the painting's outline, or the canvas inside it
    /// when the frame is removed; the whole photo when nothing was found.
    static func cropQuad(of settings: ProcessingSettings) -> [NormPoint] {
        guard let quad = settings.paintingQuad else {
            return [NormPoint(x: 0, y: 1), NormPoint(x: 1, y: 1), NormPoint(x: 1, y: 0), NormPoint(x: 0, y: 0)]
        }
        guard let canvas = settings.canvasQuad, !settings.keptFrame else { return quad }
        let toPhoto = squareToQuad(quad)
        return canvas.map(toPhoto)
    }

    /// Draws the painting from the original photo with an existing recipe (no detection).
    /// The recipe's corners are relative to the photo, so it can be drawn at any size:
    /// `maxDimension` caps the photo's long side before cropping (larger for edits saved to Photos).
    static func render(
        imageData: Data,
        settings: ProcessingSettings,
        maxDimension: CGFloat = PaintingProcessor.maxDimension,
        writeTo url: URL
    ) throws -> ProcessingSettings {
        var (base, _) = try prepare(imageData, maxDimension: maxDimension)
        if let k = settings.lensK, let undone = undistort(base, k: k) { base = undone.0 }
        return try render(base: base, settings: settings, writeTo: url)
    }

    // MARK: Preparing the photo

    /// Loads the photo, applies its orientation and scales it to the working size.
    private static func prepare(_ imageData: Data, maxDimension: CGFloat = PaintingProcessor.maxDimension) throws -> (CIImage, CGImage) {
        guard var image = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else {
            throw ProcessingError.noImage
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, maxDimension / max(image.extent.width, image.extent.height))
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
            ])
        }
        guard let baseCG = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            throw ProcessingError.renderFailed
        }
        return (CIImage(cgImage: baseCG), baseCG)
    }

    // MARK: Lens distortion

    /// Finds barrel (fish-eye) or pincushion distortion from straight edges near the photo's sides, where a
    /// painting's frame usually runs: those edges are straight in reality. Points where the colour changes sharply
    /// are collected in the outer part of each side; the correction under which the most of them line up along
    /// each side (allowing for some tilt) wins. Nothing needs to be found first, since bent edges defeat that.
    /// Nil when the edges are already straight (most phone photos, whose camera corrects its lens) or unclear.
    private static func estimateLens(in image: CGImage) -> Double? {
        guard let map = EdgeMap(image, depth: 0.35) else { return nil }
        func support(_ k: Double) -> [Int] { (0..<4).map { map.bestLine(side: $0, k: k, maxAngle: 12).count } }
        let straight = support(0)
        var best = (k: 0.0, total: straight.reduce(0, +))
        // Barrel (fish-eye, wide-angle) up to strong; pincushion (some zoom lenses) only mild.
        for step in -45...6 where step != 0 {
            let k = Double(step) / 100
            let total = support(k).reduce(0, +)
            if total > best.total { best = (k, total) }
        }
        // Only correct when clearly more of the edges line up than before.
        let before = straight.reduce(0, +)
        guard abs(best.k) >= 0.04, best.total - before >= 12, Double(best.total) >= Double(before) * 1.15 else { return nil }
        return best.k
    }

    /// Points where the colour changes sharply, in the outer part of each side of an image (shrunk to 800
    /// pixels), and the straight lines they form. Used to find lens distortion and to straighten a painting.
    struct EdgeMap {
        static let positions = 48
        let width: Int, height: Int
        /// Per side (left, right, top, bottom): points in pixels, row 0 at the top.
        let sides: [[SIMD2<Double>]]

        init?(_ image: CGImage, depth: Double) {
            let scale = min(1, 800 / CGFloat(max(image.width, image.height)))
            let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
            guard w >= 200, h >= 200,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: PaintingProcessor.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let small = ctx.makeImage(), let px = Pixels(small) else { return nil }
            width = w; height = h
            var sides: [[SIMD2<Double>]] = []
            for side in 0..<4 {
                let length = side < 2 ? h : w, across = side < 2 ? w : h
                func colour(_ d: Int, _ a: Int) -> SIMD3<Float> {
                    switch side {
                    case 0: return px.at(d, a)
                    case 1: return px.at(w - 1 - d, a)
                    case 2: return px.at(a, d)
                    default: return px.at(a, h - 1 - d)
                    }
                }
                var points: [SIMD2<Double>] = []
                let maxDepth = Int(Double(across) * depth)
                for k in 0..<Self.positions {
                    let a = length * (5 + 90 * k / (Self.positions - 1)) / 100
                    var change = [Float](repeating: 0, count: maxDepth)
                    for d in 3..<max(3, maxDepth - 3) {
                        var diff = SIMD3<Float>(repeating: 0)
                        for t in -1...1 { diff += abs(colour(d + 2, a + t) - colour(d - 2, a + t)) }
                        change[d] = (diff.x + diff.y + diff.z) / 9
                    }
                    var peaks: [(Int, Float)] = []
                    for d in 4..<max(4, maxDepth - 4) where change[d] >= 0.06 && change[d] >= change[d - 1] && change[d] > change[d + 1] {
                        peaks.append((d, change[d]))
                    }
                    for (d, _) in peaks.sorted(by: { $0.1 > $1.1 }).prefix(6) {
                        switch side {
                        case 0: points.append(SIMD2(Double(d), Double(a)))
                        case 1: points.append(SIMD2(Double(w - 1 - d), Double(a)))
                        case 2: points.append(SIMD2(Double(a), Double(d)))
                        default: points.append(SIMD2(Double(a), Double(h - 1 - d)))
                        }
                    }
                }
                sides.append(points)
            }
            self.sides = sides
        }

        /// The line along a side (tilted up to `maxAngle` degrees) that the most points lie within 1.5 pixels of,
        /// after undoing lens distortion `k`. `offset` is the line's distance along its normal (cos a, sin a) for
        /// the left and right sides, (sin a, cos a) for the top and bottom.
        func bestLine(side: Int, k: Double = 0, maxAngle: Double) -> (angle: Double, offset: Double, count: Int) {
            let centre = SIMD2(Double(width) / 2, Double(height) / 2), radius = hypot(Double(width), Double(height)) / 2
            let points = k == 0 ? sides[side] : sides[side].map { p -> SIMD2<Double> in
                let r = simd_length(p - centre) / radius
                return centre + (p - centre) / (1 + k * r * r)
            }
            var best = (angle: 0.0, offset: 0.0, count: 0)
            for degrees in stride(from: -maxAngle, through: maxAngle, by: 0.5) {
                let angle = degrees * .pi / 180
                let normal = side < 2 ? SIMD2(cos(angle), sin(angle)) : SIMD2(sin(angle), cos(angle))
                var bins = [Int: Int]()
                for p in points { bins[Int((simd_dot(p, normal) / 1.5).rounded(.down)), default: 0] += 1 }
                for (bin, count) in bins {
                    let total = count + (bins[bin + 1] ?? 0)
                    if total > best.count { best = (angle, Double(bin + 1) * 1.5, total) }
                }
            }
            return best
        }
    }

    /// For testing: how far the strongest edge along each side of an image leans from square (degrees), and how
    /// many of the 48 points along that side it runs through.
    static func sideLeans(of image: CGImage) -> [(degrees: Double, count: Int)] {
        guard let map = EdgeMap(image, depth: 0.15) else { return [] }
        return (0..<4).map { let l = map.bestLine(side: $0, maxAngle: 20); return (l.angle * 180 / .pi, l.count) }
    }

    /// Undoes lens distortion `k` (see `estimateLens`). Barrel correction keeps the photo's size (losing a little at
    /// the edges); pincushion correction shrinks it slightly so the corners stay filled.
    static func undistort(_ image: CIImage, k: Double) -> (CIImage, CGImage)? {
        let zoom = k > 0 ? 1 / (1 + k) : 1
        return remap(image) { r in
            // Output radius r (relative to the half-diagonal) comes from the distorted photo at this radius.
            let ru = r * zoom
            guard abs(k) > 1e-9, ru > 1e-9 else { return ru }
            let discriminant = 1 - 4 * k * ru * ru
            guard discriminant >= 0 else { return .infinity }
            return (1 - discriminant.squareRoot()) / (2 * k * ru)
        }
    }

    /// Bends a straight photo as lens distortion `k` would, zoomed so the corners stay filled (for testing
    /// `estimateLens`; relative to the result, the distortion is k × zoom²).
    static func distort(_ image: CIImage, k: Double) -> (CIImage, CGImage)? {
        let zoom = k < 0 ? (1 - (1 - 4 * k).squareRoot()) / (2 * k) : 1
        return remap(image) { r in r * zoom / (1 + k * r * r * zoom * zoom) }
    }

    /// Redraws the image so the pixel at radius r from the centre (relative to the half-diagonal) is taken from
    /// radius `source(r)` in the original, with bilinear sampling.
    private static func remap(_ image: CIImage, source: (Double) -> Double) -> (CIImage, CGImage)? {
        guard let cg = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            return nil
        }
        let w = cg.width, h = cg.height
        var input = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = input.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var output = [UInt8](repeating: 0, count: w * h * 4)
        let cx = Double(w) / 2, cy = Double(h) / 2, radius = hypot(cx, cy)
        // The mapping depends only on the radius, so tabulate it.
        let steps = 4096
        let table = (0...steps).map { source(Double($0) / Double(steps) * 1.5) }
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let dy = (Double(y) + 0.5 - cy) / radius
                    for x in 0..<w {
                        let dx = (Double(x) + 0.5 - cx) / radius
                        let r = (dx * dx + dy * dy).squareRoot()
                        let position = min(r / 1.5, 1) * Double(steps)
                        let i = min(Int(position), steps - 1), f = position - Double(i)
                        let rs = table[i] * (1 - f) + table[i + 1] * f
                        guard rs.isFinite else { continue }
                        let ratio = r > 1e-9 ? rs / r : 1
                        let sx = cx + dx * ratio * radius - 0.5, sy = cy + dy * ratio * radius - 0.5
                        guard sx >= 0, sy >= 0, sx < Double(w - 1), sy < Double(h - 1) else { continue }
                        let x0 = Int(sx), y0 = Int(sy), fx = sx - Double(x0), fy = sy - Double(y0)
                        let o = (y * w + x) * 4, i00 = (y0 * w + x0) * 4, i01 = i00 + 4, i10 = i00 + w * 4, i11 = i10 + 4
                        for c in 0..<4 {
                            let top = Double(src[i00 + c]) * (1 - fx) + Double(src[i01 + c]) * fx
                            let bottom = Double(src[i10 + c]) * (1 - fx) + Double(src[i11 + c]) * fx
                            dst[o + c] = UInt8(min(255, max(0, (top * (1 - fy) + bottom * fy).rounded())))
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let result = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        return (CIImage(cgImage: result), result)
    }

    // MARK: Analysis

    /// The lens's focal length as a 35 mm-equivalent, from the photo's EXIF data.
    private static func focalLength35(of imageData: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let focal = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue, focal > 5 else {
            return nil
        }
        return focal
    }

    private static func analyze(base: CIImage, baseCG: CGImage, keepFrame: Bool, focal35: Double?,
                                forcedQuad: [NormPoint]? = nil) -> ProcessingSettings {
        var settings = ProcessingSettings(
            paintingQuad: nil, canvasQuad: nil, keptFrame: keepFrame,
            lightStrength: 0, whiteBalance: SIMD3(1, 1, 1),
            gainLeft: 1, gainRight: 1, gainTop: 1, gainBottom: 1
        )

        // 1. Find the painting: the photo's subject, if it is rectangular (a painting in its frame); then a clear
        // rectangle with wall around it, then the main flat object, then (a close-up) the whole photo, if a frame
        // can be found running along its edges. Thin strips are skipped: they are usually a band across the painting, not the painting.
        let size = base.extent.size
        let plausible: (CGFloat, CGPoint) -> Bool = { area, _ in area >= 0.08 }
        let pixels = smallPixels(base)
        func shaped(_ quad: [NormPoint]?) -> [NormPoint]? {
            guard let quad else { return nil }
            let ratio = naiveAspect(of: quad, in: size)
            guard ratio > 1 / 3.2, ratio < 3.2 else { return nil }
            // The painting usually fills most of the photo. A small outline is often a shape inside the painting
            // (a window, a panel, a face), so it must have plain wall around nearly all of it; a long, thin one
            // is often a band across the painting, so it needs bare wall on every side.
            let elongated = ratio > 2.2 || ratio < 1 / 2.2
            let small = area(of: quad) < 0.4
            if let pixels {
                let check: Bool
                if elongated && small {
                    check = surroundingsLookPlain(quad, in: pixels, strictness: .wallOnly, share: 1)
                } else if small {
                    check = surroundingsLookPlain(quad, in: pixels, strictness: .strict, share: 0.75)
                } else {
                    check = surroundingsLookPlain(quad, in: pixels, strictness: elongated ? .strict : .lenient,
                                                  share: elongated ? 1 : 0.5)
                }
                if !check { return nil }
            }
            return quad
        }
        let wholePhoto = [NormPoint(x: 0, y: 1), NormPoint(x: 1, y: 1), NormPoint(x: 1, y: 0), NormPoint(x: 0, y: 0)]
        // Vision's largest rectangle, skipping lines on the wall (a panel or doorway around the painting). A smaller
        // rectangle is only tried in place of a wall feature: one inside a rejected outline is part of the painting.
        let rectangle = rectangles(in: baseCG, minimumSize: 0.2, accept: plausible)
            .first { quad in pixels.map { !isWallFeature(quad, in: $0) } ?? true }
            .flatMap(shaped)
        guard var quad = forcedQuad
                ?? subjectFinder(baseCG).flatMap(shaped)
                ?? rectangle
                ?? shaped(documentQuad(in: baseCG))
                // Otherwise assume the painting fills the photo, with its frame near the edges or out of shot.
                ?? (findCanvas(in: base) != nil ? wholePhoto : nil)
                ?? straighten(wholePhoto, in: base) else {
            return settings
        }
        // Square it up from the frame's own edges: an outline that missed the perspective (or the whole photo of
        // a painting shot from below or one side) leaves the frame a trapezoid.
        for _ in 0..<(forcedQuad == nil ? 2 : 0) {
            // A painting is in the photo: a squaring that puts corners well outside it has followed the wrong lines.
            guard let squarer = straighten(quad, in: base),
                  squarer.allSatisfy({ $0.x > -0.02 && $0.x < 1.02 && $0.y > -0.02 && $0.y < 1.02 }) else { break }
            quad = squarer
        }
        settings.paintingQuad = quad
        settings.aspect = quad == wholePhoto ? nil : trueAspect(of: quad, in: size, focal35: focal35)
        let wall = sampleWall(around: quad, in: base)
        settings.wallLeft = wall.left
        settings.wallRight = wall.right
        settings.wallTop = wall.top
        settings.wallBottom = wall.bottom

        // 2. Look for the canvas inside the frame (always, so the frame choice can change later).
        // Corners set by hand are the crop itself.
        settings.canvasQuad = forcedQuad == nil ? findCanvas(in: flattenPainting(base, settings: settings)) : nil

        // 3. Work out the corrections from the wall. Its colour isn't used for white balance: which bit of wall
        // (and frame) ends up beside the crop varies from photo to photo, and on photos of the same painting
        // that made the colours differ far more than the cameras' own white balance did. Estimating the light
        // from the painting itself (grey world and the like) drains the colour of warm, varnished paintings.
        if wall.average != nil {
            // Spotlight falloff: brighten the side of the canvas next to the darker wall.
            if let l = wall.left, let r = wall.right {
                let ll = l.sum / 3, lr = r.sum / 3, mean = (ll + lr) / 2
                settings.gainLeft = clamp(mean / max(ll, 0.0001), 0.75, 1.33)
                settings.gainRight = clamp(mean / max(lr, 0.0001), 0.75, 1.33)
            }
            if let t = wall.top, let b = wall.bottom {
                let lt = t.sum / 3, lb = b.sum / 3, mean = (lt + lb) / 2
                settings.gainTop = clamp(mean / max(lt, 0.0001), 0.75, 1.33)
                settings.gainBottom = clamp(mean / max(lb, 0.0001), 0.75, 1.33)
            }
        }
        return settings
    }

    // MARK: Rendering

    private static func render(base: CIImage, settings: ProcessingSettings, writeTo url: URL) throws -> ProcessingSettings {
        var settings = settings
        var painting = base
        if settings.paintingQuad != nil {
            painting = flattenPainting(painting, settings: settings)
            if let inner = settings.canvasQuad, !settings.keptFrame {
                painting = flatten(painting, quad: inner)
            }
        }
        guard let paintingCG = context.createCGImage(painting, from: painting.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            throw ProcessingError.renderFailed
        }

        let output = try applyCorrections(to: paintingCG, settings: &settings)

        // Write to a temporary file first, so a half-written image is never shown.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        guard let destination = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProcessingError.writeFailed
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProcessingError.writeFailed }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return settings
    }

    // MARK: Finding the painting

    /// The rectangles Vision finds that pass `accept(area, center)`, largest first, in normalized coordinates,
    /// as top-left, top-right, bottom-right, bottom-left.
    private static func rectangles(
        in image: CGImage,
        minimumSize: Float,
        confidence: Float = 0.4,
        tolerance: Float = 25,
        accept: (CGFloat, CGPoint) -> Bool
    ) -> [[NormPoint]] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1.0
        request.minimumSize = minimumSize
        request.maximumObservations = 8
        request.quadratureTolerance = tolerance
        request.minimumConfidence = confidence
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        let quads = (request.results ?? []).map { o in
            [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { NormPoint(x: Double($0.x), y: Double($0.y)) }
        }
        // Vision can extend a shape past the photo's edges; a painting in the photo stays inside it.
        return quads
            .filter { $0.allSatisfy { $0.x > -0.1 && $0.x < 1.1 && $0.y > -0.1 && $0.y < 1.1 } }
            .filter { accept(area(of: $0), center(of: $0)) }
            .sorted { area(of: $0) > area(of: $1) }
    }

    /// Finds the painting as the photo's main object; Apple's foreground segmentation unless replaced.
    nonisolated(unsafe) static var subjectFinder: (CGImage) -> [NormPoint]? = foregroundQuad

    /// The photo's subject as Vision separates it from the background (the object at the centre of the photo,
    /// else the largest), as a quad through its outermost corners, if it is rectangular.
    static func foregroundQuad(in image: CGImage) -> [NormPoint]? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var counts = [UInt8: Int]()
        for y in 0..<h { for x in 0..<w where base[y * row + x] > 0 { counts[base[y * row + x], default: 0] += 1 } }
        var label = base[(h / 2) * row + w / 2]
        if label == 0 { label = counts.max { $0.value < $1.value }?.key ?? 0 }
        guard label > 0 else { return nil }
        return rectangularQuad(width: w, height: h) { x, y in base[y * row + x] == label }
    }

    /// The quad through a mask's outermost corners (row 0 at the top), if the mask is rectangular: a painting in
    /// its frame fills its outline and doesn't spill outside it; a face or a tree, whose outermost points make a
    /// diamond, spills well outside.
    static func rectangularQuad(width w: Int, height h: Int, isOn: (Int, Int) -> Bool) -> [NormPoint]? {
        var pixels = 0
        var tl = (Double.infinity, SIMD2<Double>(0, 0)), br = (-Double.infinity, SIMD2<Double>(0, 0))
        var tr = (-Double.infinity, SIMD2<Double>(0, 0)), bl = (Double.infinity, SIMD2<Double>(0, 0))
        for y in 0..<h {
            for x in 0..<w where isOn(x, y) {
                pixels += 1
                let p = SIMD2((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h))
                if p.x + p.y < tl.0 { tl = (p.x + p.y, p) }
                if p.x + p.y > br.0 { br = (p.x + p.y, p) }
                if p.x - p.y > tr.0 { tr = (p.x - p.y, p) }
                if p.x - p.y < bl.0 { bl = (p.x - p.y, p) }
            }
        }
        guard pixels > 0 else { return nil }
        let corners = [tl.1, tr.1, br.1, bl.1]
        let quad = corners.map { NormPoint(x: $0.x, y: 1 - $0.y) }
        let outline = Double(area(of: quad))
        guard outline >= 0.15, isConvex(quad) else { return nil }
        func inside(_ p: SIMD2<Double>) -> Bool {
            (0..<4).allSatisfy { i in
                let a = corners[i], b = corners[(i + 1) % 4]
                return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -0.002
            }
        }
        var outside = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where isOn(x, y) {
                if !inside(SIMD2((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h))) { outside += 4 }
            }
        }
        let share = Double(pixels) / Double(w * h)
        guard Double(outside) / Double(pixels) < 0.04, (share - Double(outside) / Double(w * h)) >= outline * 0.92 else {
            return nil
        }
        return quad
    }

    /// Vision's document finder, as a fallback when no rectangle stands out: it picks out the main
    /// flat object in the photo, which for a photo of a painting is usually the painting in its frame.
    private static func documentQuad(in image: CGImage) -> [NormPoint]? {
        let request = VNDetectDocumentSegmentationRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let o = request.results?.first, o.confidence >= 0.5 else { return nil }
        let quad = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { NormPoint(x: Double($0.x), y: Double($0.y)) }
        return area(of: quad) >= 0.08 ? quad : nil
    }

    /// An image's pixels as floats, row 0 at the top.
    struct Pixels {
        let width: Int, height: Int
        private let values: [Float]

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: PaintingProcessor.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            width = w; height = h
            values = bytes.map { Float($0) / 255 }
        }

        func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return SIMD3(values[i], values[i + 1], values[i + 2])
        }
    }

    /// How much a strip running along a side changes along its length, beyond slow changes in the light.
    /// A frame or mat looks much the same all the way along; a strip of painting does not.
    private static func busyness(length: Int, from: Int, to: Int, sample: (Int, Int) -> SIMD3<Float>) -> Float {
        let step = max(1, (to - from) / 6)
        let profile: [SIMD3<Float>] = (0..<length).map { a in
            var sum = SIMD3<Float>(repeating: 0), n: Float = 0
            for d in stride(from: from, to: to, by: step) { sum += sample(d, a); n += 1 }
            return sum / max(n, 1)
        }
        func smooth(_ p: [SIMD3<Float>], _ radius: Int) -> [SIMD3<Float>] {
            var prefix = [SIMD3<Float>(repeating: 0)]
            for v in p { prefix.append(prefix.last! + v) }
            return (0..<p.count).map { i in
                let lo = max(0, i - radius), hi = min(p.count, i + radius + 1)
                return (prefix[hi] - prefix[lo]) / Float(hi - lo)
            }
        }
        let fine = smooth(profile, max(1, length / 40)), coarse = smooth(profile, max(2, length / 6))
        let lo = length / 20, hi = length - length / 20
        var total: Float = 0
        for i in lo..<hi { let d = abs(fine[i] - coarse[i]); total += (d.x + d.y + d.z) / 3 }
        return total / Float(max(1, hi - lo))
    }

    /// How deep a frame's rail runs on one side, judged by its colours: the rail's colour make-up (gold, wood, a
    /// mat) holds however carved it is, until the canvas starts. The rail is sampled just inside `known` (the
    /// depth already found to be frame), or from 3% in when none was found, since the outermost pixels are often
    /// a sliver of wall. Only an end that falls on one of the side's straight `lines` counts.
    /// Whether the band just outside a line `to` pixels in from the side looks like frame: its colour make-up
    /// differs from the painting's centre and from the band just inside the line.
    private static func bandIsFrame(_ side: SideReader, to depth: Int, centre: [Float]) -> Bool {
        let span = max(4, side.across * 3 / 100)
        guard depth - span >= 1, depth + span < side.across / 2 else { return false }
        let along = Array(stride(from: side.length * 10 / 100, to: side.length * 90 / 100, by: 2))
        func histogram(_ depths: Range<Int>) -> [Float] {
            var counts = [Float](repeating: 0, count: 64)
            for d in depths { for t in along { counts[colourBin(side.sample(d, t))] += 1 } }
            let total = counts.reduce(0, +)
            return counts.map { $0 / max(total, 1) }
        }
        let outside = histogram((depth - span)..<(depth - 1)), inside = histogram((depth + 2)..<(depth + span))
        return histogramDistance(outside, centre) > 0.4 && histogramDistance(outside, inside) > 0.3
    }

    private static func railDepth(_ side: SideReader, known: Int, lines: [(depth: Int, score: Float)],
                                  centre: [Float]) -> Int? {
        let maxDepth = side.across * 35 / 100
        let span = max(4, side.across * 3 / 100)
        guard maxDepth > 16 else { return nil }
        let along = Array(stride(from: side.length * 10 / 100, to: side.length * 90 / 100, by: 2))
        // Colour make-up of a band of depths: a 4 × 4 × 4 histogram of sRGB, as fractions.
        func histogram(_ depths: Range<Int>) -> [Float] {
            var counts = [Float](repeating: 0, count: 64)
            for d in depths { for t in along { counts[colourBin(side.sample(d, t))] += 1 } }
            let total = counts.reduce(0, +)
            return counts.map { $0 / max(total, 1) }
        }
        let start = known > span + 2 ? known - span : span
        guard start + span < maxDepth else { return nil }
        let rail = histogram(start..<(start + span))
        // No frame if that band already looks like the painting's centre.
        guard histogramDistance(rail, centre) > 0.5 else { return nil }
        // Walk in while bands keep the reference's make-up. Where they change to something that still doesn't
        // look like the painting (a frame's shadow on the wall, then the frame; an outer moulding, then the
        // rail), carry on with that as the reference, up to three times.
        var reference = rail, end = start + span, segments = 0
        while true {
            var depth = end, misses = 0
            while depth + 3 <= maxDepth {
                if histogramDistance(histogram(depth..<(depth + 3)), reference) < 0.5 { end = depth + 3; misses = 0 } else { misses += 1 }
                if misses >= 2 { break }
                depth += 3
            }
            guard segments < 3, end + span < maxDepth else { break }
            let next = histogram(end..<(end + span))
            guard histogramDistance(next, centre) > 0.7, histogramDistance(next, reference) >= 0.5 else { break }
            reference = next
            end += span
            segments += 1
        }
        guard end > known + 3, end < maxDepth - 3 else { return nil }
        let near = max(4, side.across * 2 / 100)
        return lines.filter { abs($0.depth - end) <= near && $0.score >= 0.08 }.max { $0.score < $1.score }?.depth
    }

    private static func colourBin(_ c: SIMD3<Float>) -> Int {
        let r = min(3, Int(c.x * 4)), g = min(3, Int(c.y * 4)), b = min(3, Int(c.z * 4))
        return r * 16 + g * 4 + b
    }

    /// 0 for the same colour make-up, 1 for nothing in common.
    private static func histogramDistance(_ a: [Float], _ b: [Float]) -> Float {
        1 - zip(a, b).map { min($0, $1) }.reduce(0, +)
    }

    // MARK: Finding the canvas inside the frame

    /// Finds the frame's inner edge on each side of the straightened painting: the innermost straight line
    /// that runs the length of that side with a clear change of colour across it (a frame's mouldings, a mat,
    /// and the step down to the canvas all make such lines; the painting's own lines rarely run edge to edge).
    /// Returns the canvas as a quad within the straightened painting, or nil if there is no frame to remove.
    private static func findCanvas(in image: CIImage) -> [NormPoint]? {
        let e = image.extent
        let scale = min(1, 640 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: sRGB),
              let pixels = Pixels(cg), pixels.width >= 80, pixels.height >= 80 else {
            return nil
        }
        let w = pixels.width, h = pixels.height
        let pixel = pixels.at

        // For one side: `sample(depth, along)` reads the pixel `depth` in from that side.
        // Returns the depths of the straight lines found, outermost first, with their strength.
        func lines(length: Int, across: Int, sample: (Int, Int) -> SIMD3<Float>) -> [(depth: Int, score: Float)] {
            let strip = 3
            let maxDepth = Int(Double(across) * 0.25)
            guard maxDepth > strip * 2 + 2 else { return [] }
            let along = Array(stride(from: Int(Double(length) * 0.12), to: Int(Double(length) * 0.88), by: 1))
            // Colour change across each depth, for every position along the side.
            var change = [[Float]](repeating: [], count: maxDepth)
            for d in strip..<(maxDepth - strip) {
                change[d] = along.map { a in
                    var outer = SIMD3<Float>(repeating: 0), inner = SIMD3<Float>(repeating: 0)
                    for k in 1...strip {
                        outer += sample(d - k, a)
                        inner += sample(d + k - 1, a)
                    }
                    let diff = abs(outer - inner) / Float(strip)
                    return (diff.x + diff.y + diff.z) / 3
                }
            }
            // A line counts if it is there along most of the side (median), allowing it to wander by a pixel.
            var score = [Float](repeating: 0, count: maxDepth)
            for d in (strip + 1)..<(maxDepth - strip - 1) {
                var best = [Float](repeating: 0, count: along.count)
                for i in 0..<along.count {
                    best[i] = max(change[d - 1][i], change[d][i], change[d + 1][i])
                }
                best.sort()
                score[d] = best[best.count / 2]
            }
            let strongest = score.max() ?? 0
            guard strongest >= 0.06 else { return [] }
            var found: [(depth: Int, score: Float)] = []
            for d in (strip + 1)..<(maxDepth - strip - 1) {
                let lo = max(0, d - 3), hi = min(maxDepth - 1, d + 3)
                if score[d] >= 0.06, score[d] >= strongest * 0.4, score[d] == score[lo...hi].max() {
                    found.append((d, score[d]))
                }
            }
            return found
        }

        let sideReaders: [SideReader] = [
            (h, w, { d, a in pixel(d, a) }),             // left
            (h, w, { d, a in pixel(w - 1 - d, a) }),     // right
            (w, h, { d, a in pixel(a, d) }),             // top
            (w, h, { d, a in pixel(a, h - 1 - d) })      // bottom
        ]
        let sides = sideReaders.map { lines(length: $0.length, across: $0.across, sample: $0.sample) }
        /// Whether the strip outside `depth` on side `i` looks like frame rather than painting.
        func looksLikeFrame(_ i: Int, _ depth: Int) -> Bool {
            let r = sideReaders[i]
            // A thin frame is too narrow to judge, and a painting's own lines rarely sit that close to its edge.
            guard Double(depth) > Double(r.across) * 0.04 else { return true }
            let outside = busyness(length: r.length, from: 1, to: depth - 2, sample: r.sample)
            let inside = busyness(length: r.length, from: depth + 2, to: min(r.across / 2, depth + max(depth, r.across / 12)), sample: r.sample)
            return outside < 0.015 || outside < inside * 0.5
        }
        // A frame (or mat) is about as wide on every side, so look for the widest frame width that has a line
        // on at least three sides with frame, not painting, outside it; lines in the painting rarely line up like that.
        var best: (width: Int, depths: [Int])?
        for width in Set(sides.flatMap { $0.map(\.depth) }).sorted().reversed() {
            let tolerance = Double(width) * 0.35 + 4
            let picks = sides.map { side in
                side.filter { abs(Double($0.depth - width)) <= tolerance }.max { $0.score < $1.score }?.depth
            }
            guard picks.compactMap({ $0 }).count >= 3 else { continue }
            // A side with no line near this width (often the bottom, seen from below) takes its own deepest
            // frame-like line up to twice the width.
            let depths = (0..<4).map { i in
                picks[i] ?? sides[i].map(\.depth).filter { $0 <= width * 2 + 4 && looksLikeFrame(i, $0) }.max() ?? width
            }
            guard (0..<4).filter({ looksLikeFrame($0, depths[$0]) }).count >= 3 else { continue }
            // The frame's edges should be clear lines, not faint ones.
            let strengths = (0..<4).compactMap { i in sides[i].first { $0.depth == depths[i] }?.score }
            guard strengths.reduce(0, +) / Float(max(1, strengths.count)) >= 0.1 else { continue }
            best = (width, depths)
            break
        }
        var depths = best?.depths ?? [0, 0, 0, 0]

        // A carved rail is as busy as a painting, so the checks above often stop at its outer mouldings. Its
        // colours give it away: going in from the edge, bands keep the rail's colour make-up until the canvas.
        var centreCounts = [Float](repeating: 0, count: 64)
        for y in stride(from: h * 3 / 10, to: h * 7 / 10, by: 2) {
            for x in stride(from: w * 3 / 10, to: w * 7 / 10, by: 2) { centreCounts[colourBin(pixel(x, y))] += 1 }
        }
        let centreTotal = centreCounts.reduce(0, +)
        let centre = centreCounts.map { $0 / max(centreTotal, 1) }
        let rails = (0..<4).map { railDepth(sideReaders[$0], known: depths[$0], lines: sides[$0], centre: centre) }
        // Rails come in pairs: a plain background running down one side of a painting doesn't. Left and right
        // must both be found and about as deep; top and bottom may differ more (the frame's shadow below it).
        for (a, b, ratio) in [(0, 1, 0.6), (2, 3, 0.35)] {
            guard let ra = rails[a], let rb = rails[b],
                  Double(min(ra, rb)) >= Double(max(ra, rb)) * ratio else { continue }
            depths[a] = max(depths[a], ra)
            depths[b] = max(depths[b], rb)
        }

        // Hand-fixed crops showed the canvas edge is nearly always the deepest strong line on its side: a frame's
        // mouldings, lip and slip each make a line on the way in, and stopping at any of them leaves frame behind.
        // So move in to it. A painting's own lines rarely run its full length; to be safe, opposite sides must
        // land about as deep (top and bottom may differ more: the frame's shadow falls below it).
        // The band given up must look like frame, not painting: its colours unlike the painting's centre and unlike
        // what lies just inside the line (an unframed painting's own stripes and edges would otherwise be cut off).
        var deepest = depths
        // Not where no frame was seen at all: there the strong lines are the painting's own.
        let noFrameSeen = depths.allSatisfy { $0 == 0 }
        for i in 0..<4 where !noFrameSeen {
            let strongest = sides[i].map(\.score).max() ?? 0
            let candidates = sides[i].filter { $0.depth > depths[i] && $0.score >= max(0.12, strongest * 0.5) }.map(\.depth)
            if let line = candidates.sorted().reversed().first(where: { bandIsFrame(sideReaders[i], to: $0, centre: centre) }) {
                deepest[i] = line
            }
        }
        for (a, b, ratio) in [(0, 1, 0.6), (2, 3, 0.3)] {
            let da = Double(deepest[a]) / Double(sideReaders[a].across)
            let db = Double(deepest[b]) / Double(sideReaders[b].across)
            if min(da, db) >= max(da, db) * ratio || max(da, db) < 0.03 {
                depths[a] = deepest[a]
                depths[b] = deepest[b]
            } else if da < db {
                depths[a] = deepest[a]      // unpaired: keep only the shallower side's move
            } else {
                depths[b] = deepest[b]
            }
        }

        // Then, side by side, trim a leftover sliver of frame: a narrow strip at the edge that is plain along
        // its length, ends at a strong straight line, and is plainly quieter than the painting inside it.
        for i in 0..<4 {
            let r = sideReaders[i]
            let reach = depths[i] + max(4, r.across * 6 / 100)
            let candidates = sides[i].filter { $0.depth > depths[i] + 2 && $0.depth <= reach && $0.score >= 0.12 }
            for line in candidates.reversed() {
                let strip = busyness(length: r.length, from: depths[i] + 1, to: line.depth - 1, sample: r.sample)
                let inside = busyness(length: r.length, from: line.depth + 2,
                                      to: min(r.across / 2, line.depth + max(8, r.across / 12)), sample: r.sample)
                if strip < 0.012 || strip < inside * 0.4 {
                    depths[i] = line.depth
                    break
                }
            }
        }
        guard depths.contains(where: { $0 > 0 }) else { return nil }

        guard let quad = quad(depths: depths, sides: sideReaders, width: w, height: h) else { return nil }
        let bb = boundingBox(of: quad)
        guard bb.width > 0.3, bb.height > 0.3 else { return nil }
        return quad
    }

    typealias SideReader = (length: Int, across: Int, sample: (Int, Int) -> SIMD3<Float>)

    /// The quad bounded by an edge at `depths[i]` in from each side (left, right, top, bottom; 0 = the image's
    /// own edge) of a `width` × `height` image. Each edge is refitted as a straight line that may lean slightly,
    /// when a leaning line follows the edge better: a painting a little rotated or skewed is then straightened.
    private static func quad(depths: [Int], sides: [SideReader], width w: Int, height h: Int) -> [NormPoint]? {
        func fit(_ side: SideReader, near depth: Int) -> (Double, Double) {
            let a = Double(side.length) * 0.2, b = Double(side.length) * 0.8
            let reach = max(2, side.across * 2 / 100)
            let samples = Array(stride(from: side.length / 10, to: side.length - side.length / 10, by: 3))
            func contrast(_ atA: Int, _ atB: Int) -> Float {
                var diffs = samples.map { t -> Float in
                    let d = Int((Double(atA) + Double(atB - atA) * (Double(t) - a) / (b - a)).rounded())
                    var o = SIMD3<Float>(repeating: 0), n = SIMD3<Float>(repeating: 0)
                    for k in 1...3 { o += side.sample(d - k, t); n += side.sample(d + k - 1, t) }
                    let diff = abs(o - n) / 3
                    return (diff.x + diff.y + diff.z) / 3
                }
                diffs.sort()
                return diffs[diffs.count / 2]
            }
            var best = (depth, depth, contrast(depth, depth))
            for atA in max(4, depth - reach)...(depth + reach) {
                for atB in max(4, depth - reach)...(depth + reach) where atA != atB {
                    let c = contrast(atA, atB)
                    if c > best.2 * 1.08 { best = (atA, atB, c) }
                }
            }
            // The deeper end, plus a little more, so no sliver of the frame's lip is left at either end.
            return (Double(best.0 + 2), Double(best.1 + 2))
        }

        typealias Line = (p: SIMD2<Double>, q: SIMD2<Double>)
        var edges: [Line] = []
        for (i, side) in sides.enumerated() {
            let a = Double(side.length) * 0.2, b = Double(side.length) * 0.8
            let (dA, dB) = depths[i] > 0 ? fit(side, near: depths[i]) : (0, 0)
            switch i {
            case 0: edges.append((SIMD2(dA, a), SIMD2(dB, b)))
            case 1: edges.append((SIMD2(Double(w) - dA, a), SIMD2(Double(w) - dB, b)))
            case 2: edges.append((SIMD2(a, dA), SIMD2(b, dB)))
            default: edges.append((SIMD2(a, Double(h) - dA), SIMD2(b, Double(h) - dB)))
            }
        }
        func meet(_ l: Line, _ m: Line) -> SIMD2<Double>? {
            let d1 = l.q - l.p, d2 = m.q - m.p
            let denominator = d1.x * d2.y - d1.y * d2.x
            guard abs(denominator) > 1e-9 else { return nil }
            let t = ((m.p.x - l.p.x) * d2.y - (m.p.y - l.p.y) * d2.x) / denominator
            return l.p + d1 * t
        }
        guard let tl = meet(edges[2], edges[0]), let tr = meet(edges[2], edges[1]),
              let br = meet(edges[3], edges[1]), let bl = meet(edges[3], edges[0]) else { return nil }
        // Bottom-left origin, as Vision gives quads: top-left, top-right, bottom-right, bottom-left.
        return [tl, tr, br, bl].map { NormPoint(x: min(max($0.x / Double(w), 0), 1), y: min(max(1 - $0.y / Double(h), 0), 1)) }
    }

    private static func area(of quad: [NormPoint]) -> CGFloat {
        var sum: Double = 0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return CGFloat(abs(sum) / 2)
    }

    private static func center(of quad: [NormPoint]) -> CGPoint {
        CGPoint(x: quad.map(\.x).reduce(0, +) / 4, y: quad.map(\.y).reduce(0, +) / 4)
    }

    private static func boundingBox(of quad: [NormPoint]) -> CGRect {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1, minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The painting straightened and, when its true shape is known, stretched back to it.
    private static func flattenPainting(_ image: CIImage, settings: ProcessingSettings) -> CIImage {
        guard let quad = settings.paintingQuad else { return image }
        let flat = flatten(image, quad: quad)
        guard let aspect = settings.aspect, flat.extent.height > 0 else { return flat }
        let current = Double(flat.extent.width / flat.extent.height)
        // Stretch the shorter way rather than shrink, so no detail is lost.
        let sx = aspect > current ? aspect / current : 1, sy = aspect > current ? 1 : current / aspect
        return flat.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    private static func smallPixels(_ image: CIImage) -> Pixels? {
        let e = image.extent
        let scale = min(1, 640 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            return nil
        }
        return Pixels(cg)
    }

    /// Whether what lies just outside the quad looks like wall or frame (plain along its length) rather than more
    /// painting. An outline found inside a painting has busy picture around it. Sides at the photo's edge are
    /// skipped; at least `share` of the rest must look plain.
    enum Strictness { case lenient, strict, wallOnly }

    private static func surroundingsLookPlain(_ quad: [NormPoint], in px: Pixels, strictness: Strictness, share: Double) -> Bool {
        let w = px.width, h = px.height
        let bb = boundingBox(of: quad)
        let x0 = Int(bb.minX * CGFloat(w)), x1 = Int(bb.maxX * CGFloat(w))
        let y0 = Int((1 - bb.maxY) * CGFloat(h)), y1 = Int((1 - bb.minY) * CGFloat(h)) // row 0 at the top
        let gapX = max(2, w / 100), gapY = max(2, h / 100), stripX = max(6, w / 25), stripY = max(6, h / 25)
        var plain = 0, checked = 0
        func check(length: Int, outsideRoom: Int, strip: Int, insideRoom: Int, sample: @escaping (Int, Int) -> SIMD3<Float>) {
            // `sample(depth, along)`: depth 0 is the quad's edge, negative outward.
            guard outsideRoom >= strip + 2, length >= 40, insideRoom >= strip * 2 else { return }
            let gap = strip / 3
            let outside = busyness(length: length, from: 0, to: strip) { d, a in sample(-(d + gap), a) }
            let inside = busyness(length: length, from: 0, to: strip) { d, a in sample(d + gap, a) }
            checked += 1
            switch strictness {
            case .lenient: if outside < 0.015 || outside < inside * 0.6 { plain += 1 }
            case .strict: if outside < 0.012 || outside < inside * 0.5 { plain += 1 }
            case .wallOnly: if outside < 0.01 { plain += 1 }
            }
        }
        check(length: y1 - y0, outsideRoom: x0 - gapX, strip: stripX, insideRoom: x1 - x0) { d, a in px.at(x0 + d, y0 + a) }
        check(length: y1 - y0, outsideRoom: w - x1 - gapX, strip: stripX, insideRoom: x1 - x0) { d, a in px.at(x1 - d, y0 + a) }
        check(length: x1 - x0, outsideRoom: y0 - gapY, strip: stripY, insideRoom: y1 - y0) { d, a in px.at(x0 + a, y0 + d) }
        check(length: x1 - x0, outsideRoom: h - y1 - gapY, strip: stripY, insideRoom: y1 - y0) { d, a in px.at(x0 + a, y1 - d) }
        return checked == 0 || Double(plain) >= Double(checked) * share - 0.001
    }

    /// Whether the quad is a line on the wall rather than a painting's edge: on at least three sides, the strips
    /// just inside and just outside are both plain and the same colour (the same wall on both sides).
    private static func isWallFeature(_ quad: [NormPoint], in px: Pixels) -> Bool {
        let w = px.width, h = px.height
        let bb = boundingBox(of: quad)
        let x0 = Int(bb.minX * CGFloat(w)), x1 = Int(bb.maxX * CGFloat(w))
        let y0 = Int((1 - bb.maxY) * CGFloat(h)), y1 = Int((1 - bb.minY) * CGFloat(h)) // row 0 at the top
        let strip = max(5, min(w, h) / 30), gap = max(2, strip / 2)
        var sameWall = 0
        func check(length: Int, room: Int, inside insideRoom: Int, sample: @escaping (Int, Int) -> SIMD3<Float>) {
            // `sample(depth, along)`: depth 0 is the quad's edge, negative outward.
            guard room >= strip + gap, insideRoom >= (strip + gap) * 2, length >= 40 else { return }
            func band(_ sign: Int) -> (SIMD3<Float>, Float) {
                let pick: (Int, Int) -> SIMD3<Float> = { d, a in sample(sign * (d + gap), a) }
                var sum = SIMD3<Float>(repeating: 0), n: Float = 0
                for d in stride(from: 0, to: strip, by: 2) {
                    for a in stride(from: length / 10, to: length - length / 10, by: 3) { sum += pick(d, a); n += 1 }
                }
                return (sum / max(n, 1), busyness(length: length, from: 0, to: strip, sample: pick))
            }
            let (outColour, outBusy) = band(-1), (inColour, inBusy) = band(1)
            let d = abs(outColour - inColour)
            if outBusy < 0.01, inBusy < 0.01, (d.x + d.y + d.z) / 3 < 0.03 { sameWall += 1 }
        }
        check(length: y1 - y0, room: x0, inside: x1 - x0) { d, a in px.at(x0 + d, y0 + a) }
        check(length: y1 - y0, room: w - x1, inside: x1 - x0) { d, a in px.at(x1 - d, y0 + a) }
        check(length: x1 - x0, room: y0, inside: y1 - y0) { d, a in px.at(x0 + a, y0 + d) }
        check(length: x1 - x0, room: h - y1, inside: y1 - y0) { d, a in px.at(x0 + a, y1 - d) }
        return sameWall >= 3
    }

    /// The painting's outline squared up from the frame's edges. The image is straightened with `quad`; if the
    /// strongest straight edges along at least three sides of the result still visibly lean, they are taken as the
    /// frame's sides and the outline is rebuilt from them (a missing fourth side keeps the image's edge).
    /// Nil if the edges are already square or unclear.
    private static func straighten(_ quad: [NormPoint], in base: CIImage) -> [NormPoint]? {
        let flat = flatten(base, quad: quad)
        guard let cg = context.createCGImage(flat, from: flat.extent.integral, format: .RGBA8, colorSpace: sRGB),
              let map = EdgeMap(cg, depth: 0.3) else { return nil }
        let w = Double(map.width), h = Double(map.height)
        let lines = (0..<4).map { map.bestLine(side: $0, maxAngle: 20) }
        let strong = lines.map { $0.count >= EdgeMap.positions * 4 / 10 }
        guard strong.filter({ $0 }).count >= 3,
              (0..<4).contains(where: { strong[$0] && abs(lines[$0].angle) > 1.5 * .pi / 180 }) else { return nil }

        // Each side as n · p = offset, in pixels with row 0 at the top.
        let sides: [(n: SIMD2<Double>, offset: Double)] = (0..<4).map { i in
            guard strong[i] else {
                switch i {
                case 0: return (SIMD2(1, 0), 0)
                case 1: return (SIMD2(1, 0), w)
                case 2: return (SIMD2(0, 1), 0)
                default: return (SIMD2(0, 1), h)
                }
            }
            let a = lines[i].angle
            return (i < 2 ? SIMD2(cos(a), sin(a)) : SIMD2(sin(a), cos(a)), lines[i].offset)
        }
        func meet(_ i: Int, _ j: Int) -> SIMD2<Double>? {
            let (n1, c1) = sides[i], (n2, c2) = sides[j]
            let det = n1.x * n2.y - n1.y * n2.x
            guard abs(det) > 1e-9 else { return nil }
            return SIMD2((c1 * n2.y - c2 * n1.y) / det, (n1.x * c2 - n2.x * c1) / det)
        }
        guard let tl = meet(2, 0), let tr = meet(2, 1), let br = meet(3, 1), let bl = meet(3, 0) else { return nil }
        // In the straightened image, bottom-left origin.
        let inner = [tl, tr, br, bl].map { NormPoint(x: $0.x / w, y: 1 - $0.y / h) }
        // Only ever tighten the outline (growing it would bring back frame already left outside).
        guard inner.allSatisfy({ $0.x > -0.02 && $0.x < 1.02 && $0.y > -0.02 && $0.y < 1.02 }),
              isConvex(inner) else { return nil }
        // A whole frame (long, clear edges on all four sides) may sit well inside the outline, e.g. a big painting
        // in a room; with only three sides found, the outline mustn't shrink much (a line in the painting).
        let wholeFrame = lines.allSatisfy { $0.count >= EdgeMap.positions * 6 / 10 }
        guard area(of: inner) > (wholeFrame ? 0.35 : 0.6) else { return nil }
        // Back into the photo, through the perspective that straightened it.
        let toPhoto = squareToQuad(quad)
        return inner.map { toPhoto($0) }
    }

    private static func isConvex(_ quad: [NormPoint]) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4], c = quad[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross == 0 { return false }
            if sign == 0 { sign = cross } else if (sign > 0) != (cross > 0) { return false }
        }
        return true
    }

    /// The perspective mapping from the unit square (bottom-left origin) onto `quad` (top-left, top-right,
    /// bottom-right, bottom-left), as used to straighten it (Heckbert's square-to-quad).
    private static func squareToQuad(_ quad: [NormPoint]) -> (NormPoint) -> NormPoint {
        let p0 = quad[3], p1 = quad[2], p2 = quad[1], p3 = quad[0] // (0,0), (1,0), (1,1), (0,1)
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y
        var g = 0.0, h = 0.0
        let det = dx1 * dy2 - dx2 * dy1
        if abs(det) > 1e-12 {
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
        }
        let a = p1.x - p0.x + g * p1.x, b = p3.x - p0.x + h * p3.x, c = p0.x
        let d = p1.y - p0.y + g * p1.y, e = p3.y - p0.y + h * p3.y, f = p0.y
        return { p in
            let z = g * p.x + h * p.y + 1
            return NormPoint(x: (a * p.x + b * p.y + c) / z, y: (d * p.x + e * p.y + f) / z)
        }
    }

    /// Width ÷ height of the quad's sides as they appear in the photo.
    private static func naiveAspect(of quad: [NormPoint], in size: CGSize) -> Double {
        func length(_ a: NormPoint, _ b: NormPoint) -> Double {
            hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
        }
        let width = (length(quad[0], quad[1]) + length(quad[3], quad[2])) / 2
        let height = (length(quad[0], quad[3]) + length(quad[1], quad[2])) / 2
        return height > 0 ? width / height : 1
    }

    /// The painting's real width ÷ height. A rectangle seen at an angle looks narrower than it is; knowing the
    /// lens's focal length undoes that (Zhang & He's method for photographed whiteboards). Without the focal
    /// length it is estimated from the corners when they are skewed enough to tell. Nil if no better than the
    /// corners' own shape.
    private static func trueAspect(of quad: [NormPoint], in size: CGSize, focal35: Double?) -> Double? {
        // Corners in pixels, relative to the centre of the photo.
        func corner(_ n: NormPoint) -> SIMD3<Double> {
            SIMD3((n.x - 0.5) * size.width, (n.y - 0.5) * size.height, 1)
        }
        let m1 = corner(quad[0]), m2 = corner(quad[1]), m3 = corner(quad[3]), m4 = corner(quad[2]) // TL, TR, BL, BR
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
        let d2 = dot(cross(m2, m4), m3), d3 = dot(cross(m3, m4), m2)
        guard abs(d2) > 1e-9, abs(d3) > 1e-9 else { return nil }
        let k2 = dot(cross(m1, m4), m3) / d2, k3 = dot(cross(m1, m4), m2) / d3
        let n2 = k2 * m2 - m1, n3 = k3 * m3 - m1

        let diagonal = hypot(Double(size.width), Double(size.height))
        var f2: Double
        if let focal35 {
            let f = focal35 / 43.27 * diagonal // 43.27 mm: the diagonal of a 35 mm frame
            f2 = f * f
        } else {
            // Estimate from the corners; only reliable when the painting is clearly seen at an angle.
            guard abs(n2.z) > 0.02, abs(n3.z) > 0.02 else { return nil }
            f2 = -(n2.x * n3.x + n2.y * n3.y) / (n2.z * n3.z)
            guard f2 > 0, sqrt(f2) > diagonal * 0.4, sqrt(f2) < diagonal * 3 else { return nil }
        }
        let w = sqrt((n2.x * n2.x + n2.y * n2.y) / f2 + n2.z * n2.z)
        let h = sqrt((n3.x * n3.x + n3.y * n3.y) / f2 + n3.z * n3.z)
        guard h > 0 else { return nil }
        let aspect = w / h, naive = naiveAspect(of: quad, in: size)
        let change = aspect / naive
        // Ignore tiny corrections, and distrust huge ones (usually a wrong corner).
        guard abs(change - 1) > 0.015, change > 0.67, change < 1.5 else { return nil }
        return aspect
    }

    /// Straightens the quad into a flat rectangle. Vision and Core Image both use a bottom-left origin.
    private static func flatten(_ image: CIImage, quad: [NormPoint]) -> CIImage {
        let e = image.extent
        func point(_ n: NormPoint) -> CIVector {
            CIVector(cgPoint: CGPoint(x: e.minX + n.x * e.width, y: e.minY + n.y * e.height))
        }
        let flat = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(quad[0]),
            "inputTopRight": point(quad[1]),
            "inputBottomRight": point(quad[2]),
            "inputBottomLeft": point(quad[3])
        ])
        return flat.transformed(by: CGAffineTransform(translationX: -flat.extent.minX, y: -flat.extent.minY))
    }

    // MARK: Reading the wall

    struct WallSample {
        var left: SIMD3<Float>?
        var right: SIMD3<Float>?
        var top: SIMD3<Float>?
        var bottom: SIMD3<Float>?

        var average: SIMD3<Float>? {
            let sides = [left, right, top, bottom].compactMap { $0 }
            guard !sides.isEmpty else { return nil }
            return sides.reduce(SIMD3<Float>(repeating: 0), +) / Float(sides.count)
        }
    }

    /// Averages four strips of wall just outside the painting, leaving a small gap for the frame's shadow.
    private static func sampleWall(around quad: [NormPoint], in image: CIImage) -> WallSample {
        let e = image.extent
        let bb = boundingBox(of: quad)
        let box = CGRect(
            x: e.minX + bb.minX * e.width,
            y: e.minY + bb.minY * e.height,
            width: bb.width * e.width,
            height: bb.height * e.height
        )
        let m = 0.10 * max(box.width, box.height)
        let gap = 0.25 * m
        return WallSample(
            left: average(image, CGRect(x: box.minX - gap - m, y: box.minY, width: m, height: box.height)),
            right: average(image, CGRect(x: box.maxX + gap, y: box.minY, width: m, height: box.height)),
            top: average(image, CGRect(x: box.minX, y: box.maxY + gap, width: box.width, height: m)),
            bottom: average(image, CGRect(x: box.minX, y: box.minY - gap - m, width: box.width, height: m))
        )
    }

    /// Linear-light average colour of a region, or nil if too little of it is inside the photo.
    private static func average(_ image: CIImage, _ rect: CGRect) -> SIMD3<Float>? {
        let r = rect.intersection(image.extent)
        guard !r.isNull, r.width > 8, r.height > 8, r.width * r.height > rect.width * rect.height * 0.4 else { return nil }
        let out = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(origin: out.extent.origin, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: linearSpace)
        return SIMD3(pixel[0], pixel[1], pixel[2])
    }

    /// How much to trust the wall as a neutral reference (0...1).
    /// A warm or cool cast along the warm–cool axis looks like the colour of the light, so it is corrected fully.
    /// A cast off that axis (a red, green or blue painted wall) is the wall's own colour, so it is left alone.
    // MARK: Applying the corrections

    /// Applies white balance, spotlight gains and exposure. When the recipe has no exposure yet,
    /// it is worked out from the painting's brightness range and stored back into `settings`.
    private static func applyCorrections(to image: CGImage, settings: inout ProcessingSettings) throws -> CGImage {
        let w = image.width, h = image.height
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ProcessingError.renderFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { throw ProcessingError.renderFailed }
        let px = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Lookup tables between sRGB bytes and linear light.
        let toLinear: [Float] = (0..<256).map { i in
            let c = Float(i) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        let lutSize = 4096
        let toSRGB: [UInt8] = (0..<lutSize).map { i in
            let l = Float(i) / Float(lutSize - 1)
            let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, (c * 255).rounded())))
        }

        // Spotlight correction per column and per row (row 0 is the top).
        let gl = settings.gainLeft, gr = settings.gainRight, gt = settings.gainTop, gb = settings.gainBottom
        let colGain: [Float] = (0..<w).map { x in gl + (gr - gl) * Float(x) / Float(w - 1) }
        let rowGain: [Float] = (0..<h).map { y in gt + (gb - gt) * Float(y) / Float(h - 1) }
        let wb = [settings.whiteBalance.x, settings.whiteBalance.y, settings.whiteBalance.z]

        if settings.blackPoint == nil || settings.exposure == nil {
            // Brightness range after colour and spotlight correction (sampled).
            var histogram = [Int](repeating: 0, count: 1024)
            let stride = max(1, (w * h) / 300_000)
            toLinear.withUnsafeBufferPointer { lin in
                var i = 0
                while i < w * h {
                    let g = colGain[i % w] * rowGain[i / w]
                    let o = i * 4
                    let r = lin[Int(px[o])] * wb[0] * g
                    let gg = lin[Int(px[o + 1])] * wb[1] * g
                    let b = lin[Int(px[o + 2])] * wb[2] * g
                    let l = 0.2126 * r + 0.7152 * gg + 0.0722 * b
                    histogram[min(1023, max(0, Int(l * 1023)))] += 1
                    i += stride
                }
            }
            let total = histogram.reduce(0, +)
            func percentile(_ p: Float) -> Float {
                let target = Int(Float(total) * p)
                var running = 0
                for (k, count) in histogram.enumerated() {
                    running += count
                    if running >= target { return Float(k) / 1023 }
                }
                return 1
            }
            let low = percentile(0.003), high = percentile(0.997)

            // Gentle exposure: lift only a little black, bring the brightest paint to about 95% (sRGB).
            let black = min(low * 0.8, 0.02)
            settings.blackPoint = black
            settings.exposure = clamp(0.9 / max(high - black, 0.05), 0.8, 2.0)
        }
        let black = settings.blackPoint ?? 0
        let exposure = settings.exposure ?? 1

        toLinear.withUnsafeBufferPointer { lin in
            toSRGB.withUnsafeBufferPointer { out in
                let top = Float(lutSize - 1)
                for y in 0..<h {
                    let rg = rowGain[y]
                    for x in 0..<w {
                        let g = colGain[x] * rg
                        let o = (y * w + x) * 4
                        for c in 0..<3 {
                            var v = (lin[Int(px[o + c])] * wb[c] * g - black) * exposure
                            v = max(0, min(1, v))
                            px[o + c] = out[Int(v * top)]
                        }
                        px[o + 3] = 255
                    }
                }
            }
        }

        guard let result = ctx.makeImage() else { throw ProcessingError.renderFailed }
        return result
    }

    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { max(lo, min(hi, v)) }
}

private extension SIMD3 where Scalar == Float {
    var sum: Float { x + y + z }
}
