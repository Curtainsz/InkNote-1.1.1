import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Creates a notebook, or edits the cover and paper of an existing one.
struct NotebookSetupSheet: View {
    enum Mode {
        case create
        case edit
    }

    enum CoverMode {
        case preset
        case photo
    }

    let mode: Mode
    @State private var draft: NotebookDraft
    @State private var coverMode: CoverMode
    @State private var photoItem: PhotosPickerItem?
    @State private var cropRequest: CropRequest?
    @State private var showFileImporter = false
    /// Cover files written during this visit, so they can be removed if nothing keeps them.
    @State private var createdFiles: [String] = []
    @State private var message: String?
    let onSave: (NotebookDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    init(mode: Mode, draft: NotebookDraft, onSave: @escaping (NotebookDraft) -> Void) {
        self.mode = mode
        _draft = State(initialValue: draft)
        _coverMode = State(initialValue: draft.cover.style == .image ? .photo : .preset)
        self.onSave = onSave
    }

    private let swatchColumns = [GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 10)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Notebook title", text: $draft.title)
                }

                Section("Cover") {
                    HStack {
                        Spacer()
                        CoverView(title: draft.title, cover: draft.cover, size: CGSize(width: 130, height: 174))
                        Spacer()
                    }
                    .padding(.vertical, 8)

                    Picker("Cover type", selection: $coverMode) {
                        Text("Preset").tag(CoverMode.preset)
                        Text("Photo").tag(CoverMode.photo)
                    }
                    .pickerStyle(.segmented)

                    if coverMode == .preset {
                        presetControls
                    } else {
                        photoControls
                    }
                }

                Section("Paper") {
                    paperControls
                }
            }
            .navigationTitle(mode == .create ? "New notebook" : "Notebook details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        removeCreatedFiles(keeping: [])
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(mode == .create ? "Create" : "Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onChange(of: coverMode) { newMode in
            if newMode == .preset {
                if draft.cover.style == .image { draft.cover.style = .gradient }
            } else if draft.cover.imageFileName != nil {
                draft.cover.style = .image
            }
        }
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                photoItem = nil
                if let data = data {
                    beginCrop(data: data)
                } else {
                    message = "That picture could not be opened."
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.image]) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    beginCrop(data: data)
                } else {
                    message = "That picture could not be opened."
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .sheet(item: $cropRequest) { request in
            CoverCropView(
                image: request.image,
                onCancel: { cropRequest = nil },
                onDone: { cropped in finishCrop(cropped, request: request) }
            )
        }
        .alert("InkNote", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Cover controls

    @ViewBuilder
    private var presetControls: some View {
        LazyVGrid(columns: swatchColumns, spacing: 10) {
            ForEach(CoverOptions.palette, id: \.self) { hex in
                Button {
                    draft.cover.colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Color.primary.opacity(draft.cover.colorHex == hex ? 0.9 : 0), lineWidth: 3))
                }
                .buttonStyle(.plain)
            }
        }
        ColorPicker("Custom colour", selection: Binding(
            get: { Color(hex: draft.cover.colorHex) },
            set: { draft.cover.colorHex = $0.hexString }
        ), supportsOpacity: false)

        LazyVGrid(columns: swatchColumns, spacing: 10) {
            ForEach(CoverOptions.symbols, id: \.self) { name in
                Button {
                    draft.cover.symbol = name
                } label: {
                    Image(systemName: name)
                        .font(.system(size: 18))
                        .frame(width: 40, height: 40)
                        .background(draft.cover.symbol == name ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }

        Picker("Style", selection: $draft.cover.style) {
            ForEach(CoverStyle.presets) { style in
                Text(style.title).tag(style)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var photoControls: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            Label("Choose from Photos", systemImage: "photo.on.rectangle")
        }
        Button {
            showFileImporter = true
        } label: {
            Label("Choose from Files", systemImage: "folder")
        }
        Button {
            pasteImage()
        } label: {
            Label("Paste copied image", systemImage: "doc.on.clipboard")
        }

        if draft.cover.style == .image {
            Toggle("Show title on cover", isOn: $draft.cover.showTitle)
            if draft.cover.originalFileName != nil {
                Button {
                    recrop()
                } label: {
                    Label("Crop again", systemImage: "crop")
                }
            }
            Button(role: .destructive) {
                removePhoto()
            } label: {
                Label("Remove photo", systemImage: "trash")
            }
        } else {
            Text("Pick a picture and crop it to the cover shape. Your preset covers are still there under Preset.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Paper controls

    @ViewBuilder
    private var paperControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(PaperTemplate.allCases) { template in
                    Button {
                        draft.template = template
                    } label: {
                        VStack(spacing: 4) {
                            Image(uiImage: PaperRenderer.image(template: template, tone: draft.tone,
                                                               size: PageMetrics.portrait, scale: 0.4))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 78, height: 110)
                                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: draft.template == template ? 3 : 0))
                                .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
                            Text(template.title).font(.caption.weight(.semibold))
                            Text(template.detail).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }

        Picker("Paper colour", selection: $draft.tone) {
            ForEach(PaperTone.allCases) { tone in
                Text(tone.title).tag(tone)
            }
        }
        .pickerStyle(.segmented)

        if mode == .create {
            Picker("Orientation", selection: $draft.landscape) {
                Text("Portrait").tag(false)
                Text("Landscape").tag(true)
            }
            .pickerStyle(.segmented)
        } else {
            Text("Paper changes apply to pages you add from now on. Use the editor menu to restyle existing pages.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Photo handling

    private func beginCrop(data: Data) {
        if let image = CoverImageStore.downsampled(data: data, maxPixel: 2000) {
            cropRequest = CropRequest(image: image, originalName: nil)
        } else {
            message = "That picture could not be opened."
        }
    }

    private func pasteImage() {
        if let image = UIPasteboard.general.image, let data = image.pngData() {
            beginCrop(data: data)
        } else {
            message = "There is no copied image to paste."
        }
    }

    private func recrop() {
        guard let name = draft.cover.originalFileName,
              let image = CoverImageStore.downsampled(url: CoverImageStore.url(name), maxPixel: 2000) else {
            message = "The original picture is no longer available. Choose it again."
            return
        }
        cropRequest = CropRequest(image: image, originalName: name)
    }

    private func finishCrop(_ cropped: UIImage, request: CropRequest) {
        let keepsOriginal = request.originalName != nil
        guard let saved = CoverImageStore.save(cropped: cropped, original: keepsOriginal ? nil : request.image) else {
            cropRequest = nil
            message = "The cover could not be saved."
            return
        }

        // A cropped file made earlier in this visit has never been saved, so it can go now.
        if let previous = draft.cover.imageFileName, createdFiles.contains(previous) {
            CoverImageStore.remove(previous)
            createdFiles.removeAll { $0 == previous }
        }
        createdFiles.append(saved.cover)
        draft.cover.imageFileName = saved.cover

        if let newOriginal = saved.original {
            if let previous = draft.cover.originalFileName, createdFiles.contains(previous) {
                CoverImageStore.remove(previous)
                createdFiles.removeAll { $0 == previous }
            }
            createdFiles.append(newOriginal)
            draft.cover.originalFileName = newOriginal
        }
        draft.cover.style = .image
        cropRequest = nil
    }

    private func removePhoto() {
        draft.cover.style = .gradient
        draft.cover.imageFileName = nil
        draft.cover.originalFileName = nil
        coverMode = .preset
    }

    private func removeCreatedFiles(keeping kept: [String]) {
        for name in createdFiles where !kept.contains(name) {
            CoverImageStore.remove(name)
        }
        createdFiles = createdFiles.filter { kept.contains($0) }
    }

    private func save() {
        var saved = draft
        if saved.cover.style != .image {
            saved.cover.imageFileName = nil
            saved.cover.originalFileName = nil
        }
        let kept = [saved.cover.imageFileName, saved.cover.originalFileName].compactMap { $0 }
        removeCreatedFiles(keeping: kept)
        onSave(saved)
        dismiss()
    }
}

/// One text field in a sheet, for naming and renaming folders.
struct NameSheet: View {
    let title: String
    let actionTitle: String
    @State private var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, actionTitle: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        _text = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $text)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(actionTitle) {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}
