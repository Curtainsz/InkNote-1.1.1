import UIKit

/// Draws the paper templates (lined, grid, dotted, ...) with Core Graphics.
/// The same code feeds the on-screen page, thumbnails and PDF export.
enum PaperRenderer {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(template: PaperTemplate, tone: PaperTone, size: CGSize, scale: CGFloat = 2) -> UIImage {
        let key = "\(template.rawValue)-\(tone.rawValue)-\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(template: template, tone: tone, in: ctx.cgContext, size: size)
        }
        cache.setObject(img, forKey: key)
        return img
    }

    static func draw(template: PaperTemplate, tone: PaperTone, in cg: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        cg.setFillColor(tone.color.cgColor)
        cg.fill(rect)
        cg.setStrokeColor(tone.lineColor.cgColor)
        cg.setLineWidth(1)

        switch template {
        case .blank:
            break

        case .lined:
            let spacing: CGFloat = 38
            var y: CGFloat = 110
            while y < size.height - 40 {
                hLine(cg, y: y, from: 0, to: size.width)
                y += spacing
            }
            cg.setStrokeColor(UIColor(red: 0.89, green: 0.35, blue: 0.35, alpha: 0.38).cgColor)
            vLine(cg, x: 96, from: 0, to: size.height)

        case .grid:
            let spacing: CGFloat = 32
            cg.setLineWidth(0.6)
            var x: CGFloat = spacing
            while x < size.width {
                vLine(cg, x: x, from: 0, to: size.height)
                x += spacing
            }
            var y: CGFloat = spacing
            while y < size.height {
                hLine(cg, y: y, from: 0, to: size.width)
                y += spacing
            }

        case .dotted:
            let spacing: CGFloat = 32
            cg.setFillColor(tone.lineColor.withAlphaComponent(0.95).cgColor)
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    cg.fillEllipse(in: CGRect(x: x - 1.7, y: y - 1.7, width: 3.4, height: 3.4))
                    x += spacing
                }
                y += spacing
            }

        case .cornell:
            let top: CGFloat = 100
            let summaryY = size.height - 190
            let cueX: CGFloat = 230
            var y: CGFloat = top + 38
            while y < summaryY {
                hLine(cg, y: y, from: 0, to: size.width)
                y += 38
            }
            cg.setLineWidth(1.6)
            hLine(cg, y: top, from: 0, to: size.width)
            hLine(cg, y: summaryY, from: 0, to: size.width)
            vLine(cg, x: cueX, from: top, to: summaryY)
            let attrs = labelAttributes(tone)
            ("CUES" as NSString).draw(at: CGPoint(x: 24, y: top + 10), withAttributes: attrs)
            ("NOTES" as NSString).draw(at: CGPoint(x: cueX + 18, y: top + 10), withAttributes: attrs)
            ("SUMMARY" as NSString).draw(at: CGPoint(x: 24, y: summaryY + 10), withAttributes: attrs)
            ("TOPIC  /  DATE" as NSString).draw(at: CGPoint(x: 24, y: 40), withAttributes: attrs)

        case .planner:
            let left: CGFloat = 60
            let right = size.width - 60
            let top: CGFloat = 110
            let rowHeight = (size.height - top - 50) / 7
            let days = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
            cg.setLineWidth(1.4)
            hLine(cg, y: 80, from: left, to: right)
            let attrs = labelAttributes(tone)
            ("WEEK OF" as NSString).draw(at: CGPoint(x: left, y: 52), withAttributes: attrs)
            cg.setLineWidth(1)
            for i in 0...7 {
                hLine(cg, y: top + CGFloat(i) * rowHeight, from: left, to: right)
            }
            vLine(cg, x: left + 90, from: top, to: top + 7 * rowHeight)
            vLine(cg, x: left, from: top, to: top + 7 * rowHeight)
            vLine(cg, x: right, from: top, to: top + 7 * rowHeight)
            for (i, d) in days.enumerated() {
                (d as NSString).draw(at: CGPoint(x: left + 14, y: top + CGFloat(i) * rowHeight + 12), withAttributes: attrs)
            }
        }
    }

    private static func labelAttributes(_ tone: PaperTone) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: tone.lineColor.adjusted(brightness: -0.25)
        ]
    }

    private static func hLine(_ cg: CGContext, y: CGFloat, from x0: CGFloat, to x1: CGFloat) {
        cg.move(to: CGPoint(x: x0, y: y))
        cg.addLine(to: CGPoint(x: x1, y: y))
        cg.strokePath()
    }

    private static func vLine(_ cg: CGContext, x: CGFloat, from y0: CGFloat, to y1: CGFloat) {
        cg.move(to: CGPoint(x: x, y: y0))
        cg.addLine(to: CGPoint(x: x, y: y1))
        cg.strokePath()
    }
}
