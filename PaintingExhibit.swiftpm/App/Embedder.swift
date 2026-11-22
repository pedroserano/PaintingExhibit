import Foundation
import CoreGraphics
import CoreML
import Vision

/// Recognises paintings by image on the device with Apple's MobileCLIP (S0) model, which reads what a picture
/// shows rather than only how its pixels look: the same painting matches across angle, glare, lighting and
/// small or blurry museum thumbnails, where Vision's general feature print failed (on 36 hand-checked pairs it
/// told same from different almost perfectly from 330-pixel thumbnails, where the feature print was barely
/// better than chance).
///
/// The model (23 MB) is built into the app: scripts/fetch-model.sh fetches it from Apple at build time (Apple
/// Machine Learning Research Model License, so it isn't kept in the repository).
final class Embedder: @unchecked Sendable {
    static let name = "mobileclip_s0_image"
    private let model: VNCoreMLModel

    private init(model: VNCoreMLModel) { self.model = model }

    /// Loaded once, on first use.
    private static let loaded: Embedder? = {
        guard let url = Bundle.module.url(forResource: name, withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url), let vision = try? VNCoreMLModel(for: ml) else { return nil }
        return Embedder(model: vision)
    }()

    /// The recogniser (nil only if the app was built without the model).
    static func shared() async -> Embedder? { loaded }

    /// The image's fingerprint: 512 numbers of unit length, so the dot product of two is their similarity.
    func vector(_ image: CGImage) -> [Float]? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let values = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue
        else { return nil }
        var v = (0..<values.count).map { Float(truncating: values[$0]) }
        let length = v.map { $0 * $0 }.reduce(0, +).squareRoot()
        guard length > 0 else { return nil }
        for i in v.indices { v[i] /= length }
        return v
    }
}
