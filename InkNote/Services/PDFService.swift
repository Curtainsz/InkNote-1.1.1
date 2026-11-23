import PDFKit
import UIKit

/// Thread-safe access to imported PDFs. PDFKit documents are only touched on one serial queue.
final class PDFService {
    static let shared = PDFService()

    private let queue = DispatchQueue(label: "com.inknote.pdf")
    private var documents: [String: PDFDocument] = [:]
    private let cache = NSCache<NSString, UIImage>()

    /// Must be called on `queue`.
    private func document(for url: URL) -> PDFDocument? {
        if let doc = documents[url.path] { return doc }
        guard let doc = PDFDocument(url: url) else { return nil }
        documents[url.path] = doc
        return doc
    }

    func renderSync(url: URL, index: Int, size: CGSize, scale: CGFloat) -> UIImage? {
        let key = "\(url.lastPathComponent)#\(index)#\(Int(size.width * scale))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: UIImage? = queue.sync {
            guard let doc = document(for: url), let page = doc.page(at: index) else { return nil }
            let target = CGSize(width: size.width * scale, height: size.height * scale)
            return page.thumbnail(of: target, for: .mediaBox)
        }
        if let image = image { cache.setObject(image, forKey: key) }
        return image
    }

    func render(url: URL, index: Int, size: CGSize, scale: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.renderSync(url: url, index: index, size: size, scale: scale))
            }
        }
    }

    /// Page sizes, adjusted for page rotation.
    func pageSizes(url: URL) -> [CGSize] {
        queue.sync {
            guard let doc = document(for: url) else { return [] }
            return (0..<doc.pageCount).map { i in
                guard let page = doc.page(at: i) else { return CGSize(width: 595, height: 842) }
                let r = page.bounds(for: .mediaBox)
                return page.rotation % 180 == 0 ? r.size : CGSize(width: r.height, height: r.width)
            }
        }
    }

    /// Plain text of every page, for search.
    func pageTexts(url: URL) -> [String] {
        queue.sync {
            guard let doc = document(for: url) else { return [] }
            return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        }
    }
}
