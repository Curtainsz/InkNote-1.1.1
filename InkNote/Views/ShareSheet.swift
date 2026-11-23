import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Small page preview used in the page list.
struct PageThumbnail: View {
    @EnvironmentObject var store: LibraryStore
    let notebookID: UUID
    let page: Page
    var width: CGFloat = 70

    @State private var image: UIImage?

    var body: some View {
        let height = width * CGFloat(page.height / page.width)
        ZStack {
            Color(UIColor.systemBackground)
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.35), lineWidth: 0.5))
        .task(id: page.id) {
            image = await store.thumbnail(notebookID: notebookID, pageID: page.id)
        }
    }
}
