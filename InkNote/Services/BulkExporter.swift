import UIKit
import PencilKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdfEach, pdfMerged, images, backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdfEach: return "PDF for each notebook"
        case .pdfMerged: return "One merged PDF"
        case .images: return "Page images (PNG)"
        case .backup: return "InkNote backup"
        }
    }

    var detail: String {
        switch self {
        case .pdfEach: return "Easy to read and share anywhere."
        case .pdfMerged: return "Every selected page in a single PDF."
        case .images: return "One picture per page, in a folder per notebook."
        case .backup: return "Keeps everything editable. Opens again in InkNote."
        }
    }

    var symbol: String {
        switch self {
        case .pdfEach: return "doc.richtext"
        case .pdfMerged: return "doc.on.doc"
        case .images: return "photo.on.rectangle"
        case .backup: return "externaldrive"
        }
    }
}

struct ExportOptions {
    var format: ExportFormat = .pdfEach
    var keepFolders: Bool = true
    var includeAudio: Bool = false
}

/// One notebook to export, with the folders it sits in (relative to where the selection was made).
struct ExportSource {
    var notebook: Notebook
    var folderPath: [String]
}

/// Lets the Cancel button reach work running on a background thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

enum BulkExporter {
    /// Builds the export in a temporary folder and returns the single file to hand over:
    /// the PDF or backup itself, or one zip when there are several files.
    static func run(sources: [ExportSource],
                    folders: [Folder],
                    options: ExportOptions,
                    paths: StorePaths,
                    progress: @escaping (Double, String) -> Void,
                    cancel: CancelFlag) throws -> URL {
        if sources.isEmpty { throw ExportError.empty }
        let fm = FileManager.default
        let stamp = dateStamp()
        let work = fm.temporaryDirectory.appendingPathComponent("InkNote Export \(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        do {
            switch options.format {
            case .backup:
                let url = work.appendingPathComponent("InkNote backup \(stamp).\(BackupService.fileExtension)")
                try BackupService.writeBackup(
                    to: url,
                    notebooks: sources.map { $0.notebook },
                    folders: folders,
                    includeAudio: options.includeAudio,
                    paths: paths,
                    progress: { progress($0, "Packing backup") },
                    cancel: cancel
                )
                return url

            case .pdfMerged:
                return try mergedPDF(sources: sources, paths: paths, work: work, stamp: stamp,
                                     progress: progress, cancel: cancel)

            case .pdfEach, .images:
                return try exportFiles(sources: sources, options: options, paths: paths, work: work,
                                       stamp: stamp, progress: progress, cancel: cancel)
            }
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    // MARK: Merged PDF

    private static func mergedPDF(sources: [ExportSource],
                                  paths: StorePaths,
                                  work: URL,
                                  stamp: String,
                                  progress: @escaping (Double, String) -> Void,
                                  cancel: CancelFlag) throws -> URL {
        var allPages: [(notebook: Notebook, page: Page)] = []
        for source in sources {
            for page in source.notebook.pages {
                allPages.append((source.notebook, page))
            }
        }
        guard let first = allPages.first else { throw ExportError.empty }

        let url = work.appendingPathComponent("InkNote merged \(stamp).pdf")
        var cancelled = false
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.page.size))
        try renderer.writePDF(to: url) { ctx in
            for (index, entry) in allPages.enumerated() {
                if cancel.isCancelled {
                    cancelled = true
                    break
                }
                autoreleasepool {
                    ctx.beginPage(withBounds: CGRect(origin: .zero, size: entry.page.size), pageInfo: [:])
                    PageRenderer.draw(renderInput(entry.notebook, entry.page, paths), in: ctx.cgContext, rasterScale: 2)
                }
                progress(Double(index + 1) / Double(allPages.count), "Rendering pages")
            }
        }
        if cancelled { throw ZipError.cancelled }
        return url
    }

    // MARK: PDF per notebook, or page images

    private static func exportFiles(sources: [ExportSource],
                                    options: ExportOptions,
                                    paths: StorePaths,
                                    work: URL,
                                    stamp: String,
                                    progress: @escaping (Double, String) -> Void,
                                    cancel: CancelFlag) throws -> URL {
        let fm = FileManager.default
        var produced: [(relative: String, url: URL)] = []
        var usedNames = Set<String>()
        let totalPages = max(sources.reduce(0) { $0 + $1.notebook.pages.count }, 1)
        var donePages = 0

        /// A path that has not been used yet, adding " (2)", " (3)" and so on when needed.
        func uniqueName(_ directory: [String], _ base: String, _ ext: String?) -> String {
            let dir = directory.joined(separator: "/")
            var n = 1
            while true {
                var name = n == 1 ? base : "\(base) (\(n))"
                if let ext = ext { name += ".\(ext)" }
                let relative = dir.isEmpty ? name : "\(dir)/\(name)"
                if !usedNames.contains(relative.lowercased()) {
                    usedNames.insert(relative.lowercased())
                    return relative
                }
                n += 1
            }
        }

        func tick() {
            donePages += 1
            let fraction = Double(donePages) / Double(totalPages)
            progress(0.9 * min(fraction, 1), "Rendering pages")
        }

        for source in sources {
            if cancel.isCancelled { throw ZipError.cancelled }
            let nb = source.notebook
            let parts = (options.keepFolders ? source.folderPath : []).map { Exporter.fileName($0) }
            let title = Exporter.fileName(nb.title)
            let audioFolderBase: String

            if options.format == .images {
                let folder = uniqueName(parts, title, nil)
                audioFolderBase = folder
                for (index, page) in nb.pages.enumerated() {
                    if cancel.isCancelled { throw ZipError.cancelled }
                    let relative = "\(folder)/Page \(String(format: "%02d", index + 1)).png"
                    let url = work.appendingPathComponent(relative)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try autoreleasepool { () throws -> Void in
                        let input = renderInput(nb, page, paths)
                        let image = PageRenderer.image(input, width: CGFloat(page.width) * 2)
                        guard let png = image.pngData() else { throw ExportError.encodingFailed }
                        try png.write(to: url)
                    }
                    produced.append((relative, url))
                    tick()
                }
            } else {
                let relative = uniqueName(parts, title, "pdf")
                let url = work.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writePDF(nb, to: url, paths: paths, cancel: cancel, tick: tick)
                produced.append((relative, url))
                audioFolderBase = (parts + ["\(title) audio"]).joined(separator: "/")
            }

            if options.includeAudio {
                for clip in nb.audio {
                    guard BackupService.safeName(clip.fileName) != nil else { continue }
                    let audioSource = paths.audio.appendingPathComponent(clip.fileName)
                    guard fm.fileExists(atPath: audioSource.path) else { continue }
                    let folder = options.format == .images ? "\(audioFolderBase)/Audio" : audioFolderBase
                    let relative = uniqueName([folder], Exporter.fileName(clip.title), "m4a")
                    let destination = work.appendingPathComponent(relative)
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: audioSource, to: destination)
                    produced.append((relative, destination))
                }
            }
        }

        if produced.isEmpty { throw ExportError.empty }
        if produced.count == 1, let only = produced.first {
            return only.url
        }

        let zipURL = work.appendingPathComponent("InkNote export \(stamp).zip")
        let zip = try ZipWriter(url: zipURL)
        do {
            let root = "InkNote export \(stamp)"
            for (index, item) in produced.enumerated() {
                if cancel.isCancelled { throw ZipError.cancelled }
                try zip.addFile("\(root)/\(item.relative)", from: item.url)
                progress(0.9 + 0.1 * Double(index + 1) / Double(produced.count), "Zipping")
            }
            try zip.finish()
        } catch {
            zip.abandon()
            throw error
        }
        return zipURL
    }

    private static func writePDF(_ nb: Notebook,
                                 to url: URL,
                                 paths: StorePaths,
                                 cancel: CancelFlag,
                                 tick: () -> Void) throws {
        guard let first = nb.pages.first else { throw ExportError.empty }
        var cancelled = false
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
        try renderer.writePDF(to: url) { ctx in
            for page in nb.pages {
                if cancel.isCancelled {
                    cancelled = true
                    break
                }
                autoreleasepool {
                    ctx.beginPage(withBounds: CGRect(origin: .zero, size: page.size), pageInfo: [:])
                    PageRenderer.draw(renderInput(nb, page, paths), in: ctx.cgContext, rasterScale: 2)
                }
                tick()
            }
        }
        if cancelled { throw ZipError.cancelled }
    }

    // MARK: Helpers

    /// Reads the ink for a page straight from disk, so one page at a time is in memory.
    static func renderInput(_ nb: Notebook, _ page: Page, _ paths: StorePaths) -> PageRenderInput {
        var drawing = PKDrawing()
        if let data = try? Data(contentsOf: paths.drawing(page.id)), let d = try? PKDrawing(data: data) {
            drawing = d
        }
        return PageRenderInput(page: page,
                               pdfURL: nb.pdfFileName.map { paths.pdfs.appendingPathComponent($0) },
                               drawing: drawing,
                               imagesDir: paths.images)
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

extension LibraryStore {
    /// Gathers what the person ticked: notebooks directly, and everything inside ticked folders.
    /// Paths are relative to the folder the selection was made in.
    func exportSelection(notebookIDs: Set<UUID>, folderIDs: Set<UUID>) -> (sources: [ExportSource], folders: [Folder]) {
        flushDrawings()

        var sources: [ExportSource] = []
        var included: [Folder] = []

        for nb in data.notebooks where notebookIDs.contains(nb.id) {
            sources.append(ExportSource(notebook: nb, folderPath: []))
        }

        func collect(_ folder: Folder, path: [String]) {
            included.append(folder)
            for nb in notebooks(in: folder.id) {
                sources.append(ExportSource(notebook: nb, folderPath: path))
            }
            for sub in folders(in: folder.id) {
                collect(sub, path: path + [sub.title])
            }
        }

        for id in folderIDs {
            if let root = folder(id) {
                collect(root, path: [root.title])
            }
        }

        sources.sort { a, b in
            let left = (a.folderPath + [a.notebook.title]).joined(separator: "/")
            let right = (b.folderPath + [b.notebook.title]).joined(separator: "/")
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return (sources, included)
    }
}
