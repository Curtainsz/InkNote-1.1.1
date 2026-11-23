import SwiftUI
import UIKit

// MARK: - Paper

enum PaperTemplate: String, Codable, CaseIterable, Identifiable {
    case blank, lined, grid, dotted, cornell, planner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank"
        case .lined: return "Lined"
        case .grid: return "Grid"
        case .dotted: return "Dotted"
        case .cornell: return "Cornell"
        case .planner: return "Planner"
        }
    }

    var detail: String {
        switch self {
        case .blank: return "Sketching"
        case .lined: return "Writing"
        case .grid: return "Maths"
        case .dotted: return "Mind maps"
        case .cornell: return "Lectures"
        case .planner: return "Weekly plans"
        }
    }
}

enum PaperTone: String, Codable, CaseIterable, Identifiable {
    case white, cream, mint, sky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "White"
        case .cream: return "Cream"
        case .mint: return "Mint"
        case .sky: return "Sky"
        }
    }

    var color: UIColor {
        switch self {
        case .white: return UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
        case .cream: return UIColor(red: 0.99, green: 0.97, blue: 0.89, alpha: 1)
        case .mint: return UIColor(red: 0.93, green: 0.98, blue: 0.94, alpha: 1)
        case .sky: return UIColor(red: 0.93, green: 0.96, blue: 1.0, alpha: 1)
        }
    }

    var lineColor: UIColor {
        switch self {
        case .white: return UIColor(red: 0.78, green: 0.83, blue: 0.92, alpha: 1)
        case .cream: return UIColor(red: 0.82, green: 0.76, blue: 0.60, alpha: 1)
        case .mint: return UIColor(red: 0.62, green: 0.80, blue: 0.68, alpha: 1)
        case .sky: return UIColor(red: 0.64, green: 0.76, blue: 0.92, alpha: 1)
        }
    }
}

enum PageMetrics {
    static let portrait = CGSize(width: 820, height: 1160)
    static let landscape = CGSize(width: 1160, height: 820)
    static func size(landscape isLandscape: Bool) -> CGSize { isLandscape ? landscape : portrait }
}

// MARK: - Covers

enum CoverStyle: String, Codable, CaseIterable, Identifiable {
    case solid, gradient, stripes, label, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        case .stripes: return "Stripes"
        case .label: return "Label"
        case .image: return "Photo"
        }
    }

    /// The styles drawn from a colour, as opposed to a picture.
    static var presets: [CoverStyle] { [.solid, .gradient, .stripes, .label] }
}

struct Cover: Codable, Hashable {
    var colorHex: String = "#3B6FD4"
    var symbol: String = "pencil.and.scribble"
    var style: CoverStyle = .gradient
    /// Cropped 3:4 picture shown when `style == .image` (file in Documents/InkNote/covers).
    var imageFileName: String? = nil
    /// Larger original kept so the picture can be cropped again later.
    var originalFileName: String? = nil
    var showTitle: Bool = true
}

extension Cover {
    enum CodingKeys: String, CodingKey {
        case colorHex, symbol, style, imageFileName, originalFileName, showTitle
    }

    /// Reads libraries saved before photo covers existed, where the new keys are missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#3B6FD4"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "pencil.and.scribble"
        style = try c.decodeIfPresent(CoverStyle.self, forKey: .style) ?? .gradient
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName)
        showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? true
    }
}

enum CoverOptions {
    static let palette: [String] = [
        "#3B6FD4", "#E4572E", "#F2A541", "#3DA35D", "#8E5BD0",
        "#E0568A", "#2B2D42", "#16A3A3", "#8D6E63", "#607D8B"
    ]
    static let symbols: [String] = [
        "pencil.and.scribble", "book.closed.fill", "graduationcap.fill", "function",
        "atom", "testtube.2", "leaf.fill", "globe.asia.australia.fill",
        "music.note", "paintpalette.fill", "briefcase.fill", "chart.bar.fill",
        "laptopcomputer", "heart.fill", "star.fill", "lightbulb.fill",
        "camera.fill", "brain.head.profile", "doc.richtext", "calendar"
    ]
}

// MARK: - Page content

struct TextBox: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String = ""
    var x: Double
    var y: Double
    var width: Double = 280
    var height: Double = 90
    var fontSize: Double = 22
    var bold: Bool = false
    var colorHex: String = "#1B1B1F"
}

struct ImageItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var fileName: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct AudioClip: Identifiable, Codable, Hashable {
    var id = UUID()
    var fileName: String
    var title: String
    var date: Date = Date()
    var duration: Double = 0
}

struct Page: Identifiable, Codable, Hashable {
    var id = UUID()
    var template: PaperTemplate = .lined
    var tone: PaperTone = .white
    var width: Double = 820
    var height: Double = 1160
    var pdfPageIndex: Int? = nil
    var textBoxes: [TextBox] = []
    var images: [ImageItem] = []
    /// Text produced by handwriting recognition (used for search).
    var recognisedText: String = ""
    /// Text extracted from the imported PDF page (used for search).
    var sourceText: String = ""

    var size: CGSize { CGSize(width: width, height: height) }
}

// MARK: - Library

struct Folder: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var colorHex: String = "#3B6FD4"
    var parentID: UUID? = nil
    var created: Date = Date()
}

struct Notebook: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var cover: Cover = Cover()
    var parentID: UUID? = nil
    var template: PaperTemplate = .lined
    var tone: PaperTone = .white
    var landscape: Bool = false
    var pages: [Page] = []
    var pdfFileName: String? = nil
    var audio: [AudioClip] = []
    var created: Date = Date()
    var modified: Date = Date()

    func makePage() -> Page {
        let s = PageMetrics.size(landscape: landscape)
        return Page(template: template, tone: tone, width: Double(s.width), height: Double(s.height))
    }
}

struct LibraryData: Codable {
    var folders: [Folder] = []
    var notebooks: [Notebook] = []
}

/// Values edited in the "new notebook" and "edit details" sheet.
struct NotebookDraft {
    var title: String = "Untitled notebook"
    var cover: Cover = Cover()
    var template: PaperTemplate = .lined
    var tone: PaperTone = .white
    var landscape: Bool = false
}

struct SearchHit: Identifiable {
    let id = UUID()
    let notebookID: UUID
    let notebookTitle: String
    let pageIndex: Int
    let snippet: String
}

enum Route: Hashable {
    case folder(UUID)
    case notebook(UUID, Int)
}
