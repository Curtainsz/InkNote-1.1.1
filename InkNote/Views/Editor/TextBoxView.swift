import SwiftUI

/// A typed text box that can be dragged, resized and edited. Apple Pencil Scribble works inside it.
struct TextBoxView: View {
    let box: TextBox
    let selected: Bool
    let interactive: Bool
    let onSelect: () -> Void
    let onChange: (TextBox) -> Void
    let onDelete: () -> Void

    @State private var moveOrigin: CGPoint?
    @State private var resizeOrigin: CGSize?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { box.text },
                set: { newValue in
                    var b = box
                    b.text = newValue
                    onChange(b)
                }
            ))
            .font(.system(size: CGFloat(box.fontSize), weight: box.bold ? .bold : .regular))
            .foregroundColor(Color(hex: box.colorHex))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(width: CGFloat(box.width), height: CGFloat(box.height))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.accentColor : Color.clear,
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .allowsHitTesting(interactive)

            if selected && interactive {
                handle(symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .accentColor)
                    .offset(x: -15, y: -15)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("page"))
                            .onChanged { value in
                                let origin = moveOrigin ?? CGPoint(x: box.x, y: box.y)
                                moveOrigin = origin
                                var b = box
                                b.x = origin.x + value.translation.width
                                b.y = origin.y + value.translation.height
                                onChange(b)
                            }
                            .onEnded { _ in moveOrigin = nil }
                    )

                Button(action: onDelete) {
                    handle(symbol: "xmark", tint: .red)
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(box.width) - 15, y: -15)

                handle(symbol: "arrow.up.left.and.arrow.down.right", tint: .accentColor)
                    .offset(x: CGFloat(box.width) - 15, y: CGFloat(box.height) - 15)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("page"))
                            .onChanged { value in
                                let origin = resizeOrigin ?? CGSize(width: box.width, height: box.height)
                                resizeOrigin = origin
                                var b = box
                                b.width = max(100, Double(origin.width + value.translation.width))
                                b.height = max(44, Double(origin.height + value.translation.height))
                                onChange(b)
                            }
                            .onEnded { _ in resizeOrigin = nil }
                    )
            }
        }
        .offset(x: CGFloat(box.x), y: CGFloat(box.y))
        .onChange(of: focused) { isFocused in
            if isFocused { onSelect() }
        }
    }

    private func handle(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(tint))
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .contentShape(Circle())
    }
}

/// A picture on the page that can be dragged and resized.
struct ImageItemView: View {
    let item: ImageItem
    let url: URL
    let selected: Bool
    let interactive: Bool
    let onSelect: () -> Void
    let onChange: (ImageItem) -> Void
    let onDelete: () -> Void

    @State private var image: UIImage?
    @State private var moveOrigin: CGPoint?
    @State private var resizeOrigin: CGSize?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image = image {
                    Image(uiImage: image).resizable()
                } else {
                    Color.gray.opacity(0.15)
                }
            }
            .frame(width: CGFloat(item.width), height: CGFloat(item.height))
            .overlay(
                Rectangle().stroke(selected ? Color.accentColor : Color.clear,
                                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if interactive { onSelect() }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("page"))
                    .onChanged { value in
                        let origin = moveOrigin ?? CGPoint(x: item.x, y: item.y)
                        moveOrigin = origin
                        var i = item
                        i.x = origin.x + value.translation.width
                        i.y = origin.y + value.translation.height
                        onChange(i)
                    }
                    .onEnded { _ in moveOrigin = nil },
                including: interactive ? .all : .none
            )

            if selected && interactive {
                Button(action: onDelete) {
                    corner(symbol: "xmark", tint: .red)
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(item.width) - 15, y: -15)

                corner(symbol: "arrow.up.left.and.arrow.down.right", tint: .accentColor)
                    .offset(x: CGFloat(item.width) - 15, y: CGFloat(item.height) - 15)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("page"))
                            .onChanged { value in
                                let origin = resizeOrigin ?? CGSize(width: item.width, height: item.height)
                                resizeOrigin = origin
                                let ratio = origin.height / max(origin.width, 1)
                                var i = item
                                i.width = max(60, Double(origin.width + value.translation.width))
                                i.height = i.width * Double(ratio)
                                onChange(i)
                            }
                            .onEnded { _ in resizeOrigin = nil }
                    )
            }
        }
        .offset(x: CGFloat(item.x), y: CGFloat(item.y))
        .task(id: item.fileName) {
            let path = url.path
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)
            }.value
        }
    }

    private func corner(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(tint))
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .contentShape(Circle())
    }
}
