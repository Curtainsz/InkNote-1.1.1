import SwiftUI
import PencilKit

enum EditorTool: String, CaseIterable, Identifiable {
    case pen, marker, pencil, eraser, lasso, shape, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .marker: return "Highlighter"
        case .pencil: return "Pencil"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso"
        case .shape: return "Shapes"
        case .text: return "Text & pictures"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .shape: return "square.on.circle"
        case .text: return "textformat"
        }
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, rectangle, ellipse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        }
    }

    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
}

/// Shared tool settings for the page being edited.
final class EditorState: ObservableObject {
    @Published var tool: EditorTool = .pen
    @Published var shape: ShapeKind = .line

    @Published var penColor: Color = Color(hex: "#1B1B1F")
    @Published var markerColor: Color = Color(hex: "#F5D90A")
    @Published var pencilColor: Color = Color(hex: "#3A3A3C")

    @Published var penWidth: CGFloat = 4
    @Published var markerWidth: CGFloat = 20
    @Published var pencilWidth: CGFloat = 4

    @Published var eraserIsVector: Bool = true
    @Published var zoom: CGFloat = 1

    @Published var selectedBoxID: UUID?
    @Published var selectedImageID: UUID?

    @Published var canUndo = false
    @Published var canRedo = false

    @Published var pencilOnly: Bool {
        didSet { UserDefaults.standard.set(pencilOnly, forKey: "inknote.pencilOnly") }
    }

    /// The live canvas, so toolbar buttons can undo and redo.
    weak var canvas: PKCanvasView?
    private var toolBeforeEraser: EditorTool = .pen

    init() {
        if let saved = UserDefaults.standard.object(forKey: "inknote.pencilOnly") as? Bool {
            pencilOnly = saved
        } else {
            // iPads are usually used with a Pencil. On iPhone there is none, so fingers draw.
            pencilOnly = UIDevice.current.userInterfaceIdiom == .pad
        }
    }

    static let palette: [String] = [
        "#1B1B1F", "#1E3A8A", "#2563EB", "#DC2626", "#EA580C",
        "#F5D90A", "#16A34A", "#7C3AED", "#DB2777", "#6B7280"
    ]

    // MARK: Active tool settings

    var activeColor: Color {
        switch tool {
        case .marker: return markerColor
        case .pencil: return pencilColor
        default: return penColor
        }
    }

    func setActiveColor(_ color: Color) {
        switch tool {
        case .marker: markerColor = color
        case .pencil: pencilColor = color
        default: penColor = color
        }
    }

    var activeWidth: CGFloat {
        switch tool {
        case .marker: return markerWidth
        case .pencil: return pencilWidth
        default: return penWidth
        }
    }

    func setActiveWidth(_ width: CGFloat) {
        switch tool {
        case .marker: markerWidth = width
        case .pencil: pencilWidth = width
        default: penWidth = width
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        tool == .marker ? 8...44 : 1...24
    }

    var usesColour: Bool {
        switch tool {
        case .pen, .marker, .pencil, .shape, .text: return true
        case .eraser, .lasso: return false
        }
    }

    var usesWidth: Bool {
        switch tool {
        case .pen, .marker, .pencil, .shape: return true
        default: return false
        }
    }

    /// The PencilKit tool that matches the current selection.
    func makePKTool() -> PKTool {
        switch tool {
        case .pen, .shape:
            return PKInkingTool(.pen, color: UIColor(penColor), width: penWidth)
        case .marker:
            return PKInkingTool(.marker, color: UIColor(markerColor), width: markerWidth)
        case .pencil:
            return PKInkingTool(.pencil, color: UIColor(pencilColor), width: pencilWidth)
        case .eraser:
            return PKEraserTool(eraserIsVector ? .vector : .bitmap)
        case .lasso, .text:
            return PKLassoTool()
        }
    }

    /// A string that changes only when the PencilKit tool needs to change.
    var toolSignature: String {
        "\(tool.rawValue)|\(penColor.hexString)|\(markerColor.hexString)|\(pencilColor.hexString)|\(penWidth)|\(markerWidth)|\(pencilWidth)|\(eraserIsVector)"
    }

    // MARK: Undo and redo

    func undo() {
        canvas?.undoManager?.undo()
        refreshUndo()
    }

    func redo() {
        canvas?.undoManager?.redo()
        refreshUndo()
    }

    func refreshUndo() {
        // Read after the hop, so PencilKit has registered its own undo step first.
        DispatchQueue.main.async {
            let u = self.canvas?.undoManager?.canUndo ?? false
            let r = self.canvas?.undoManager?.canRedo ?? false
            if self.canUndo != u { self.canUndo = u }
            if self.canRedo != r { self.canRedo = r }
        }
    }

    /// Double-tap on Apple Pencil flips between the current tool and the eraser.
    func pencilDoubleTap() {
        if tool == .eraser {
            tool = toolBeforeEraser
        } else {
            toolBeforeEraser = tool
            tool = .eraser
        }
    }

    func select(_ newTool: EditorTool) {
        tool = newTool
        if newTool != .text {
            selectedBoxID = nil
            selectedImageID = nil
        }
    }
}
