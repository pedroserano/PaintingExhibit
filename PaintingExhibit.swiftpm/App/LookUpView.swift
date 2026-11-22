import SwiftUI
import VisionKit

/// The painting with Apple's Visual Look Up, which recognises many famous paintings on the device. Apple shows
/// its answer only on screen (the ⓘ badge), so this is for checking by eye; what you learn can be typed into
/// the painting's details.
struct LookUpView: View {
    @EnvironmentObject var library: Library
    let painting: Painting
    let close: () -> Void

    @State private var image: CGImage?
    @State private var found: Bool?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image {
                    LookUpImage(image: image) { found = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.bottom)
            .navigationTitle("Apple Visual Look Up")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
            .task {
                guard let url = await library.imageURL(for: painting) else { return }
                image = await ImageLoader.load(url, maxPixel: 2048)
            }
        }
    }

    private var message: String {
        guard ImageAnalyzer.isSupported else { return "Visual Look Up isn't available on this device." }
        switch found {
        case nil: return "Looking…"
        case true?: return "Tap the ⓘ badge on the painting to see what Apple recognises. You can type what it says into the painting's Details."
        case false?: return "Apple's Visual Look Up didn't recognise this painting."
        }
    }
}

#if os(iOS)
private struct LookUpImage: UIViewRepresentable {
    let image: CGImage
    let onAnalysed: (Bool) -> Void

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: UIImage(cgImage: image))
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .visualLookUp
        view.addInteraction(interaction)
        analyse(into: interaction)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    private func analyse(into interaction: ImageAnalysisInteraction) {
        guard ImageAnalyzer.isSupported else { onAnalysed(false); return }
        let image = image, onAnalysed = onAnalysed
        Task { @MainActor in
            let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up,
                                                              configuration: ImageAnalyzer.Configuration([.visualLookUp]))
            interaction.analysis = analysis
            interaction.preferredInteractionTypes = .visualLookUp
            onAnalysed(analysis?.hasResults(for: .visualLookUp) ?? false)
        }
    }
}
#else
private struct LookUpImage: NSViewRepresentable {
    let image: CGImage
    let onAnalysed: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let imageView = NSImageView(image: NSImage(cgImage: image, size: .zero))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let overlay = ImageAnalysisOverlayView()
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .visualLookUp
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        container.addSubview(overlay)
        for view in [imageView, overlay] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        guard ImageAnalyzer.isSupported else { onAnalysed(false); return container }
        let image = image, onAnalysed = onAnalysed
        Task { @MainActor in
            let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up,
                                                              configuration: ImageAnalyzer.Configuration([.visualLookUp]))
            overlay.analysis = analysis
            onAnalysed(analysis?.hasResults(for: .visualLookUp) ?? false)
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
