import SwiftUI
import PencilKit
import PhotosUI

/// The note-taking screen: tool bar, page, page bar and the sheets around them.
struct EditorView: View {
    @EnvironmentObject var store: LibraryStore
    let notebookID: UUID

    @StateObject var state = EditorState()
    @StateObject var audio = AudioModel()

    @State var pageIndex: Int
    @State var showPages = false
    @State var showAudio = false
    @State var showText = false
    @State var shareItem: ShareItem?
    @State var recognisedText = ""
    @State var recognising = false
    @State var photoItem: PhotosPickerItem?
    @State var recogTask: Task<Void, Never>?
    @State var busy = false
    @State var message: String?
    @State var pinchBase: CGFloat = 1

    init(notebookID: UUID, startPage: Int) {
        self.notebookID = notebookID
        _pageIndex = State(initialValue: startPage)
    }

    var body: some View {
        Group {
            if let nb = store.notebook(notebookID), !nb.pages.isEmpty {
                editor(nb)
            } else {
                Text("This notebook is no longer available.")
                    .foregroundColor(.secondary)
            }
        }
    }

    func currentIndex(_ nb: Notebook) -> Int {
        min(max(pageIndex, 0), nb.pages.count - 1)
    }

    // MARK: Layout

    func editor(_ nb: Notebook) -> some View {
        let index = currentIndex(nb)
        let page = nb.pages[index]
        return VStack(spacing: 0) {
            toolsBar(page)
            Divider()
            if state.tool == .text {
                objectInspector(page)
                Divider()
            }
            GeometryReader { geo in
                pageScroller(geo, nb, page)
            }
            pageBar(nb, index)
        }
        .navigationTitle(nb.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                moreMenu(nb, page)
            }
        }
        .sheet(isPresented: $showPages) {
            PagesSheet(notebookID: notebookID, pageIndex: $pageIndex)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAudio) {
            AudioSheet(audio: audio, notebookID: notebookID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showText) {
            RecognisedTextSheet(text: $recognisedText, isWorking: recognising) {
                insertRecognisedText(page)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls)
        }
        .onChange(of: photoItem) { item in
            importPhoto(item, pageID: page.id)
        }
        .alert("InkNote", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .overlay {
            if busy {
                ProgressView("Working…")
                    .padding(20)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .onDisappear {
            store.flushAll()
            if audio.isRecording, let clip = audio.stopRecording() {
                store.addClip(clip, to: notebookID)
            }
            audio.stopPlayback()
        }
    }

    func pageScroller(_ geo: GeometryProxy, _ nb: Notebook, _ page: Page) -> some View {
        let fit = min(max((geo.size.width - 48) / CGFloat(page.width), 0.2), 1.6)
        let scale = fit * state.zoom
        let width = CGFloat(page.width)
        let height = CGFloat(page.height)
        return ScrollView([.horizontal, .vertical]) {
            PageCanvasView(
                state: state,
                notebookID: nb.id,
                pageID: page.id,
                onInkChange: { drawing in handleInk(page, drawing) }
            )
            .id(page.id)
            .frame(width: width, height: height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width * scale, height: height * scale, alignment: .topLeading)
            .shadow(color: Color.black.opacity(0.22), radius: 6, x: 0, y: 2)
            .padding(24)
            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
        }
        .background(Color(UIColor.systemGray5))
        // Pinch to zoom only when fingers are not used for drawing.
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    state.zoom = min(max(pinchBase * value, 0.5), 4)
                }
                .onEnded { _ in
                    pinchBase = state.zoom
                },
            including: state.pencilOnly ? .all : .none
        )
    }

    // MARK: Actions

    func setZoom(_ value: CGFloat) {
        state.zoom = min(max(value, 0.5), 4)
        pinchBase = state.zoom
    }

    func goToPage(_ index: Int, in nb: Notebook) {
        state.selectedBoxID = nil
        state.selectedImageID = nil
        pageIndex = min(max(index, 0), nb.pages.count - 1)
    }

    func handleInk(_ page: Page, _ drawing: PKDrawing) {
        store.setDrawing(drawing, pageID: page.id)

        // Read the handwriting a moment after the last stroke so search stays current.
        let pageID = page.id
        let size = page.size
        recogTask?.cancel()
        recogTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            let text = await HandwritingRecognizer.recognise(drawing, pageSize: size)
            if Task.isCancelled { return }
            store.updatePage(notebookID, pageID, touch: false) { $0.recognisedText = text }
        }
    }

    func importPhoto(_ item: PhotosPickerItem?, pageID: UUID) {
        guard let item = item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            if let data = data, let id = store.addImage(data: data, notebookID: notebookID, pageID: pageID) {
                state.select(.text)
                state.selectedImageID = id
            } else {
                message = "That picture could not be added."
            }
            photoItem = nil
        }
    }

    func convertHandwriting(_ page: Page) {
        store.flushDrawings()
        recognisedText = ""
        recognising = true
        showText = true
        let drawing = store.drawing(for: page.id)
        let size = page.size
        let pageID = page.id
        Task {
            let text = await HandwritingRecognizer.recognise(drawing, pageSize: size)
            recognisedText = text
            recognising = false
            store.updatePage(notebookID, pageID, touch: false) { $0.recognisedText = text }
        }
    }

    func insertRecognisedText(_ page: Page) {
        let drawing = store.drawing(for: page.id)
        let below = drawing.strokes.isEmpty ? 80.0 : Double(drawing.bounds.maxY) + 30
        let y = min(max(below, 40), max(page.height - 200, 40))
        var box = TextBox(x: 60, y: y, width: page.width - 120, height: 160, colorHex: state.penColor.hexString)
        box.text = recognisedText
        store.updatePage(notebookID, page.id) { $0.textBoxes.append(box) }
        showText = false
        state.select(.text)
        state.selectedBoxID = box.id
    }

    func exportPDF() {
        busy = true
        Task {
            do {
                let url = try await store.exportPDF(notebookID: notebookID)
                shareItem = ShareItem(urls: [url])
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    func exportPNG(_ page: Page) {
        busy = true
        Task {
            do {
                let url = try await store.exportPNG(notebookID: notebookID, pageID: page.id)
                shareItem = ShareItem(urls: [url])
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    func updateSelectedBox(_ page: Page, _ change: @escaping (inout TextBox) -> Void) {
        guard let id = state.selectedBoxID else { return }
        store.updatePage(notebookID, page.id) { p in
            if let i = p.textBoxes.firstIndex(where: { $0.id == id }) {
                change(&p.textBoxes[i])
            }
        }
    }

    func applyColour(_ color: Color, page: Page) {
        state.setActiveColor(color)
        if state.tool == .text {
            let hex = color.hexString
            updateSelectedBox(page) { $0.colorHex = hex }
        }
    }
}
