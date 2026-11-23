import SwiftUI

/// Thumbnails of every page, with reorder, duplicate and delete.
struct PagesSheet: View {
    @EnvironmentObject var store: LibraryStore
    let notebookID: UUID
    @Binding var pageIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            Group {
                if let nb = store.notebook(notebookID) {
                    List {
                        ForEach(Array(nb.pages.enumerated()), id: \.element.id) { entry in
                            row(nb, index: entry.offset, page: entry.element)
                        }
                        .onMove { source, destination in
                            keepingCurrentPage {
                                store.movePages(from: source, to: destination, in: notebookID)
                            }
                        }
                        .onDelete { offsets in
                            keepingCurrentPage {
                                store.deletePages(at: offsets, in: notebookID)
                            }
                        }
                    }
                    .environment(\.editMode, $editMode)
                } else {
                    Text("This notebook is no longer available.")
                }
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        let newIndex = store.addPage(to: notebookID, after: pageIndex)
                        pageIndex = newIndex
                    } label: {
                        Image(systemName: "plus")
                    }
                    Button("Close") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func row(_ nb: Notebook, index: Int, page: Page) -> some View {
        Button {
            pageIndex = index
            dismiss()
        } label: {
            HStack(spacing: 14) {
                PageThumbnail(notebookID: notebookID, page: page, width: 62)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Page \(index + 1)").font(.headline)
                    Text(subtitle(page)).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if index == pageIndex {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let newIndex = store.duplicatePage(page.id, in: notebookID) {
                    pageIndex = newIndex
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if nb.pages.count > 1 {
                Button(role: .destructive) {
                    keepingCurrentPage {
                        store.deletePages(at: IndexSet(integer: index), in: notebookID)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func subtitle(_ page: Page) -> String {
        var parts: [String] = []
        if let pdf = page.pdfPageIndex {
            parts.append("PDF page \(pdf + 1)")
        } else {
            parts.append(page.template.title)
        }
        if !page.textBoxes.isEmpty { parts.append("\(page.textBoxes.count) text") }
        if !page.images.isEmpty { parts.append("\(page.images.count) picture\(page.images.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// After moving or deleting, keep the editor on the page the person was looking at.
    private func keepingCurrentPage(_ change: () -> Void) {
        let before = store.notebook(notebookID)
        let currentID: UUID? = {
            guard let pages = before?.pages, pages.indices.contains(pageIndex) else { return nil }
            return pages[pageIndex].id
        }()
        change()
        guard let after = store.notebook(notebookID) else { return }
        if let id = currentID, let newIndex = after.pages.firstIndex(where: { $0.id == id }) {
            pageIndex = newIndex
        } else {
            pageIndex = min(pageIndex, max(after.pages.count - 1, 0))
        }
    }
}
