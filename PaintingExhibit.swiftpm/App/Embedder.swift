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
/// The model (23 MB, Apple Sample Code License) is fetched once from Apple's page on Hugging Face and kept in
/// Application Support, rather than added to the app.
final class Embedder: @unchecked Sendable {
    static let name = "mobileclip_s0_image"
    private static let source = "https://huggingface.co/apple/coreml-mobileclip/resolve/main/\(name).mlpackage/"
    private static let files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]

    private let model: VNCoreMLModel

    private init(model: VNCoreMLModel) { self.model = model }

    private static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaintingExhibit/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var compiledURL: URL { folder.appendingPathComponent(name + ".mlmodelc") }

    /// The one load in progress or done, shared by every caller (so the model is fetched once).
    @MainActor private static var loading: Task<Embedder?, Never>?

    /// The recogniser, ready to use: loaded from disk, or fetched and compiled the first time. Nil if the model
    /// can't be had (offline on first use); the next call tries again.
    static func shared() async -> Embedder? {
        let task = await MainActor.run { () -> Task<Embedder?, Never> in
            if let loading { return loading }
            let task = Task.detached { await load() }
            loading = task
            return task
        }
        let embedder = await task.value
        if embedder == nil { await MainActor.run { loading = nil } }
        return embedder
    }

    private static func load() async -> Embedder? {
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            guard await download() else { return nil }
        }
        guard let ml = try? MLModel(contentsOf: compiledURL), let vision = try? VNCoreMLModel(for: ml) else {
            // A damaged copy: fetch it again next time.
            try? FileManager.default.removeItem(at: compiledURL)
            return nil
        }
        return Embedder(model: vision)
    }

    private static func download() async -> Bool {
        let package = folder.appendingPathComponent(name + ".mlpackage", isDirectory: true)
        try? FileManager.default.removeItem(at: package)
        for file in files {
            guard let url = URL(string: source + file),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let target = package.appendingPathComponent(file)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: target)) != nil else { return false }
        }
        guard let compiled = try? await MLModel.compileModel(at: package) else { return false }
        try? FileManager.default.removeItem(at: compiledURL)
        defer { try? FileManager.default.removeItem(at: package) }
        return (try? FileManager.default.moveItem(at: compiled, to: compiledURL)) != nil
    }

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
