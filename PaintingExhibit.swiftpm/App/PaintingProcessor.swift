import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Vision
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

/// The non-destructive edit recipe for one painting. The photo in Photos is never changed;
/// the exhibit image is drawn from the original with these values, and can be redrawn at any time.
struct ProcessingSettings: Codable, Hashable {
    /// The painting (outer frame edge) in the photo: top-left, top-right, bottom-right, bottom-left.
    var paintingQuad: [NormPoint]?
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

    /// How far the wall was trusted as a neutral reference (0...1).
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
    static func analyzeAndRender(imageData: Data, keepFrame: Bool, writeTo url: URL) throws -> ProcessingSettings {
        let (base, baseCG) = try prepare(imageData)
        let settings = analyze(base: base, baseCG: baseCG, keepFrame: keepFrame, focal35: focalLength35(of: imageData))
        return try render(base: base, settings: settings, writeTo: url)
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
        let (base, _) = try prepare(imageData, maxDimension: maxDimension)
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

    private static func analyze(base: CIImage, baseCG: CGImage, keepFrame: Bool, focal35: Double?) -> ProcessingSettings {
        var settings = ProcessingSettings(
            paintingQuad: nil, canvasQuad: nil, keptFrame: keepFrame,
            lightStrength: 0, whiteBalance: SIMD3(1, 1, 1),
            gainLeft: 1, gainRight: 1, gainTop: 1, gainBottom: 1
        )

        // 1. Find the painting: a clear rectangle first, then the main flat object, then (for a close-up)
        // the whole photo, if a frame can be found running along its edges. Thin strips are skipped: they are usually a band across the painting, not the painting.
        let size = base.extent.size
        let plausible: (CGFloat, CGPoint) -> Bool = { area, _ in area >= 0.08 }
        let pixels = smallPixels(base)
        func shaped(_ quad: [NormPoint]?) -> [NormPoint]? {
            guard let quad else { return nil }
            let ratio = naiveAspect(of: quad, in: size)
            guard ratio > 1 / 3.2, ratio < 3.2 else { return nil }
            // A long, thin outline is more often a band across the painting, so it needs plain surroundings on every side.
            let elongated = ratio > 2.2 || ratio < 1 / 2.2
            if let pixels, !surroundingsLookPlain(quad, in: pixels, allSides: elongated) { return nil }
            return quad
        }
        let wholePhoto = [NormPoint(x: 0, y: 1), NormPoint(x: 1, y: 1), NormPoint(x: 1, y: 0), NormPoint(x: 0, y: 0)]
        guard let quad = shaped(largestQuad(in: baseCG, minimumSize: 0.2, accept: plausible))
                ?? shaped(documentQuad(in: baseCG))
                // A close-up, with the frame running off the edges of the photo: the frame can still be found.
                ?? (findCanvas(in: base) != nil ? wholePhoto : nil) else {
            return settings
        }
        settings.paintingQuad = quad
        settings.aspect = quad == wholePhoto ? nil : trueAspect(of: quad, in: size, focal35: focal35)
        let wall = sampleWall(around: quad, in: base)
        settings.wallLeft = wall.left
        settings.wallRight = wall.right
        settings.wallTop = wall.top
        settings.wallBottom = wall.bottom

        // 2. Look for the canvas inside the frame (always, so the frame choice can change later).
        settings.canvasQuad = findCanvas(in: flattenPainting(base, settings: settings))

        // 3. Work out the corrections from the wall.
        if let average = wall.average {
            let strength = lightStrength(for: average)
            settings.lightStrength = strength
            let luminance = (average.x + average.y + average.z) / 3
            for c in 0..<3 {
                let full = clamp(luminance / max(average[c], 0.0001), 0.5, 2.2)
                settings.whiteBalance[c] = 1 + (full - 1) * strength
            }

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

    /// The largest rectangle Vision finds that passes `accept(area, center)`, in normalized coordinates,
    /// as top-left, top-right, bottom-right, bottom-left.
    private static func largestQuad(
        in image: CGImage,
        minimumSize: Float,
        confidence: Float = 0.4,
        tolerance: Float = 25,
        accept: (CGFloat, CGPoint) -> Bool
    ) -> [NormPoint]? {
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
            return nil
        }
        let quads = (request.results ?? []).map { o in
            [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { NormPoint(x: Double($0.x), y: Double($0.y)) }
        }
        return quads
            .filter { accept(area(of: $0), center(of: $0)) }
            .max { area(of: $0) < area(of: $1) }
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

        typealias Side = (length: Int, across: Int, sample: (Int, Int) -> SIMD3<Float>)
        let sideReaders: [Side] = [
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

        // Trim a hair more, so no sliver of the frame's lip is left.
        let l = Double(depths[0] + 2) / Double(w), r = Double(depths[1] + 2) / Double(w)
        let t = Double(depths[2] + 2) / Double(h), b = Double(depths[3] + 2) / Double(h)
        guard l + r < 0.7, t + b < 0.7 else { return nil }
        // Bottom-left origin, as Vision gives quads: top-left, top-right, bottom-right, bottom-left.
        return [NormPoint(x: l, y: 1 - t), NormPoint(x: 1 - r, y: 1 - t), NormPoint(x: 1 - r, y: b), NormPoint(x: l, y: b)]
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
    /// skipped; at least half of the rest (or all, with `allSides`) must look plain.
    private static func surroundingsLookPlain(_ quad: [NormPoint], in px: Pixels, allSides: Bool) -> Bool {
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
            if outside < 0.015 || outside < inside * 0.6 { plain += 1 }
        }
        check(length: y1 - y0, outsideRoom: x0 - gapX, strip: stripX, insideRoom: x1 - x0) { d, a in px.at(x0 + d, y0 + a) }
        check(length: y1 - y0, outsideRoom: w - x1 - gapX, strip: stripX, insideRoom: x1 - x0) { d, a in px.at(x1 - d, y0 + a) }
        check(length: x1 - x0, outsideRoom: y0 - gapY, strip: stripY, insideRoom: y1 - y0) { d, a in px.at(x0 + a, y0 + d) }
        check(length: x1 - x0, outsideRoom: h - y1 - gapY, strip: stripY, insideRoom: y1 - y0) { d, a in px.at(x0 + a, y1 - d) }
        return checked == 0 || (allSides ? plain == checked : plain * 2 >= checked)
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
    private static func lightStrength(for wall: SIMD3<Float>) -> Float {
        let r = log(max(wall.x, 0.0001)), g = log(max(wall.y, 0.0001)), b = log(max(wall.z, 0.0001))
        let offAxis = abs(g - (r + b) / 2)
        if offAxis < 0.1 { return 1 }
        if offAxis > 0.3 { return 0 }
        return 1 - (offAxis - 0.1) / 0.2
    }

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
