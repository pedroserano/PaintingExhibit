import SwiftUI

/// Setting a painting's corners by hand, in the exhibit's Adjust Crop mode: the photo with the crop's four
/// corners, which you drag onto the painting's corners. A magnifier shows the spot under the corner while
/// dragging. Changes are saved with Save (Return), or when you move on to another painting or leave the mode;
/// Revert puts the corners back first.
struct CropEditor: View {
    @EnvironmentObject var library: Library
    let painting: Painting

    @State private var photo: CGImage?
    @State private var failed = false
    /// Top-left, top-right, bottom-right, bottom-left, as fractions of the photo with row 0 at the top.
    @State private var corners: [CGPoint] = []
    /// The corners as last saved (or as the crop was), to tell whether anything changed.
    @State private var saved: [CGPoint] = []
    @State private var dragging: Int?
    @State private var dragStart: CGPoint?

    private var changed: Bool {
        corners.count == 4 && saved.count == 4 && zip(corners, saved).contains { abs($0.x - $1.x) > 1e-4 || abs($0.y - $1.y) > 1e-4 }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let photo {
                    let size = fittedSize(for: photo, in: geo.size)
                    editor(photo: photo, size: size)
                        .frame(width: size.width, height: size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else if failed {
                    Text("The photo couldn't be opened.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 64)   // clear of the previous and next arrows

            HStack(spacing: 12) {
                Text(changed ? "Saved when you move on, or press Save." : "Drag each corner onto a corner of the painting.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if painting.manualCrop != nil && !changed {
                    Button("Use Automatic Crop") { library.setManualCrop(nil, for: painting.id) }
                }
                if changed {
                    Button("Revert") { corners = saved }
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isConvex)
                }
            }
            .buttonStyle(.bordered)
            .focusable(false)
            .padding(.horizontal, 64)
            .padding(.bottom, 12)
            .frame(minHeight: 44)
        }
        .tint(.white)
        .task {
            // An automatic outline can run off the photo; start every corner on it, where it can be dragged.
            corners = library.currentCrop(of: painting).map { CGPoint(x: min(max($0.x, 0), 1), y: min(max(1 - $0.y, 0), 1)) }
            saved = corners
            photo = await library.editorPhoto(for: painting)
            failed = photo == nil
        }
        // Moving to another painting or leaving the mode keeps what was done.
        .onDisappear { if changed && isConvex { save() } }
    }

    private func save() {
        library.setManualCrop(corners.map { NormPoint(x: $0.x, y: 1 - $0.y) }, for: painting.id)
        saved = corners
    }

    private func editor(photo: CGImage, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: photo, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)

            // Dim everything outside the crop.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addLines(points(in: size))
                path.closeSubpath()
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                path.addLines(points(in: size))
                path.closeSubpath()
            }
            .stroke(Color.white, lineWidth: 1.5)
            .allowsHitTesting(false)

            ForEach(corners.indices, id: \.self) { i in
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().fill(Color.accentColor.opacity(dragging == i ? 0.6 : 0.3)))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle().inset(by: -12))
                    .position(x: corners[i].x * size.width, y: corners[i].y * size.height)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragging != i { dragging = i; dragStart = corners[i] }
                                guard let start = dragStart else { return }
                                corners[i] = CGPoint(
                                    x: min(max(start.x + value.translation.width / size.width, 0), 1),
                                    y: min(max(start.y + value.translation.height / size.height, 0), 1))
                            }
                            .onEnded { _ in dragging = nil; dragStart = nil }
                    )
            }

            if let i = dragging {
                loupe(photo: photo, size: size, at: corners[i])
                    // On the side away from the corner being dragged, so the finger doesn't cover it.
                    .position(x: corners[i].x < 0.5 ? size.width - 70 : 70, y: 70)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The photo around `point`, three times larger, with cross hairs on the point.
    private func loupe(photo: CGImage, size: CGSize, at point: CGPoint) -> some View {
        let zoom: CGFloat = 3, diameter: CGFloat = 120
        return ZStack {
            Image(decorative: photo, scale: 1)
                .resizable()
                .frame(width: size.width * zoom, height: size.height * zoom)
                .offset(x: (0.5 - point.x) * size.width * zoom, y: (0.5 - point.y) * size.height * zoom)
                .frame(width: diameter, height: diameter)
                .clipped()
            Path { p in
                p.move(to: CGPoint(x: diameter / 2, y: 0)); p.addLine(to: CGPoint(x: diameter / 2, y: diameter))
                p.move(to: CGPoint(x: 0, y: diameter / 2)); p.addLine(to: CGPoint(x: diameter, y: diameter / 2))
            }
            .stroke(Color.white.opacity(0.8), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 2))
        .shadow(radius: 8)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }

    private func fittedSize(for photo: CGImage, in space: CGSize) -> CGSize {
        let scale = min(space.width / CGFloat(photo.width), space.height / CGFloat(photo.height))
        return CGSize(width: CGFloat(photo.width) * scale, height: CGFloat(photo.height) * scale)
    }

    /// The corners make a proper four-sided shape (not crossed over).
    private var isConvex: Bool {
        guard corners.count == 4 else { return false }
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-6 { return false }
            if sign == 0 { sign = cross } else if (sign > 0) != (cross > 0) { return false }
        }
        return true
    }
}
