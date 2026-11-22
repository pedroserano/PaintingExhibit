import SwiftUI
import CoreImage

/// Setting a painting's white balance by hand: warmth and tint sliders, and an eyedropper that makes the spot
/// you tap neutral (pick something that should be white or grey). The preview updates as you go; Save redraws
/// the painting from the original photo.
struct ColourView: View {
    @EnvironmentObject var library: Library
    let painting: Painting
    let close: () -> Void

    @State private var adjust: ColourAdjust
    @State private var base: CGImage?
    @State private var pixels: [UInt8] = []
    @State private var preview: CGImage?
    @State private var picking = false
    @State private var picked: CGPoint?
    @State private var saving = false

    private static let context = CIContext()

    init(painting: Painting, close: @escaping () -> Void) {
        self.painting = painting
        self.close = close
        _adjust = State(initialValue: painting.settings.colour ?? .neutral)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    ZStack {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if let picked {
                            Circle().strokeBorder(.white, lineWidth: 2)
                                .background(Circle().strokeBorder(.black, lineWidth: 4))
                                .frame(width: 22, height: 22)
                                .position(picked)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard picking else { return }
                        pick(at: location, in: geo.size)
                    }
                }
                .background(Color.black)

                Text(picking ? "Tap a spot that should be white or neutral grey."
                             : "Drag the sliders, or use the eyedropper to pick a white point.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    slider("Warmth", value: $adjust.warmth, low: "Cooler", high: "Warmer")
                    slider("Tint", value: $adjust.tint, low: "Green", high: "Magenta")
                }
                .padding(.horizontal)

                HStack {
                    Button {
                        picking.toggle()
                    } label: {
                        Label(picking ? "Picking…" : "Pick White Point", systemImage: "eyedropper")
                    }
                    .buttonStyle(.bordered)
                    .tint(picking ? .accentColor : nil)
                    Button("Reset") {
                        adjust = .neutral
                        picked = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(adjust == .neutral)
                }
            }
            .padding(.vertical)
            .navigationTitle("White Balance")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            await library.setColour(adjust, for: painting.id)
                            close()
                        }
                    }
                    .disabled(saving || adjust == (painting.settings.colour ?? .neutral))
                }
            }
            .task { await load() }
            .onChange(of: adjust) { updatePreview() }
        }
    }

    private func slider(_ title: String, value: Binding<Float>, low: String, high: String) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Text(low).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: -1...1)
            Text(high).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Preview

    private func load() async {
        guard let url = await library.imageURL(for: painting),
              let image = await ImageLoader.load(url, maxPixel: 1600) else { return }
        base = image
        pixels = Self.bytes(of: image)
        updatePreview()
    }

    /// The drawn painting already carries its saved balance: the preview applies only the change from it, in
    /// linear light, allowing for the black point and exposure applied after the balance.
    private func updatePreview() {
        guard let base else { return }
        let ratio = PaintingProcessor.colourGains(adjust) / PaintingProcessor.colourGains(painting.settings.colour)
        let black = painting.settings.blackPoint ?? 0, exposure = painting.settings.exposure ?? 1
        let bias = (ratio - 1) * black * exposure
        let image = CIImage(cgImage: base).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(ratio.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(ratio.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(ratio.z), w: 0),
            "inputBiasVector": CIVector(x: CGFloat(bias.x), y: CGFloat(bias.y), z: CGFloat(bias.z), w: 0)
        ])
        preview = Self.context.createCGImage(image, from: image.extent)
    }

    // MARK: Eyedropper

    /// Makes the colour around the tapped spot neutral: it is taken back to how the painting looked before any
    /// hand-set balance, and the warmth and tint that turn that grey are set.
    private func pick(at location: CGPoint, in size: CGSize) {
        guard let base, !pixels.isEmpty else { return }
        let w = CGFloat(base.width), h = CGFloat(base.height)
        let scale = min(size.width / w, size.height / h)
        let origin = CGPoint(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2)
        let x = Int((location.x - origin.x) / scale), y = Int((location.y - origin.y) / scale)
        guard x >= 0, y >= 0, x < base.width, y < base.height else { return }

        func linear(_ byte: UInt8) -> Float {
            let c = Float(byte) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        var sum = SIMD3<Float>(repeating: 0)
        var count: Float = 0
        let r = max(2, base.width / 200)
        for yy in max(0, y - r)...min(base.height - 1, y + r) {
            for xx in max(0, x - r)...min(base.width - 1, x + r) {
                let o = (yy * base.width + xx) * 4
                sum += SIMD3(linear(pixels[o]), linear(pixels[o + 1]), linear(pixels[o + 2]))
                count += 1
            }
        }
        let black = painting.settings.blackPoint ?? 0, exposure = painting.settings.exposure ?? 1
        let drawn = sum / count
        let unbalanced = (drawn / exposure + black) / PaintingProcessor.colourGains(painting.settings.colour)
        adjust = PaintingProcessor.neutralizing(unbalanced)
        picked = location
        picking = false
    }

    private static func bytes(of image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? bytes : []
    }
}
