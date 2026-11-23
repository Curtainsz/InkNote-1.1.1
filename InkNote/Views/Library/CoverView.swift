import SwiftUI

/// A notebook cover: colour, style, symbol and title, or a custom photo.
struct CoverView: View {
    let title: String
    let cover: Cover
    var size: CGSize

    @State private var photo: UIImage?

    init(title: String, cover: Cover, size: CGSize = CGSize(width: 150, height: 200)) {
        self.title = title
        self.cover = cover
        self.size = size
        let cached: UIImage? = (cover.style == .image) ? cover.imageFileName.flatMap { CoverImageStore.cached($0) } : nil
        _photo = State(initialValue: cached)
    }

    var body: some View {
        let base = Color(hex: cover.colorHex)
        ZStack(alignment: .topLeading) {
            coverBackground(base)

            Rectangle()
                .fill(Color.black.opacity(0.18))
                .frame(width: size.width * 0.09)

            if cover.style == .label {
                labelContent
            } else if cover.style == .image {
                photoContent
            } else {
                standardContent
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Color.black.opacity(0.22), radius: 4, x: 0, y: 2)
        .task(id: "\(cover.style.rawValue)|\(cover.imageFileName ?? "")") {
            if cover.style == .image, let name = cover.imageFileName {
                photo = CoverImageStore.cached(name)
                if photo == nil {
                    photo = await CoverImageStore.load(name)
                }
            } else {
                photo = nil
            }
        }
    }

    // MARK: Content layouts

    private var labelContent: some View {
        VStack(spacing: 0) {
            Image(systemName: cover.symbol)
                .font(.system(size: size.width * 0.28, weight: .semibold))
                .foregroundColor(.white)
                .padding(.top, size.height * 0.14)
            Spacer()
            Text(title)
                .font(.system(size: size.width * 0.105, weight: .semibold, design: .rounded))
                .foregroundColor(Color(hex: "#1B1B1F"))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, size.width * 0.14)
                .padding(.bottom, size.height * 0.14)
        }
        .frame(width: size.width, height: size.height)
        .padding(.leading, size.width * 0.04)
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: cover.symbol)
                .font(.system(size: size.width * 0.26, weight: .semibold))
                .foregroundColor(.white.opacity(0.95))
            Spacer()
            Text(title)
                .font(.system(size: size.width * 0.115, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
        }
        .padding(.leading, size.width * 0.17)
        .padding(.trailing, size.width * 0.08)
        .padding(.vertical, size.height * 0.09)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Title over a dark gradient at the bottom, so it stays readable on any picture.
    @ViewBuilder
    private var photoContent: some View {
        if cover.showTitle {
            VStack(spacing: 0) {
                Spacer()
                Text(title)
                    .font(.system(size: size.width * 0.115, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, size.width * 0.17)
                    .padding(.trailing, size.width * 0.08)
                    .padding(.top, size.height * 0.14)
                    .padding(.bottom, size.height * 0.07)
                    .background(
                        LinearGradient(
                            colors: [Color.black.opacity(0), Color.black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(width: size.width, height: size.height)
        }
    }

    // MARK: Backgrounds

    @ViewBuilder
    private func coverBackground(_ base: Color) -> some View {
        switch cover.style {
        case .solid, .label:
            base
        case .gradient:
            LinearGradient(
                colors: [Color(UIColor(base).adjusted(brightness: 0.12)),
                         Color(UIColor(base).adjusted(brightness: -0.18))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .stripes:
            ZStack {
                base
                Canvas { context, canvasSize in
                    var x = -canvasSize.height
                    while x < canvasSize.width {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: canvasSize.height))
                        path.addLine(to: CGPoint(x: x + canvasSize.height, y: 0))
                        context.stroke(path, with: .color(Color.white.opacity(0.14)), lineWidth: 8)
                        x += 28
                    }
                }
            }
        case .image:
            if let photo = photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                base
            }
        }
    }
}
