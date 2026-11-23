import SwiftUI
import PhotosUI

// Tool bar, text-box inspector, page bar and the "more" menu.
extension EditorView {

    // MARK: Tool bar

    func toolsBar(_ page: Page) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                undoRedoGroup
                barDivider
                toolGroup
                barDivider
                styleGroup(page)
                insertGroup
                barDivider
                zoomGroup
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.35))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }

    func barButton(_ symbol: String,
                   label: String,
                   active: Bool = false,
                   tint: Color? = nil,
                   enabled: Bool = true,
                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 36)
                .foregroundColor(active ? Color.white : (tint ?? Color.primary))
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(active ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private var undoRedoGroup: some View {
        HStack(spacing: 2) {
            barButton("arrow.uturn.backward", label: "Undo", enabled: state.canUndo) { state.undo() }
            barButton("arrow.uturn.forward", label: "Redo", enabled: state.canRedo) { state.redo() }
        }
    }

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                barButton(tool.symbol, label: tool.title, active: state.tool == tool) {
                    state.select(tool)
                }
            }
        }
    }

    @ViewBuilder
    private func styleGroup(_ page: Page) -> some View {
        if state.usesColour {
            HStack(spacing: 7) {
                ForEach(EditorState.palette, id: \.self) { hex in
                    swatch(hex, page: page)
                }
                ColorPicker("Colour", selection: Binding(
                    get: { state.activeColor },
                    set: { applyColour($0, page: page) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
            .padding(.horizontal, 4)
        }
        if state.usesWidth {
            HStack(spacing: 6) {
                Image(systemName: "scribble").foregroundColor(.secondary)
                Slider(value: Binding(
                    get: { state.activeWidth },
                    set: { state.setActiveWidth($0) }
                ), in: state.widthRange)
                .frame(width: 120)
                Text("\(Int(state.activeWidth))")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 26)
            }
        }
        if state.tool == .eraser {
            Picker("Eraser", selection: $state.eraserIsVector) {
                Text("Stroke").tag(true)
                Text("Pixel").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
        if state.tool == .shape {
            Picker("Shape", selection: $state.shape) {
                ForEach(ShapeKind.allCases) { kind in
                    Image(systemName: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
    }

    private func swatch(_ hex: String, page: Page) -> some View {
        let selected = state.activeColor.hexString == hex
        return Button {
            applyColour(Color(hex: hex), page: page)
        } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0.18), lineWidth: selected ? 2.5 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var insertGroup: some View {
        HStack(spacing: 2) {
            barDivider
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 42, height: 36)
                    .foregroundColor(.primary)
            }
            .accessibilityLabel("Add picture")

            barButton(audio.isRecording ? "record.circle.fill" : "mic",
                      label: "Audio",
                      tint: audio.isRecording ? Color.red : nil) {
                showAudio = true
            }

            barButton(state.pencilOnly ? "pencil.tip.crop.circle" : "hand.draw",
                      label: state.pencilOnly ? "Apple Pencil only. Tap to let fingers draw." : "Fingers draw. Tap for Apple Pencil only.",
                      active: state.pencilOnly) {
                state.pencilOnly.toggle()
            }
        }
    }

    private var zoomGroup: some View {
        HStack(spacing: 2) {
            barButton("minus.magnifyingglass", label: "Zoom out") { setZoom(state.zoom - 0.25) }
            Button {
                setZoom(1)
            } label: {
                Text("\(Int((state.zoom * 100).rounded()))%")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(width: 48, height: 36)
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset zoom")
            barButton("plus.magnifyingglass", label: "Zoom in") { setZoom(state.zoom + 0.25) }
        }
    }

    // MARK: Text box and picture inspector

    func objectInspector(_ page: Page) -> some View {
        HStack(spacing: 10) {
            if let id = state.selectedBoxID, let box = page.textBoxes.first(where: { $0.id == id }) {
                Image(systemName: "textformat").foregroundColor(.secondary)
                Button {
                    updateSelectedBox(page) { $0.fontSize = max(10, $0.fontSize - 2) }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                Text("\(Int(box.fontSize)) pt")
                    .font(.footnote.monospacedDigit())
                    .frame(width: 46)
                Button {
                    updateSelectedBox(page) { $0.fontSize = min(96, $0.fontSize + 2) }
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                Button {
                    updateSelectedBox(page) { $0.bold.toggle() }
                } label: {
                    Image(systemName: "bold")
                        .foregroundColor(box.bold ? Color.accentColor : Color.primary)
                }
                Text("Pick a colour above to recolour this box.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if state.selectedImageID != nil {
                Image(systemName: "photo").foregroundColor(.secondary)
                Text("Drag the picture to move it. Use the corner handle to resize.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "hand.tap").foregroundColor(.secondary)
                Text("Tap the page to add a text box. Tap a box or picture to edit it.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(UIColor.tertiarySystemBackground))
    }

    // MARK: Page bar

    func pageBar(_ nb: Notebook, _ index: Int) -> some View {
        HStack(spacing: 20) {
            Button {
                goToPage(index - 1, in: nb)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index == 0)

            Text("Page \(index + 1) of \(nb.pages.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())

            Button {
                goToPage(index + 1, in: nb)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index >= nb.pages.count - 1)

            Spacer()

            Button {
                let newIndex = store.addPage(to: notebookID, after: index)
                pageIndex = newIndex
            } label: {
                Label("Add page", systemImage: "plus.square")
            }

            Button {
                store.flushDrawings()
                showPages = true
            } label: {
                Label("Pages", systemImage: "square.grid.2x2")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: More menu

    func moreMenu(_ nb: Notebook, _ page: Page) -> some View {
        let isPDFPage = page.pdfPageIndex != nil
        return Menu {
            Button {
                let newIndex = store.addPage(to: notebookID, after: currentIndex(nb))
                pageIndex = newIndex
            } label: {
                Label("Add page", systemImage: "plus.square")
            }

            Button {
                if let newIndex = store.duplicatePage(page.id, in: notebookID) {
                    pageIndex = newIndex
                }
            } label: {
                Label("Duplicate page", systemImage: "plus.square.on.square")
            }

            Menu {
                ForEach(PaperTemplate.allCases) { template in
                    Button(template.title) {
                        store.setPaper(notebookID: notebookID, pageID: page.id, template: template, tone: nil)
                    }
                }
                ForEach(PaperTone.allCases) { tone in
                    Button("\(tone.title) paper") {
                        store.setPaper(notebookID: notebookID, pageID: page.id, template: nil, tone: tone)
                    }
                }
                Button("Use this paper for the whole notebook") {
                    store.setPaper(notebookID: notebookID, pageID: nil, template: page.template, tone: page.tone)
                }
            } label: {
                Label("Paper", systemImage: "doc.plaintext")
            }
            .disabled(isPDFPage)

            Divider()

            Button {
                convertHandwriting(page)
            } label: {
                Label("Handwriting to text", systemImage: "text.viewfinder")
            }

            Button {
                exportPDF()
            } label: {
                Label("Export notebook as PDF", systemImage: "doc.richtext")
            }

            Button {
                exportPNG(page)
            } label: {
                Label("Export page as image", systemImage: "photo")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
