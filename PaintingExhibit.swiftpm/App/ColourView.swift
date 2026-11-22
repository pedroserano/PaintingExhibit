import SwiftUI
import CoreImage

/// Setting a painting's white balance by hand, in the exhibit's White Balance mode: the painting with a live
/// preview, warmth and tint sliders, and an eyedropper that makes the spot you tap neutral (pick something that
/// should be white or grey). Changes are saved with Save (Return), or when you move on to another painting or
/// leave the mode; Revert puts them back first.
struct ColourEditor: View {
    @EnvironmentObject var library: Library
    let painting: Painting

    @State private var adjust: ColourAdjust
    /// The balance as last saved, to tell whether anything changed.
    @State private var saved: ColourAdjust
    @State private var base: CGImage?
    @State private var pixels: [UInt8] = []
    @State private var preview: CGImage?
    @State private var picking = false
    @State private var picked: CGPoint?
    @State private var note: String?

    private static let context = CIContext()

    init(painting: Painting) {
        self.painting = painting
        _adjust = State(initialValue: painting.settings.colour ?? .neutral)
        _saved = State(initialValue: painting.settings.colour ?? .neutral)
    }

    private var changed: Bool { adjust != saved }

    var body: some View {
        VStack(spacing: 0) {
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
                #if os(macOS)
                .onContinuousHover { phase in
                    if case .active = phase, picking { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                }
                #endif
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 64)   // clear of the previous and next arrows

            controls
                .padding(.horizontal, 64)
                .padding(.bottom, 12)
        }
        .task(id: painting.renderedAt) { await load() }
        .onChange(of: adjust) { updatePreview() }
        .onChange(of: picking) { note = nil }
        // Moving to another painting or leaving the mode keeps what was done.
        .onDisappear {
            if changed { Task { [library, adjust, id = painting.id] in await library.setColour(adjust, for: id) } }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                slider("Warmth", value: $adjust.warmth, low: "Cooler", high: "Warmer")
                slider("Tint", value: $adjust.tint, low: "Green", high: "Magenta")
            }
            HStack(spacing: 12) {
                Button {
                    picking.toggle()
                } label: {
                    Label(picking ? "Click a White Spot…" : "Pick White Point", systemImage: "eyedropper")
                }
                .help("Click a spot in the painting that should be white or neutral grey")
                Button {
                    autoBalance()
                } label: {
                    Label("Auto", systemImage: "wand.and.stars")
                }
                .help("Make the painting's near-neutral areas (whites, greys, pale highlights) neutral")
                Text(note ?? (picking ? "Click something that should be white or grey."
                     : changed ? "Saved when you move on, or press Save." : "Drag the sliders, pick a white point, or try Auto."))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if adjust != .neutral {
                    Button("Reset") {
                        adjust = .neutral
                        picked = nil
                    }
                }
                if changed {
                    Button("Revert") {
                        adjust = saved
                        picked = nil
                    }
                    Button("Save") {
                        let value = adjust
                        saved = value
                        Task { await library.setColour(value, for: painting.id) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .buttonStyle(.bordered)
        .focusable(false)
        .tint(.white)
        .foregroundStyle(.white)
    }

    private func slider(_ title: String, value: Binding<Float>, low: String, high: String) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 56, alignment: .leading)
            Text(low).font(.caption).foregroundStyle(.white.opacity(0.6))
            Slider(value: value, in: -1...1)
            Text(high).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: Preview

    private func load() async {
        guard let url = await library.imageURL(for: painting),
              let image = await ImageLoader.load(url, maxPixel: 2000) else { return }
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

    // MARK: Auto

    private func autoBalance() {
        guard let base, !pixels.isEmpty else { return }
        let black = painting.settings.blackPoint ?? 0, exposure = painting.settings.exposure ?? 1
        let saved = PaintingProcessor.colourGains(painting.settings.colour)
        var colours: [SIMD3<Float>] = []
        let stride = max(1, (base.width * base.height) / 60_000)
        var i = 0
        while i < base.width * base.height {
            let o = i * 4
            let drawn = SIMD3(Self.linear(pixels[o]), Self.linear(pixels[o + 1]), Self.linear(pixels[o + 2]))
            colours.append((drawn / exposure + black) / saved)
            i += stride
        }
        if let found = PaintingProcessor.autoBalance(colours) {
            adjust = found
            picked = nil
            note = nil
        } else {
            note = "Too little of this painting is white or grey to balance it automatically."
        }
    }

    private static func linear(_ byte: UInt8) -> Float {
        let c = Float(byte) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    // MARK: Eyedropper

    /// Makes the colour around the clicked spot neutral: it is taken back to how the painting looked before any
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
