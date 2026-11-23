import UIKit
import Vision
import PencilKit

/// Turns ink into text with Apple's Vision framework (runs on the device, no network).
enum HandwritingRecognizer {
    static func recognise(_ drawing: PKDrawing, pageSize: CGSize) async -> String {
        if drawing.strokes.isEmpty { return "" }
        return await Task.detached(priority: .utility) { () -> String in
            let page = CGRect(origin: .zero, size: pageSize)
            let area = drawing.bounds.insetBy(dx: -24, dy: -24).intersection(page)
            if area.isNull || area.isEmpty { return "" }

            let longest = max(area.width, area.height)
            let scale = min(2, 4000 / max(longest, 1))
            let ink = DrawingRaster.image(drawing, bounds: area, scale: scale)

            // Vision reads dark-on-light best, so flatten the ink onto white.
            let format = UIGraphicsImageRendererFormat()
            format.scale = ink.scale
            format.opaque = true
            let flat = UIGraphicsImageRenderer(size: ink.size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: ink.size))
                ink.draw(at: .zero)
            }
            guard let cgImage = flat.cgImage else { return "" }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            let observations = (request.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}
