import SwiftUI

/// What the crop screen is asked to crop. `originalName` is set when re-cropping a saved picture.
struct CropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
    let originalName: String?
}

/// Pinch and drag a picture inside a fixed 3:4 frame, then save the result as the cover.
struct CoverCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    private let frameSize = CGSize(width: 270, height: 360)

    /// Scale at which the picture exactly fills the frame.
    private var fillScale: CGFloat {
        max(frameSize.width / max(image.size.width, 1), frameSize.height / max(image.size.height, 1))
    }

    private func displaySize(for zoom: CGFloat) -> CGSize {
        CGSize(width: image.size.width * fillScale * zoom, height: image.size.height * fillScale * zoom)
    }

    /// Keeps the picture covering the whole frame, so no blank edges show.
    private func clamped(_ proposed: CGSize, zoom: CGFloat) -> CGSize {
        let shown = displaySize(for: zoom)
        let maxX = max(0, (shown.width - frameSize.width) / 2)
        let maxY = max(0, (shown.height - frameSize.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    var body: some View {
        let shown = displaySize(for: scale)
        NavigationStack {
            VStack(spacing: 22) {
                Text("Pinch and drag to choose what shows on the cover.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ZStack {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .offset(offset)
                }
                .frame(width: frameSize.width, height: frameSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
                )
                .overlay(
                    // The darker strip on the left is the spine.
                    HStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.18))
                            .frame(width: frameSize.width * 0.09)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let proposed = CGSize(width: dragStart.width + value.translation.width,
                                                  height: dragStart.height + value.translation.height)
                            offset = clamped(proposed, zoom: scale)
                        }
                        .onEnded { _ in
                            dragStart = offset
                        }
                        .simultaneously(with:
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(pinchStart * value, 1), 4)
                                    offset = clamped(offset, zoom: scale)
                                }
                                .onEnded { _ in
                                    pinchStart = scale
                                    dragStart = offset
                                }
                        )
                )

                HStack(spacing: 12) {
                    Image(systemName: "minus.magnifyingglass").foregroundColor(.secondary)
                    Slider(value: Binding(
                        get: { scale },
                        set: { newValue in
                            scale = newValue
                            pinchStart = newValue
                            offset = clamped(offset, zoom: newValue)
                            dragStart = offset
                        }
                    ), in: 1...4)
                    Image(systemName: "plus.magnifyingglass").foregroundColor(.secondary)
                }
                .frame(width: frameSize.width)

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Crop cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Use photo") {
                        onDone(renderCrop())
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// Draws exactly what the frame shows into a 600 x 800 bitmap.
    private func renderCrop() -> UIImage {
        let output = CGSize(width: 600, height: 800)
        let factor = output.width / frameSize.width
        let shown = displaySize(for: scale)
        let rect = CGRect(
            x: ((frameSize.width - shown.width) / 2 + offset.width) * factor,
            y: ((frameSize.height - shown.height) / 2 + offset.height) * factor,
            width: shown.width * factor,
            height: shown.height * factor
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: output, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: output))
            image.draw(in: rect)
        }
    }
}
