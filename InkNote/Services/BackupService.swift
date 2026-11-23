import Foundation
import UniformTypeIdentifiers

/// Where the app keeps its files, as plain values that background work can use.
struct StorePaths {
    let drawings: URL
    let pdfs: URL
    let images: URL
    let audio: URL
    let covers: URL

    func drawing(_ pageID: UUID) -> URL {
        drawings.appendingPathComponent("\(pageID.uuidString).drawing")
    }
}

struct BackupManifest: Codable {
    var format: Int = 1
    var app: String = "InkNote"
    var created: Date = Date()
    var folders: [Folder]
    var notebooks: [Notebook]
}

/// Reads and writes `.inknote` backups: a zip with `manifest.json` plus the ink, pictures,
/// PDFs, audio and covers the notebooks use.
enum BackupService {
    static let fileExtension = "inknote"
    static let typeIdentifier = "com.inknote.backup"
    /// The file type for `.inknote` (declared in Info.plist through project.yml).
    static var contentType: UTType {
        UTType(exportedAs: typeIdentifier, conformingTo: .data)
    }
    private static let allowedFolders: Set<String> = ["drawings", "images", "pdfs", "audio", "covers"]

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func safeName(_ name: String) -> String? {
        if name.isEmpty || name.contains("/") || name == "." || name == ".." { return nil }
        return name
    }

    // MARK: Writing

    static func writeBackup(to url: URL,
                            notebooks: [Notebook],
                            folders: [Folder],
                            includeAudio: Bool,
                            paths: StorePaths,
                            progress: (Double) -> Void,
                            cancel: CancelFlag) throws {
        var books = notebooks
        if !includeAudio {
            for i in books.indices { books[i].audio = [] }
        }
        let manifest = BackupManifest(folders: folders, notebooks: books)

        var files: [(entry: String, url: URL)] = []
        var seen = Set<String>()

        func add(_ folder: String, base: URL, name: String?) {
            guard let name = name, safeName(name) != nil else { return }
            let entry = "\(folder)/\(name)"
            if seen.contains(entry) { return }
            let fileURL = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                seen.insert(entry)
                files.append((entry, fileURL))
            }
        }

        for nb in books {
            for page in nb.pages {
                let drawingURL = paths.drawing(page.id)
                let entry = "drawings/\(page.id.uuidString).drawing"
                if !seen.contains(entry), FileManager.default.fileExists(atPath: drawingURL.path) {
                    seen.insert(entry)
                    files.append((entry, drawingURL))
                }
                for item in page.images {
                    add("images", base: paths.images, name: item.fileName)
                }
            }
            add("pdfs", base: paths.pdfs, name: nb.pdfFileName)
            for clip in nb.audio {
                add("audio", base: paths.audio, name: clip.fileName)
            }
            add("covers", base: paths.covers, name: nb.cover.imageFileName)
            add("covers", base: paths.covers, name: nb.cover.originalFileName)
        }

        let zip = try ZipWriter(url: url)
        do {
            try zip.addData("manifest.json", try makeEncoder().encode(manifest))
            for (index, file) in files.enumerated() {
                if cancel.isCancelled { throw ZipError.cancelled }
                try zip.addFile(file.entry, from: file.url)
                progress(Double(index + 1) / Double(max(files.count, 1)))
            }
            try zip.finish()
        } catch {
            zip.abandon()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: Reading

    /// Unpacks a backup into a fresh temporary folder. Only the known folders are extracted,
    /// and any path that tries to leave the folder is skipped.
    static func extract(zipURL: URL) throws -> URL {
        let reader = try ZipReader(url: zipURL)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InkNote Import \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for entry in reader.entries {
                guard let relative = ZipReader.safePath(entry.name) else { continue }
                let top = relative.split(separator: "/").first.map(String.init) ?? ""
                if relative != "manifest.json" && !allowedFolders.contains(top) { continue }
                try reader.extract(entry, to: dir.appendingPathComponent(relative))
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return dir
    }

    static func readManifest(in dir: URL) throws -> BackupManifest {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? makeDecoder().decode(BackupManifest.self, from: data),
              manifest.format <= 1 else {
            throw ZipError.badArchive
        }
        return manifest
    }

    /// Gives every folder, notebook, page and object a new ID so an import never collides with
    /// what is already in the library, and copies the files the notebooks need.
    static func remap(_ manifest: BackupManifest,
                      from dir: URL,
                      paths: StorePaths,
                      topParent: UUID?) -> (folders: [Folder], notebooks: [Notebook]) {
        var folderMap: [UUID: UUID] = [:]
        for f in manifest.folders { folderMap[f.id] = UUID() }

        var folders: [Folder] = []
        for old in manifest.folders {
            var f = old
            f.id = folderMap[old.id] ?? UUID()
            if let parent = old.parentID, let mapped = folderMap[parent] {
                f.parentID = mapped
            } else {
                f.parentID = topParent
            }
            folders.append(f)
        }

        var notebooks: [Notebook] = []
        for old in manifest.notebooks {
            var nb = old
            nb.id = UUID()
            nb.modified = Date()
            if let parent = old.parentID, let mapped = folderMap[parent] {
                nb.parentID = mapped
            } else {
                nb.parentID = topParent
            }

            nb.audio = old.audio.compactMap { clip -> AudioClip? in
                guard safeName(clip.fileName) != nil else { return nil }
                var c = clip
                c.id = UUID()
                copyIfMissing(dir.appendingPathComponent("audio/\(clip.fileName)"),
                              to: paths.audio.appendingPathComponent(clip.fileName))
                return c
            }

            if let pdf = old.pdfFileName, safeName(pdf) != nil {
                copyIfMissing(dir.appendingPathComponent("pdfs/\(pdf)"), to: paths.pdfs.appendingPathComponent(pdf))
            } else {
                nb.pdfFileName = nil
            }

            if let name = old.cover.imageFileName, safeName(name) == nil {
                nb.cover.imageFileName = nil
                if nb.cover.style == .image { nb.cover.style = .gradient }
            }
            if let name = old.cover.originalFileName, safeName(name) == nil {
                nb.cover.originalFileName = nil
            }
            for name in [nb.cover.imageFileName, nb.cover.originalFileName].compactMap({ $0 }) {
                copyIfMissing(dir.appendingPathComponent("covers/\(name)"), to: paths.covers.appendingPathComponent(name))
            }

            nb.pages = old.pages.map { page -> Page in
                var p = page
                p.id = UUID()
                copyIfMissing(dir.appendingPathComponent("drawings/\(page.id.uuidString).drawing"),
                              to: paths.drawing(p.id))
                p.textBoxes = page.textBoxes.map { box -> TextBox in
                    var b = box
                    b.id = UUID()
                    return b
                }
                p.images = page.images.compactMap { item -> ImageItem? in
                    guard safeName(item.fileName) != nil else { return nil }
                    var i = item
                    i.id = UUID()
                    copyIfMissing(dir.appendingPathComponent("images/\(item.fileName)"),
                                  to: paths.images.appendingPathComponent(item.fileName))
                    return i
                }
                return p
            }
            if nb.pages.isEmpty { nb.pages = [nb.makePage()] }
            notebooks.append(nb)
        }
        return (folders, notebooks)
    }

    private static func copyIfMissing(_ source: URL, to destination: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return }
        if fm.fileExists(atPath: source.path) {
            try? fm.copyItem(at: source, to: destination)
        }
    }
}

extension LibraryStore {
    var paths: StorePaths {
        StorePaths(drawings: drawingsDir, pdfs: pdfsDir, images: imagesDir, audio: audioDir,
                   covers: CoverImageStore.directory)
    }

    /// Imports a `.inknote` backup into the library and returns the new notebook IDs.
    func importBackup(from url: URL, parent: UUID?) async throws -> [UUID] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let storePaths = paths
        let result = try await Task.detached(priority: .userInitiated) { () -> (folders: [Folder], notebooks: [Notebook]) in
            let dir = try BackupService.extract(zipURL: url)
            defer { try? FileManager.default.removeItem(at: dir) }
            let manifest = try BackupService.readManifest(in: dir)
            return BackupService.remap(manifest, from: dir, paths: storePaths, topParent: parent)
        }.value

        appendImported(folders: result.folders, notebooks: result.notebooks)
        return result.notebooks.map { $0.id }
    }
}
