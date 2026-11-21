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

struct ProcessingResult {
    var cropFound: Bool
    var frameRemoved: Bool
    var lightCorrection: Double
    var unevenLightFixed: Bool
}

/// Crops a painting out of a museum photo and corrects its lighting,
/// using the wall around the painting as the reference.
///
/// Steps:
/// 1. Find the painting (frame) as a rectangle and flatten its perspective.
/// 2. Look inside that for the canvas edge, to drop the frame.
/// 3. Sample the wall just outside the frame on each side:
///    - its average colour gives the colour of the light (white balance),
///    - the difference between sides gives the spotlight falloff.
/// 4. Apply the white balance and the inverse falloff to the canvas,
///    then gently set exposure from the painting's own brightness range.
enum PaintingProcessor {
    static let maxDimension: CGFloat = 2400

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false
    ])

    static func process(imageData: Data, writeTo url: URL) throws -> ProcessingResult {
        // Load, apply the photo's orientation, and scale down.
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
        let base = CIImage(cgImage: baseCG)

        var result = ProcessingResult(cropFound: false, frameRemoved: false, lightCorrection: 0, unevenLightFixed: false)

        // 1. Find the painting.
        var painting = base
        var wall: WallSample?
        if let quad = largestQuad(in: baseCG, minimumSize: 0.2, accept: { area, _ in area >= 0.08 }) {
            result.cropFound = true
            wall = sampleWall(around: quad, in: base)
            painting = flatten(base, quad: quad)

            // 2. Look for the canvas inside the frame.
            if let flatCG = context.createCGImage(painting, from: painting.extent.integral, format: .RGBA8, colorSpace: sRGB),
               let inner = largestQuad(in: flatCG, minimumSize: 0.5, accept: { area, center in
                   area > 0.45 && area < 0.97 && abs(center.x - 0.5) < 0.1 && abs(center.y - 0.5) < 0.1
               }) {
                painting = flatten(painting, quad: inner)
                result.frameRemoved = true
            }
        }

        guard let paintingCG = context.createCGImage(painting, from: painting.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            throw ProcessingError.renderFailed
        }

        // 3. Work out the corrections from the wall.
        var whiteBalance = SIMD3<Float>(1, 1, 1)
        var gainLeft: Float = 1, gainRight: Float = 1, gainTop: Float = 1, gainBottom: Float = 1

        if let wall, let average = wall.average {
            let strength = lightStrength(for: average)
            result.lightCorrection = Double(strength)
            let luminance = (average.x + average.y + average.z) / 3
            for c in 0..<3 {
                let full = clamp(luminance / max(average[c], 0.0001), 0.5, 2.2)
                whiteBalance[c] = 1 + (full - 1) * strength
            }

            // Spotlight falloff: brighten the side of the canvas next to the darker wall.
            if let l = wall.left, let r = wall.right {
                let ll = l.sum / 3, lr = r.sum / 3, mean = (ll + lr) / 2
                gainLeft = clamp(mean / max(ll, 0.0001), 0.75, 1.33)
                gainRight = clamp(mean / max(lr, 0.0001), 0.75, 1.33)
                result.unevenLightFixed = true
            }
            if let t = wall.top, let b = wall.bottom {
                let lt = t.sum / 3, lb = b.sum / 3, mean = (lt + lb) / 2
                gainTop = clamp(mean / max(lt, 0.0001), 0.75, 1.33)
                gainBottom = clamp(mean / max(lb, 0.0001), 0.75, 1.33)
                result.unevenLightFixed = true
            }
        }

        // 4. Apply.
        let output = try applyCorrections(
            to: paintingCG,
            whiteBalance: whiteBalance,
            gainLeft: gainLeft, gainRight: gainRight,
            gainTop: gainTop, gainBottom: gainBottom
        )

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProcessingError.writeFailed
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProcessingError.writeFailed }
        return result
    }

    // MARK: Finding the painting

    /// The largest rectangle Vision finds that passes `accept(area, center)`, in normalized coordinates.
    private static func largestQuad(
        in image: CGImage,
        minimumSize: Float,
        accept: (CGFloat, CGPoint) -> Bool
    ) -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1.0
        request.minimumSize = minimumSize
        request.maximumObservations = 8
        request.quadratureTolerance = 25
        request.minimumConfidence = 0.4
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let candidates = (request.results ?? []).filter { accept(area(of: $0), center(of: $0)) }
        return candidates.max { area(of: $0) < area(of: $1) }
    }

    private static func area(of quad: VNRectangleObservation) -> CGFloat {
        let p = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private static func center(of quad: VNRectangleObservation) -> CGPoint {
        CGPoint(
            x: (quad.topLeft.x + quad.topRight.x + quad.bottomLeft.x + quad.bottomRight.x) / 4,
            y: (quad.topLeft.y + quad.topRight.y + quad.bottomLeft.y + quad.bottomRight.y) / 4
        )
    }

    /// Straightens the quad into a flat rectangle. Vision and Core Image both use a bottom-left origin.
    private static func flatten(_ image: CIImage, quad: VNRectangleObservation) -> CIImage {
        let e = image.extent
        func point(_ n: CGPoint) -> CIVector {
            CIVector(cgPoint: CGPoint(x: e.minX + n.x * e.width, y: e.minY + n.y * e.height))
        }
        let flat = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(quad.topLeft),
            "inputTopRight": point(quad.topRight),
            "inputBottomLeft": point(quad.bottomLeft),
            "inputBottomRight": point(quad.bottomRight)
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
    private static func sampleWall(around quad: VNRectangleObservation, in image: CIImage) -> WallSample {
        let e = image.extent
        let box = CGRect(
            x: e.minX + quad.boundingBox.minX * e.width,
            y: e.minY + quad.boundingBox.minY * e.height,
            width: quad.boundingBox.width * e.width,
            height: quad.boundingBox.height * e.height
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

    private static func applyCorrections(
        to image: CGImage,
        whiteBalance: SIMD3<Float>,
        gainLeft: Float, gainRight: Float,
        gainTop: Float, gainBottom: Float
    ) throws -> CGImage {
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
        let colGain: [Float] = (0..<w).map { x in gainLeft + (gainRight - gainLeft) * Float(x) / Float(w - 1) }
        let rowGain: [Float] = (0..<h).map { y in gainTop + (gainBottom - gainTop) * Float(y) / Float(h - 1) }
        let wb = [whiteBalance.x, whiteBalance.y, whiteBalance.z]

        // Pass 1: brightness range after colour and spotlight correction (sampled).
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
        let exposure = clamp(0.9 / max(high - black, 0.05), 0.8, 2.0)

        // Pass 2: apply everything.
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
