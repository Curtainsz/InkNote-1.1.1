import SwiftUI
import UniformTypeIdentifiers

enum LibrarySheet: Identifiable {
    case newNotebook
    case newFolder
    case editNotebook(UUID)
    case renameFolder(UUID)

    var id: String {
        switch self {
        case .newNotebook: return "newNotebook"
        case .newFolder: return "newFolder"
        case .editNotebook(let id): return "edit-\(id.uuidString)"
        case .renameFolder(let id): return "rename-\(id.uuidString)"
        }
    }
}

enum DeleteTarget {
    case folder(UUID)
    case notebook(UUID)
    case selection
}

/// What to hand to the export sheet.
struct ExportRequest: Identifiable {
    let id = UUID()
    var notebooks: Set<UUID> = []
    var folders: Set<UUID> = []
}

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    let folderID: UUID?

    @State private var query = ""
    @State private var sheet: LibrarySheet?
    @State private var showImporter = false
    @State private var message: String?
    @State private var shareItem: ShareItem?
    @State private var deleteTarget: DeleteTarget?
    @State private var busyText: String?
    @State private var selecting = false
    @State private var selectedNotebooks = Set<UUID>()
    @State private var selectedFolders = Set<UUID>()
    @State private var exportRequest: ExportRequest?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 28, alignment: .top)]

    private var screenTitle: String {
        if let id = folderID, let f = store.folder(id) { return f.title }
        return "InkNote"
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                SearchResultsView(query: query)
            } else {
                content
            }
        }
        .navigationTitle(selecting ? selectionTitle : screenTitle)
        .searchable(text: $query, prompt: "Search notes, handwriting and PDFs")
        .toolbar {
            if selecting {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(allSelected ? "Deselect all" : "Select all") { toggleSelectAll() }
                    Button("Done") { endSelection() }
                        .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { startExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .disabled(selectionCount == 0)
                    Spacer()
                    selectionMoveMenu
                        .disabled(selectionCount == 0)
                    Spacer()
                    Button(role: .destructive) { deleteTarget = .selection } label: { Label("Delete", systemImage: "trash") }
                        .disabled(selectionCount == 0)
                }
            } else {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Select") { selecting = true }
                        .disabled(!hasItems)
                    Menu {
                        Button { sheet = .newNotebook } label: { Label("New notebook", systemImage: "book.closed") }
                        Button { sheet = .newFolder } label: { Label("New folder", systemImage: "folder.badge.plus") }
                        Button { showImporter = true } label: { Label("Import PDFs or backups…", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
        }
        .sheet(item: $sheet) { item in
            sheetContent(item)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls)
        }
        .sheet(item: $exportRequest) { request in
            BulkExportSheet(notebookIDs: request.notebooks, folderIDs: request.folders)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType.pdf, BackupService.contentType],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importFiles(urls)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
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
            if let text = busyText {
                ProgressView(text)
                    .padding(20)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let folders = store.folders(in: folderID)
        let notebooks = store.notebooks(in: folderID)
        if folders.isEmpty && notebooks.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 54))
                    .foregroundColor(.secondary)
                Text("Nothing here yet")
                    .font(.title3.weight(.semibold))
                Text("Create a notebook or import a PDF to start writing.")
                    .foregroundColor(.secondary)
                Button("New notebook") { sheet = .newNotebook }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 30) {
                    ForEach(folders) { folder in
                        folderCell(folder)
                    }
                    ForEach(notebooks) { nb in
                        notebookCell(nb)
                    }
                }
                .padding(24)
            }
        }
    }

    /// A grid cell: opens its item normally, or ticks it while selecting.
    @ViewBuilder
    private func cell<Content: View>(route: Route,
                                     selected: Bool,
                                     toggle: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        if selecting {
            Button(action: toggle) {
                content()
                    .opacity(selected ? 1 : 0.8)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(selected ? .accentColor : .secondary)
                            .background(Circle().fill(Color(.systemBackground)).padding(2))
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: route) {
                content()
            }
            .buttonStyle(.plain)
        }
    }

    private func folderCell(_ folder: Folder) -> some View {
        cell(route: .folder(folder.id),
             selected: selectedFolders.contains(folder.id),
             toggle: { toggle(&selectedFolders, folder.id) }) {
            VStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 92))
                    .foregroundColor(Color(hex: folder.colorHex))
                    .frame(height: 200)
                Text(folder.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(folderSummary(folder.id))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contextMenu {
            if !selecting {
            Button { sheet = .renameFolder(folder.id) } label: { Label("Rename", systemImage: "pencil") }
            Button { exportRequest = ExportRequest(folders: [folder.id]) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            Menu {
                ForEach(CoverOptions.palette, id: \.self) { hex in
                    Button { store.recolourFolder(folder.id, hex: hex) } label: { Text(hex) }
                }
            } label: {
                Label("Colour", systemImage: "paintpalette")
            }
            moveMenu(excluding: store.descendantFolderIDs(of: folder.id).union([folder.id])) { target in
                store.moveFolder(folder.id, to: target)
            }
            Button(role: .destructive) { deleteTarget = .folder(folder.id) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func notebookCell(_ nb: Notebook) -> some View {
        cell(route: .notebook(nb.id, 0),
             selected: selectedNotebooks.contains(nb.id),
             toggle: { toggle(&selectedNotebooks, nb.id) }) {
            VStack(spacing: 8) {
                CoverView(title: nb.title, cover: nb.cover)
                Text(nb.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("\(nb.pages.count) page\(nb.pages.count == 1 ? "" : "s") · \(nb.modified.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contextMenu {
            if !selecting {
            Button { sheet = .editNotebook(nb.id) } label: { Label("Cover & details", systemImage: "paintbrush") }
            Button { store.duplicateNotebook(nb.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { exportPDF(nb.id) } label: { Label("Export as PDF", systemImage: "square.and.arrow.up") }
            Button { exportRequest = ExportRequest(notebooks: [nb.id]) } label: { Label("Export…", systemImage: "square.and.arrow.up.on.square") }
            moveMenu(excluding: []) { target in
                store.moveNotebook(nb.id, to: target)
            }
            Button(role: .destructive) { deleteTarget = .notebook(nb.id) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func folderSummary(_ id: UUID) -> String {
        let books = store.notebooks(in: id).count
        let subs = store.folders(in: id).count
        var parts: [String] = []
        if subs > 0 { parts.append("\(subs) folder\(subs == 1 ? "" : "s")") }
        parts.append("\(books) notebook\(books == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    // MARK: Menus and sheets

    private func folderPath(_ id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        var guardCount = 0
        while let cid = current, let f = store.folder(cid), guardCount < 20 {
            names.insert(f.title, at: 0)
            current = f.parentID
            guardCount += 1
        }
        return names.joined(separator: " / ")
    }

    private func moveMenu(excluding hidden: Set<UUID>, action: @escaping (UUID?) -> Void) -> some View {
        Menu {
            Button { action(nil) } label: { Label("InkNote home", systemImage: "house") }
            ForEach(store.data.folders.filter { !hidden.contains($0.id) }) { f in
                Button { action(f.id) } label: { Label(folderPath(f.id), systemImage: "folder") }
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: LibrarySheet) -> some View {
        switch item {
        case .newNotebook:
            NotebookSetupSheet(mode: .create, draft: NotebookDraft()) { draft in
                store.createNotebook(draft, parent: folderID)
            }
        case .newFolder:
            NameSheet(title: "New folder", actionTitle: "Create", initial: "") { name in
                store.createFolder(title: name, parent: folderID)
            }
        case .editNotebook(let id):
            if let nb = store.notebook(id) {
                NotebookSetupSheet(
                    mode: .edit,
                    draft: NotebookDraft(title: nb.title, cover: nb.cover, template: nb.template,
                                         tone: nb.tone, landscape: nb.landscape)
                ) { draft in
                    store.applyDetails(draft, to: id)
                }
            }
        case .renameFolder(let id):
            NameSheet(title: "Rename folder", actionTitle: "Save", initial: store.folder(id)?.title ?? "") { name in
                store.renameFolder(id, to: name)
            }
        }
    }

    private var deleteTitle: String {
        switch deleteTarget {
        case .folder(let id):
            return "Delete \"\(store.folder(id)?.title ?? "folder")\" and everything inside it?"
        case .notebook(let id):
            return "Delete \"\(store.notebook(id)?.title ?? "notebook")\"?"
        case .selection:
            return "Delete \(selectionCount) selected item\(selectionCount == 1 ? "" : "s")?"
        case .none:
            return ""
        }
    }

    private func performDelete() {
        switch deleteTarget {
        case .folder(let id): store.deleteFolder(id)
        case .notebook(let id): store.deleteNotebook(id)
        case .selection:
            for id in selectedFolders { store.deleteFolder(id) }
            for id in selectedNotebooks { store.deleteNotebook(id) }
            endSelection()
        case .none: break
        }
        deleteTarget = nil
    }

    private func exportPDF(_ id: UUID) {
        busyText = "Preparing PDF…"
        Task {
            do {
                let url = try await store.exportPDF(notebookID: id)
                shareItem = ShareItem(urls: [url])
            } catch {
                message = error.localizedDescription
            }
            busyText = nil
        }
    }

    // MARK: Selection

    private var selectionCount: Int { selectedNotebooks.count + selectedFolders.count }

    private var selectionTitle: String {
        selectionCount == 0 ? "Select items" : "\(selectionCount) selected"
    }

    private var hasItems: Bool {
        !store.folders(in: folderID).isEmpty || !store.notebooks(in: folderID).isEmpty
    }

    private var allSelected: Bool {
        let folders = store.folders(in: folderID)
        let notebooks = store.notebooks(in: folderID)
        let total = folders.count + notebooks.count
        return total > 0 && selectionCount >= total
            && folders.allSatisfy { selectedFolders.contains($0.id) }
            && notebooks.allSatisfy { selectedNotebooks.contains($0.id) }
    }

    private func toggle(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedFolders = []
            selectedNotebooks = []
        } else {
            selectedFolders = Set(store.folders(in: folderID).map { $0.id })
            selectedNotebooks = Set(store.notebooks(in: folderID).map { $0.id })
        }
    }

    private func endSelection() {
        selecting = false
        selectedFolders = []
        selectedNotebooks = []
    }

    private func startExport() {
        exportRequest = ExportRequest(notebooks: selectedNotebooks, folders: selectedFolders)
    }

    private var selectionMoveMenu: some View {
        var hidden = Set<UUID>()
        for id in selectedFolders {
            hidden.insert(id)
            hidden.formUnion(store.descendantFolderIDs(of: id))
        }
        return moveMenu(excluding: hidden) { target in
            for id in selectedFolders { store.moveFolder(id, to: target) }
            for id in selectedNotebooks { store.moveNotebook(id, to: target) }
            endSelection()
        }
    }

    // MARK: Import

    /// Imports every chosen PDF or `.inknote` backup, and reports the ones that failed.
    private func importFiles(_ urls: [URL]) {
        if urls.isEmpty { return }
        busyText = urls.count == 1 ? "Importing…" : "Importing \(urls.count) files…"
        let parent = folderID
        Task {
            var failures: [String] = []
            var imported = 0
            for url in urls {
                do {
                    if url.pathExtension.lowercased() == BackupService.fileExtension {
                        let ids = try await store.importBackup(from: url, parent: parent)
                        imported += ids.count
                    } else {
                        _ = try store.importPDF(from: url, parent: parent)
                        imported += 1
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            busyText = nil
            if !failures.isEmpty {
                let head = imported > 0 ? "Imported \(imported) notebook\(imported == 1 ? "" : "s"), but some files failed:\n" : ""
                message = head + failures.joined(separator: "\n")
            }
        }
    }
}

struct SearchResultsView: View {
    @EnvironmentObject var store: LibraryStore
    let query: String

    var body: some View {
        let hits = store.search(query)
        if hits.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No matches for \"\(query)\"")
                    .font(.headline)
                Text("Handwriting is indexed a couple of seconds after you stop writing.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(hits) { hit in
                NavigationLink(value: Route.notebook(hit.notebookID, hit.pageIndex)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.notebookTitle).font(.headline)
                        Text("Page \(hit.pageIndex + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                        Text(hit.snippet)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
