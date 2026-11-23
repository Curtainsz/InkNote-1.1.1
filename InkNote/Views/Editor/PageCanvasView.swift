import SwiftUI
import PencilKit

/// One page: paper (or PDF), pictures, text boxes and the ink layer on top.
struct PageCanvasView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var state: EditorState
    let notebookID: UUID
    let pageID: UUID
    var onInkChange: (PKDrawing) -> Void

    var body: some View {
        if let nb = store.notebook(notebookID), let page = nb.pages.first(where: { $0.id == pageID }) {
            pageBody(nb, page)
        }
    }

    @ViewBuilder
    private func pageBody(_ nb: Notebook, _ page: Page) -> some View {
        let textMode = state.tool == .text

        ZStack(alignment: .topLeading) {
            PaperLayer(notebook: nb, page: page)

            if textMode {
                Color.clear
                    .frame(width: CGFloat(page.width), height: CGFloat(page.height))
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            handleBackgroundTap(page, at: value.location)
                        }
                    )
            }

            ForEach(page.images) { item in
                ImageItemView(
                    item: item,
                    url: store.imageURL(item.fileName),
                    selected: state.selectedImageID == item.id,
                    interactive: textMode,
                    onSelect: {
                        state.selectedImageID = item.id
                        state.selectedBoxID = nil
                    },
                    onChange: { updated in
                        store.updatePage(notebookID, pageID) { p in
                            if let i = p.images.firstIndex(where: { $0.id == updated.id }) { p.images[i] = updated }
                        }
                    },
                    onDelete: {
                        state.selectedImageID = nil
                        store.updatePage(notebookID, pageID) { p in
                            p.images.removeAll { $0.id == item.id }
                        }
                    }
                )
            }

            ForEach(page.textBoxes) { box in
                TextBoxView(
                    box: box,
                    selected: state.selectedBoxID == box.id,
                    interactive: textMode,
                    onSelect: {
                        if state.selectedBoxID != box.id {
                            state.selectedBoxID = box.id
                            state.selectedImageID = nil
                        }
                    },
                    onChange: { updated in
                        store.updatePage(notebookID, pageID) { p in
                            if let i = p.textBoxes.firstIndex(where: { $0.id == updated.id }) { p.textBoxes[i] = updated }
                        }
                    },
                    onDelete: {
                        state.selectedBoxID = nil
                        store.updatePage(notebookID, pageID) { p in
                            p.textBoxes.removeAll { $0.id == box.id }
                        }
                    }
                )
            }

            InkCanvasView(
                pageSize: page.size,
                loadDrawing: { store.drawing(for: pageID) },
                state: state,
                onChange: onInkChange
            )
            .frame(width: CGFloat(page.width), height: CGFloat(page.height))
            .allowsHitTesting(!textMode)
        }
        .frame(width: CGFloat(page.width), height: CGFloat(page.height), alignment: .topLeading)
        .coordinateSpace(name: "page")
    }

    private func handleBackgroundTap(_ page: Page, at point: CGPoint) {
        // First tap on empty paper only deselects; the next one adds a text box.
        if state.selectedBoxID != nil || state.selectedImageID != nil {
            state.selectedBoxID = nil
            state.selectedImageID = nil
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return
        }
        let x = Double(min(max(point.x, 12), CGFloat(page.width) - 292))
        let y = Double(min(max(point.y, 12), CGFloat(page.height) - 102))
        let box = TextBox(x: x, y: y, colorHex: state.penColor.hexString)
        store.updatePage(notebookID, pageID) { $0.textBoxes.append(box) }
        state.selectedBoxID = box.id
    }
}

/// Paper template, or the rendered PDF page for imported documents.
struct PaperLayer: View {
    @EnvironmentObject var store: LibraryStore
    let notebook: Notebook
    let page: Page

    @State private var pdfImage: UIImage?

    var body: some View {
        ZStack {
            if page.pdfPageIndex != nil {
                Color.white
                if let img = pdfImage {
                    Image(uiImage: img).resizable()
                }
            } else {
                Image(uiImage: PaperRenderer.image(template: page.template, tone: page.tone, size: page.size, scale: 2))
                    .resizable()
            }
        }
        .frame(width: CGFloat(page.width), height: CGFloat(page.height))
        .task(id: page.id) {
            guard let index = page.pdfPageIndex, let name = notebook.pdfFileName else { return }
            pdfImage = await PDFService.shared.render(url: store.pdfURL(name), index: index, size: page.size, scale: 3)
        }
    }
}
