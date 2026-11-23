import SwiftUI
import PencilKit
import UIKit

enum StoreError: LocalizedError {
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "That file could not be opened as a PDF."
        }
    }
}

/// Owns every folder, notebook and page. Data lives in Documents/InkNote so the
/// Files app can see it (file sharing is enabled in Info.plist).
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var data = LibraryData()

    let rootDir: URL
    let drawingsDir: URL
    let pdfsDir: URL
    let imagesDir: URL
    let audioDir: URL
    private let libraryURL: URL

    private var drawingCache: [UUID: PKDrawing] = [:]
    private var dirtyDrawings: Set<UUID> = []
    private var drawingFlushTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private let thumbCache = NSCache<NSString, UIImage>()
    /// True when the library had to be rebuilt, in which case no clean-up sweeps should run.
    private var didSeed = false

    static let thumbnailWidth: CGFloat = 180

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("InkNote", isDirectory: true)
        rootDir = root
        drawingsDir = root.appendingPathComponent("drawings", isDirectory: true)
        pdfsDir = root.appendingPathComponent("pdfs", isDirectory: true)
        imagesDir = root.appendingPathComponent("images", isDirectory: true)
        audioDir = root.appendingPathComponent("audio", isDirectory: true)
        libraryURL = root.appendingPathComponent("library.json")
        for dir in [rootDir, drawingsDir, pdfsDir, imagesDir, audioDir, CoverImageStore.directory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
        sweepOrphanCovers()
    }

    // MARK: Persistence

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load() {
        if let raw = try? Data(contentsOf: libraryURL) {
            if let lib = try? makeDecoder().decode(LibraryData.self, from: raw) {
                data = lib
                return
            }
            // The file exists but could not be read. Keep a copy before anything overwrites it.
            let backup = rootDir.appendingPathComponent("library.unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: libraryURL, to: backup)
        }
        seedWelcome()
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            let raw = try makeEncoder().encode(data)
            try raw.write(to: libraryURL, options: .atomic)
        } catch {
            print("InkNote: could not save library: \(error)")
        }
    }

    /// Writes any ink and metadata that is still waiting. Call before leaving the editor or exporting.
    func flushAll() {
        flushDrawings()
        saveNow()
    }

    private func seedWelcome() {
        didSeed = true
        var nb = Notebook(title: "Welcome to InkNote",
                          cover: Cover(colorHex: "#3B6FD4", symbol: "pencil.and.scribble", style: .gradient))
        var page = nb.makePage()
        page.textBoxes = [
            TextBox(x: 100, y: 130, width: 620, height: 60, fontSize: 36, bold: true, colorHex: "#2B2D42"),
            TextBox(x: 100, y: 220, width: 620, height: 400, fontSize: 24, colorHex: "#1B1B1F")
        ]
        page.textBoxes[0].text = "Welcome to InkNote"
        page.textBoxes[1].text = """
        • Write with your Apple Pencil. Pick the pen, highlighter or pencil in the toolbar.
        • Tap the A tool to type text boxes, and the photo button to add pictures.
        • Use the shape tool for lines, arrows, rectangles and circles.
        • Import a PDF from the + button on the home screen to annotate slides and worksheets.
        • Handwriting is read on the device, so search finds your notes.
        • The microphone button records audio while you write.
        """
        nb.pages = [page]
        data.notebooks = [nb]
    }

    // MARK: Lookup

    func notebook(_ id: UUID) -> Notebook? {
        data.notebooks.first { $0.id == id }
    }

    func folder(_ id: UUID) -> Folder? {
        data.folders.first { $0.id == id }
    }

    func folders(in parent: UUID?) -> [Folder] {
        data.folders.filter { $0.parentID == parent }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func notebooks(in parent: UUID?) -> [Notebook] {
        data.notebooks.filter { $0.parentID == parent }.sorted { $0.modified > $1.modified }
    }

    func descendantFolderIDs(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var queue = [id]
        while let current = queue.popLast() {
            for f in data.folders where f.parentID == current {
                result.insert(f.id)
                queue.append(f.id)
            }
        }
        return result
    }

    // MARK: Mutation helpers

    func updateNotebook(_ id: UUID, touch: Bool = true, _ body: (inout Notebook) -> Void) {
        guard let i = data.notebooks.firstIndex(where: { $0.id == id }) else { return }
        body(&data.notebooks[i])
        if touch { data.notebooks[i].modified = Date() }
        thumbCache.removeAllObjects()
        scheduleSave()
    }

    func updatePage(_ notebookID: UUID, _ pageID: UUID, touch: Bool = true, _ body: (inout Page) -> Void) {
        updateNotebook(notebookID, touch: touch) { nb in
            if let j = nb.pages.firstIndex(where: { $0.id == pageID }) {
                body(&nb.pages[j])
            }
        }
    }

    // MARK: Notebooks

    @discardableResult
    func createNotebook(_ draft: NotebookDraft, parent: UUID?) -> UUID {
        var nb = Notebook(title: draft.title.isEmpty ? "Untitled notebook" : draft.title,
                          cover: draft.cover, parentID: parent,
                          template: draft.template, tone: draft.tone, landscape: draft.landscape)
        nb.pages = [nb.makePage()]
        data.notebooks.append(nb)
        scheduleSave()
        return nb.id
    }

    func applyDetails(_ draft: NotebookDraft, to id: UUID) {
        let oldCover = notebook(id)?.cover
        updateNotebook(id) { nb in
            nb.title = draft.title.isEmpty ? nb.title : draft.title
            nb.cover = draft.cover
            nb.template = draft.template
            nb.tone = draft.tone
        }
        // Remove cover pictures that nothing uses any more.
        if let old = oldCover {
            for name in [old.imageFileName, old.originalFileName].compactMap({ $0 }) where !isReferenced(name) {
                CoverImageStore.remove(name)
            }
        }
    }

    /// Deletes files in the covers folder that no notebook points to, left behind by a cancelled edit.
    private func sweepOrphanCovers() {
        if didSeed { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: CoverImageStore.directory.path)) ?? []
        for name in names where !isReferenced(name) {
            CoverImageStore.remove(name)
        }
    }

    func moveNotebook(_ id: UUID, to parent: UUID?) {
        updateNotebook(id, touch: false) { $0.parentID = parent }
    }

    func duplicateNotebook(_ id: UUID) {
        guard let src = notebook(id) else { return }
        flushDrawings()
        var copy = src
        copy.id = UUID()
        copy.title = src.title + " copy"
        copy.created = Date()
        copy.modified = Date()
        copy.audio = src.audio.map { clip in
            var c = clip
            c.id = UUID()
            return c
        }
        copy.pages = src.pages.map { duplicatePageValue($0) }
        data.notebooks.append(copy)
        scheduleSave()
    }

    func deleteNotebook(_ id: UUID) {
        guard let nb = notebook(id) else { return }
        for p in nb.pages {
            removeDrawingFiles(p.id)
        }
        data.notebooks.removeAll { $0.id == id }
        cleanUpFiles(for: nb)
        scheduleSave()
    }

    private func cleanUpFiles(for nb: Notebook) {
        if let pdf = nb.pdfFileName, !isReferenced(pdf) {
            try? FileManager.default.removeItem(at: pdfsDir.appendingPathComponent(pdf))
        }
        for page in nb.pages {
            for img in page.images where !isReferenced(img.fileName) {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(img.fileName))
            }
        }
        for clip in nb.audio where !isReferenced(clip.fileName) {
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(clip.fileName))
        }
        for name in [nb.cover.imageFileName, nb.cover.originalFileName].compactMap({ $0 }) where !isReferenced(name) {
            CoverImageStore.remove(name)
        }
    }

    func isReferenced(_ fileName: String) -> Bool {
        for nb in data.notebooks {
            if nb.pdfFileName == fileName { return true }
            if nb.cover.imageFileName == fileName || nb.cover.originalFileName == fileName { return true }
            if nb.audio.contains(where: { $0.fileName == fileName }) { return true }
            for p in nb.pages where p.images.contains(where: { $0.fileName == fileName }) { return true }
        }
        return false
    }

    // MARK: Folders

    @discardableResult
    func createFolder(title: String, parent: UUID?) -> UUID {
        let f = Folder(title: title.isEmpty ? "New folder" : title, parentID: parent)
        data.folders.append(f)
        scheduleSave()
        return f.id
    }

    func renameFolder(_ id: UUID, to title: String) {
        guard let i = data.folders.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        data.folders[i].title = title
        scheduleSave()
    }

    func recolourFolder(_ id: UUID, hex: String) {
        guard let i = data.folders.firstIndex(where: { $0.id == id }) else { return }
        data.folders[i].colorHex = hex
        scheduleSave()
    }

    func moveFolder(_ id: UUID, to parent: UUID?) {
        if let parent = parent, parent == id || descendantFolderIDs(of: id).contains(parent) { return }
        guard let i = data.folders.firstIndex(where: { $0.id == id }) else { return }
        data.folders[i].parentID = parent
        scheduleSave()
    }

    func deleteFolder(_ id: UUID) {
        let doomed = descendantFolderIDs(of: id).union([id])
        let books = data.notebooks.filter { nb in
            if let p = nb.parentID { return doomed.contains(p) }
            return false
        }
        for nb in books { deleteNotebook(nb.id) }
        data.folders.removeAll { doomed.contains($0.id) }
        scheduleSave()
    }

    // MARK: Pages

    @discardableResult
    func addPage(to notebookID: UUID, after index: Int) -> Int {
        var newIndex = 0
        updateNotebook(notebookID) { nb in
            let at = min(max(index + 1, 0), nb.pages.count)
            nb.pages.insert(nb.makePage(), at: at)
            newIndex = at
        }
        return newIndex
    }

    private func duplicatePageValue(_ page: Page) -> Page {
        var copy = page
        copy.id = UUID()
        copy.textBoxes = page.textBoxes.map { box in
            var b = box
            b.id = UUID()
            return b
        }
        copy.images = page.images.map { img in
            var i = img
            i.id = UUID()
            return i
        }
        if FileManager.default.fileExists(atPath: drawingURL(page.id).path) {
            try? FileManager.default.copyItem(at: drawingURL(page.id), to: drawingURL(copy.id))
        }
        return copy
    }

    @discardableResult
    func duplicatePage(_ pageID: UUID, in notebookID: UUID) -> Int? {
        flushDrawings()
        var newIndex: Int?
        updateNotebook(notebookID) { nb in
            guard let i = nb.pages.firstIndex(where: { $0.id == pageID }) else { return }
            nb.pages.insert(duplicatePageValue(nb.pages[i]), at: i + 1)
            newIndex = i + 1
        }
        return newIndex
    }

    func deletePages(at offsets: IndexSet, in notebookID: UUID) {
        updateNotebook(notebookID) { nb in
            if offsets.count >= nb.pages.count { return }
            for i in offsets { removeDrawingFiles(nb.pages[i].id) }
            nb.pages.remove(atOffsets: offsets)
        }
    }

    func movePages(from source: IndexSet, to destination: Int, in notebookID: UUID) {
        updateNotebook(notebookID) { nb in
            nb.pages.move(fromOffsets: source, toOffset: destination)
        }
    }

    func setPaper(notebookID: UUID, pageID: UUID?, template: PaperTemplate?, tone: PaperTone?) {
        updateNotebook(notebookID) { nb in
            for i in nb.pages.indices {
                if let pageID = pageID, nb.pages[i].id != pageID { continue }
                if nb.pages[i].pdfPageIndex != nil { continue }
                if let t = template { nb.pages[i].template = t }
                if let tn = tone { nb.pages[i].tone = tn }
            }
            if pageID == nil {
                if let t = template { nb.template = t }
                if let tn = tone { nb.tone = tn }
            }
        }
    }

    // MARK: Ink

    func drawingURL(_ pageID: UUID) -> URL {
        drawingsDir.appendingPathComponent("\(pageID.uuidString).drawing")
    }

    func drawing(for pageID: UUID) -> PKDrawing {
        if let cached = drawingCache[pageID] { return cached }
        var result = PKDrawing()
        if let raw = try? Data(contentsOf: drawingURL(pageID)), let d = try? PKDrawing(data: raw) {
            result = d
        }
        drawingCache[pageID] = result
        return result
    }

    func setDrawing(_ drawing: PKDrawing, pageID: UUID) {
        drawingCache[pageID] = drawing
        dirtyDrawings.insert(pageID)
        thumbCache.removeObject(forKey: pageID.uuidString as NSString)
        drawingFlushTask?.cancel()
        drawingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.flushDrawings()
        }
    }

    func flushDrawings() {
        drawingFlushTask?.cancel()
        for id in dirtyDrawings {
            if let d = drawingCache[id] {
                try? d.dataRepresentation().write(to: drawingURL(id), options: .atomic)
            }
        }
        dirtyDrawings.removeAll()
    }

    private func removeDrawingFiles(_ pageID: UUID) {
        try? FileManager.default.removeItem(at: drawingURL(pageID))
        drawingCache[pageID] = nil
        dirtyDrawings.remove(pageID)
        thumbCache.removeObject(forKey: pageID.uuidString as NSString)
    }

    // MARK: Pictures and audio

    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }
    func audioURL(_ name: String) -> URL { audioDir.appendingPathComponent(name) }
    func pdfURL(_ name: String) -> URL { pdfsDir.appendingPathComponent(name) }

    @discardableResult
    func addImage(data raw: Data, notebookID: UUID, pageID: UUID) -> UUID? {
        guard let img = UIImage(data: raw), img.size.width > 0, img.size.height > 0 else { return nil }
        let maxSide: CGFloat = 2000
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let newSize = CGSize(width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: imageURL(name))
        } catch {
            return nil
        }
        let itemID = UUID()
        updatePage(notebookID, pageID) { page in
            let w = min(380, page.width - 120)
            let h = w * Double(newSize.height / newSize.width)
            page.images.append(ImageItem(id: itemID, fileName: name, x: 60, y: 120, width: w, height: h))
        }
        return itemID
    }

    func addClip(_ clip: AudioClip, to notebookID: UUID) {
        updateNotebook(notebookID) { $0.audio.append(clip) }
    }

    func deleteClip(_ clipID: UUID, from notebookID: UUID) {
        guard let nb = notebook(notebookID), let clip = nb.audio.first(where: { $0.id == clipID }) else { return }
        updateNotebook(notebookID) { $0.audio.removeAll { $0.id == clipID } }
        if !isReferenced(clip.fileName) {
            try? FileManager.default.removeItem(at: audioURL(clip.fileName))
        }
    }

    // MARK: PDF import

    @discardableResult
    func importPDF(from url: URL, parent: UUID?) throws -> UUID {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let name = UUID().uuidString + ".pdf"
        let dest = pdfsDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: dest)

        let sizes = PDFService.shared.pageSizes(url: dest)
        if sizes.isEmpty {
            try? FileManager.default.removeItem(at: dest)
            throw StoreError.invalidPDF
        }
        let pages: [Page] = sizes.enumerated().map { (i, s) in
            let w: Double = 820
            let h = (w * Double(s.height / max(s.width, 1))).rounded()
            return Page(template: .blank, width: w, height: h, pdfPageIndex: i)
        }
        let nb = Notebook(title: url.deletingPathExtension().lastPathComponent,
                          cover: Cover(colorHex: "#E4572E", symbol: "doc.richtext", style: .label),
                          parentID: parent, pages: pages, pdfFileName: name)
        data.notebooks.append(nb)
        scheduleSave()

        let nbID = nb.id
        Task.detached(priority: .utility) { [weak self] in
            let texts = PDFService.shared.pageTexts(url: dest)
            await self?.applyPDFTexts(nbID, texts)
        }
        return nbID
    }

    private func applyPDFTexts(_ notebookID: UUID, _ texts: [String]) {
        updateNotebook(notebookID, touch: false) { nb in
            for i in nb.pages.indices {
                if let idx = nb.pages[i].pdfPageIndex, idx < texts.count {
                    nb.pages[i].sourceText = texts[idx]
                }
            }
        }
    }

    // MARK: Search

    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = []
        for nb in data.notebooks {
            if nb.title.range(of: q, options: options) != nil {
                hits.append(SearchHit(notebookID: nb.id, notebookTitle: nb.title, pageIndex: 0, snippet: "Notebook title"))
            }
            for (i, p) in nb.pages.enumerated() {
                let boxes = p.textBoxes.map { $0.text }.joined(separator: " ")
                let text = [p.recognisedText, p.sourceText, boxes].joined(separator: " ")
                if let r = text.range(of: q, options: options) {
                    hits.append(SearchHit(notebookID: nb.id, notebookTitle: nb.title, pageIndex: i,
                                          snippet: snippet(in: text, around: r)))
                }
                if hits.count >= 200 { return hits }
            }
        }
        return hits
    }

    private func snippet(in text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
        var s = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }

    // MARK: Importing

    /// Adds folders and notebooks that were already given new IDs, for example from a backup.
    func appendImported(folders: [Folder], notebooks: [Notebook]) {
        data.folders.append(contentsOf: folders)
        data.notebooks.append(contentsOf: notebooks)
        scheduleSave()
    }

    // MARK: Rendering and export

    func renderInput(_ nb: Notebook, _ page: Page) -> PageRenderInput {
        PageRenderInput(page: page,
                        pdfURL: nb.pdfFileName.map { pdfURL($0) },
                        drawing: drawing(for: page.id),
                        imagesDir: imagesDir)
    }

    func thumbnail(notebookID: UUID, pageID: UUID) async -> UIImage? {
        let key = pageID.uuidString as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        guard let nb = notebook(notebookID), let page = nb.pages.first(where: { $0.id == pageID }) else { return nil }
        let input = renderInput(nb, page)
        let width = LibraryStore.thumbnailWidth
        let image = await Task.detached(priority: .utility) {
            PageRenderer.image(input, width: width)
        }.value
        thumbCache.setObject(image, forKey: key)
        return image
    }

    func exportPDF(notebookID: UUID) async throws -> URL {
        guard let nb = notebook(notebookID) else { throw ExportError.empty }
        flushDrawings()
        let inputs = nb.pages.map { renderInput(nb, $0) }
        let title = nb.title
        return try await Task.detached(priority: .userInitiated) {
            try Exporter.pdf(title: title, inputs: inputs)
        }.value
    }

    func exportPNG(notebookID: UUID, pageID: UUID) async throws -> URL {
        guard let nb = notebook(notebookID), let page = nb.pages.first(where: { $0.id == pageID }) else {
            throw ExportError.empty
        }
        flushDrawings()
        let input = renderInput(nb, page)
        let title = nb.title
        return try await Task.detached(priority: .userInitiated) {
            try Exporter.png(title: title, input: input)
        }.value
    }
}
