import SwiftUI

@main
struct InkNoteApp: App {
    @StateObject private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                store.flushAll()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var path: [Route] = []
    @State private var importError: String?

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(folderID: nil)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .folder(let id):
                        LibraryView(folderID: id)
                    case .notebook(let id, let page):
                        EditorView(notebookID: id, startPage: page)
                    }
                }
        }
        // "Open in InkNote" from Files, Mail or Safari.
        .onOpenURL { url in
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                do {
                    let id = try store.importPDF(from: url, parent: nil)
                    path = [.notebook(id, 0)]
                } catch {
                    importError = error.localizedDescription
                }
            } else if ext == BackupService.fileExtension {
                Task {
                    do {
                        let ids = try await store.importBackup(from: url, parent: nil)
                        if ids.count == 1, let id = ids.first {
                            path = [.notebook(id, 0)]
                        } else {
                            path = []
                        }
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
        }
        .alert("Could not open file", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }
}
