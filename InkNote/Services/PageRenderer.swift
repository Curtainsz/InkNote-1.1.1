import UIKit
import PencilKit

/// Everything needed to draw one page away from the main thread.
struct PageRenderInput {
    var page: Page
    var pdfURL: URL?
    var drawing: PKDrawing
    var imagesDir: URL
}

enum DrawingRaster {
    /// Renders ink with light-mode colours, so black ink never turns white in Dark Mode.
    static func image(_ drawing: PKDrawing, bounds: CGRect, scale: CGFloat) -> UIImage {
        var result = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            result = drawing.image(from: bounds, scale: scale)
        }
        return result
    }
}

enum PageRenderer {
    /// Draws paper (or PDF page), pictures, text boxes and ink into the current context.
    static func draw(_ input: PageRenderInput, in cg: CGContext, rasterScale: CGFloat) {
        let page = input.page
        let size = page.size
        let rect = CGRect(origin: .zero, size: size)

        var drewPDF = false
        if let url = input.pdfURL, let index = page.pdfPageIndex,
           let img = PDFService.shared.renderSync(url: url, index: index, size: size, scale: rasterScale) {
            img.draw(in: rect)
            drewPDF = true
        }
        if !drewPDF {
            PaperRenderer.draw(template: page.template, tone: page.tone, in: cg, size: size)
        }

        for item in page.images {
            let path = input.imagesDir.appendingPathComponent(item.fileName).path
            UIImage(contentsOfFile: path)?.draw(in: CGRect(x: item.x, y: item.y, width: item.width, height: item.height))
        }

        for box in page.textBoxes where !box.text.isEmpty {
            let font = UIFont.systemFont(ofSize: CGFloat(box.fontSize), weight: box.bold ? .bold : .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(hex: box.colorHex)
            ]
            let area = CGRect(x: box.x + 5, y: box.y + 8, width: box.width - 10, height: box.height - 8)
            (box.text as NSString).draw(with: area, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        }

        if !input.drawing.strokes.isEmpty {
            DrawingRaster.image(input.drawing, bounds: rect, scale: rasterScale).draw(in: rect)
        }
    }

    /// A bitmap of the page at the given pixel width.
    static func image(_ input: PageRenderInput, width: CGFloat) -> UIImage {
        let factor = width / CGFloat(input.page.width)
        let size = CGSize(width: width, height: CGFloat(input.page.height) * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.scaleBy(x: factor, y: factor)
            draw(input, in: ctx.cgContext, rasterScale: max(1, factor * 2))
        }
    }
}

enum ExportError: LocalizedError {
    case empty
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .empty: return "There is nothing to export."
        case .encodingFailed: return "The image could not be created."
        }
    }
}

enum Exporter {
    static func pdf(title: String, inputs: [PageRenderInput]) throws -> URL {
        guard let first = inputs.first else { throw ExportError.empty }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(title) + ".pdf")
        try? FileManager.default.removeItem(at: url)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.page.size))
        try renderer.writePDF(to: url) { ctx in
            for input in inputs {
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: input.page.size), pageInfo: [:])
                PageRenderer.draw(input, in: ctx.cgContext, rasterScale: 2)
            }
        }
        return url
    }

    static func png(title: String, input: PageRenderInput) throws -> URL {
        let img = PageRenderer.image(input, width: CGFloat(input.page.width) * 2)
        guard let data = img.pngData() else { throw ExportError.encodingFailed }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(title) + ".png")
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
        return url
    }

    static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "InkNote" : cleaned
    }
}
