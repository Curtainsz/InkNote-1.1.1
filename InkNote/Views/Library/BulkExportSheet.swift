import SwiftUI

/// Runs the export on a background thread and reports progress to the sheet.
@MainActor
final class BulkExportModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var isRunning = false
    @Published var resultURL: URL?
    @Published var errorMessage: String?

    private var cancelFlag = CancelFlag()

    func start(sources: [ExportSource], folders: [Folder], options: ExportOptions, paths: StorePaths) {
        if isRunning { return }
        isRunning = true
        progress = 0
        status = "Starting…"
        resultURL = nil
        errorMessage = nil

        let flag = CancelFlag()
        cancelFlag = flag

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try BulkExporter.run(
                    sources: sources,
                    folders: folders,
                    options: options,
                    paths: paths,
                    progress: { value, text in
                        Task { @MainActor in
                            guard let model = self, model.isRunning else { return }
                            model.progress = value
                            model.status = text
                        }
                    },
                    cancel: flag
                )
                await self?.finish(url)
            } catch {
                await self?.fail(error)
            }
        }
    }

    /// Removes the temporary folder that holds the finished export.
    func discardResult() {
        if let url = resultURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        resultURL = nil
        status = ""
    }

    func cancel() {
        cancelFlag.cancel()
        status = "Cancelling…"
    }

    private func finish(_ url: URL) {
        isRunning = false
        progress = 1
        status = "Ready"
        resultURL = url
    }

    private func fail(_ error: Error) {
        isRunning = false
        if case ZipError.cancelled = error {
            status = "Cancelled"
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

/// Presents the Files "save to" picker for an exported file.
struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

struct BulkExportSheet: View {
    @EnvironmentObject var store: LibraryStore
    let notebookIDs: Set<UUID>
    let folderIDs: Set<UUID>

    @StateObject private var model = BulkExportModel()
    @State private var options = ExportOptions()
    @State private var sources: [ExportSource] = []
    @State private var folders: [Folder] = []
    @State private var gathered = false
    @State private var shareItem: ShareItem?
    @State private var saveItem: ShareItem?
    @Environment(\.dismiss) private var dismiss

    private var pageCount: Int {
        sources.reduce(0) { $0 + $1.notebook.pages.count }
    }

    private var isMerged: Bool { options.format == .pdfMerged }
    private var isBackup: Bool { options.format == .backup }

    var body: some View {
        NavigationStack {
            Form {
                Section("Selection") {
                    if gathered {
                        Label("\(sources.count) notebook\(sources.count == 1 ? "" : "s") · \(pageCount) page\(pageCount == 1 ? "" : "s")",
                              systemImage: "books.vertical")
                    } else {
                        ProgressView()
                    }
                }

                Section("Format") {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            options.format = format
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: format.symbol)
                                    .frame(width: 28)
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.title).foregroundColor(.primary)
                                    Text(format.detail).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if options.format == format {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRunning)
                    }
                }

                Section("Options") {
                    Toggle("Keep folder structure", isOn: $options.keepFolders)
                        .disabled(isMerged || isBackup || model.isRunning)
                    Toggle("Include audio recordings", isOn: $options.includeAudio)
                        .disabled(isMerged || model.isRunning)
                    if isMerged {
                        Text("A merged PDF has no folders and cannot hold audio.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else if isBackup {
                        Text("Backups always keep your folders. Recordings can make them much larger.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    actionArea
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                        .disabled(model.isRunning)
                }
            }
        }
        .interactiveDismissDisabled(model.isRunning)
        .onDisappear {
            // Not while the share or Save to Files sheet is on top of this one.
            if shareItem == nil && saveItem == nil { model.discardResult() }
        }
        .onAppear {
            if !gathered {
                let selection = store.exportSelection(notebookIDs: notebookIDs, folderIDs: folderIDs)
                sources = selection.sources
                folders = selection.folders
                gathered = true
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.urls)
        }
        .sheet(item: $saveItem) { item in
            if let url = item.urls.first {
                DocumentExportPicker(url: url)
            }
        }
        .alert("Export failed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.status).font(.footnote).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int((model.progress * 100).rounded()))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Button("Cancel export", role: .destructive) {
                    model.cancel()
                }
            }
            .padding(.vertical, 4)
        } else if let url = model.resultURL {
            VStack(alignment: .leading, spacing: 4) {
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(fileSize(url))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Button {
                shareItem = ShareItem(urls: [url])
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button {
                saveItem = ShareItem(urls: [url])
            } label: {
                Label("Save to Files…", systemImage: "folder.badge.plus")
            }
            Button("Export again with other settings") {
                model.discardResult()
            }
        } else {
            Button {
                model.start(sources: sources, folders: folders, options: options, paths: store.paths)
            } label: {
                Text("Export")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .disabled(!gathered || sources.isEmpty)
            if model.status == "Cancelled" {
                Text("The last export was cancelled.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func fileSize(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
