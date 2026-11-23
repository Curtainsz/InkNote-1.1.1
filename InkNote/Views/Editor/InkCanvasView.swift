import SwiftUI
import PencilKit

/// A PencilKit canvas for one page. Apple Pencil pressure, tilt and palm rejection come from PencilKit.
struct InkCanvasView: UIViewRepresentable {
    let pageSize: CGSize
    let loadDrawing: () -> PKDrawing
    @ObservedObject var state: EditorState
    var onChange: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView(frame: CGRect(origin: .zero, size: pageSize))
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        canvas.contentSize = pageSize
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.drawing = loadDrawing()
        canvas.delegate = context.coordinator
        canvas.allowsFingerDrawing = !state.pencilOnly

        let coordinator = context.coordinator
        coordinator.canvas = canvas

        // Apple Pencil double-tap.
        let pencil = UIPencilInteraction()
        pencil.delegate = coordinator
        canvas.addInteraction(pencil)

        // Shape tool: a one-finger or Pencil drag draws a clean line, arrow, box or ellipse.
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleShapePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        canvas.addGestureRecognizer(pan)
        coordinator.shapePan = pan

        state.canvas = canvas
        // The undo manager can be shared with the window, so drop steps left over from the previous page.
        let editorState = state
        DispatchQueue.main.async {
            canvas.undoManager?.removeAllActions()
            editorState.refreshUndo()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        state.canvas = canvas

        let wantsPencilOnly = state.pencilOnly
        let policy: PKCanvasViewDrawingPolicy = wantsPencilOnly ? .pencilOnly : .anyInput
        if canvas.drawingPolicy != policy {
            canvas.drawingPolicy = policy
        }

        let shapeMode = state.tool == .shape
        canvas.drawingGestureRecognizer.isEnabled = !shapeMode
        if let pan = coordinator.shapePan {
            pan.isEnabled = shapeMode
            let pencilType = NSNumber(value: UITouch.TouchType.pencil.rawValue)
            let fingerType = NSNumber(value: UITouch.TouchType.direct.rawValue)
            pan.allowedTouchTypes = wantsPencilOnly ? [pencilType] : [pencilType, fingerType]
        }

        let signature = state.toolSignature
        if coordinator.lastToolSignature != signature {
            coordinator.lastToolSignature = signature
            canvas.tool = state.makePKTool()
        }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        // Save the last strokes, but not in the middle of a SwiftUI update.
        let finalDrawing = canvas.drawing
        let save = coordinator.parent.onChange
        DispatchQueue.main.async {
            save(finalDrawing)
        }
        if coordinator.parent.state.canvas === canvas {
            coordinator.parent.state.canvas = nil
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var parent: InkCanvasView
        weak var canvas: PKCanvasView?
        var shapePan: UIPanGestureRecognizer?
        var lastToolSignature = ""

        private var shapeStart: CGPoint = .zero
        private let previewLayer = CAShapeLayer()

        init(_ parent: InkCanvasView) {
            self.parent = parent
            super.init()
            previewLayer.fillColor = UIColor.clear.cgColor
            previewLayer.lineCap = .round
            previewLayer.lineJoin = .round
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.onChange(canvasView.drawing)
            parent.state.refreshUndo()
        }

        // MARK: Pencil

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            parent.state.pencilDoubleTap()
        }

        // MARK: Shapes

        @objc func handleShapePan(_ gesture: UIPanGestureRecognizer) {
            guard let canvas = canvas else { return }
            let location = gesture.location(in: canvas)

            switch gesture.state {
            case .began:
                // The recogniser fires after a few points of travel, so back up to the true start.
                let moved = gesture.translation(in: canvas)
                shapeStart = CGPoint(x: location.x - moved.x, y: location.y - moved.y)
                previewLayer.strokeColor = UIColor(parent.state.penColor).cgColor
                previewLayer.lineWidth = parent.state.penWidth
                canvas.layer.addSublayer(previewLayer)
                previewLayer.path = path(for: parent.state.shape, from: shapeStart, to: location)

            case .changed:
                previewLayer.path = path(for: parent.state.shape, from: shapeStart, to: location)

            case .ended:
                previewLayer.removeFromSuperlayer()
                commitShape(from: shapeStart, to: location, in: canvas)

            default:
                previewLayer.removeFromSuperlayer()
            }
        }

        private func polylines(for kind: ShapeKind, from a: CGPoint, to b: CGPoint) -> [[CGPoint]] {
            switch kind {
            case .line:
                return [[a, b]]
            case .arrow:
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head: CGFloat = max(18, parent.state.penWidth * 4)
                let angleLeft: CGFloat = angle - CGFloat.pi / 7
                let angleRight: CGFloat = angle + CGFloat.pi / 7
                let left = CGPoint(x: b.x - head * cos(angleLeft), y: b.y - head * sin(angleLeft))
                let right = CGPoint(x: b.x - head * cos(angleRight), y: b.y - head * sin(angleRight))
                return [[a, b], [left, b, right]]
            case .rectangle:
                let tl = CGPoint(x: min(a.x, b.x), y: min(a.y, b.y))
                let br = CGPoint(x: max(a.x, b.x), y: max(a.y, b.y))
                let tr = CGPoint(x: br.x, y: tl.y)
                let bl = CGPoint(x: tl.x, y: br.y)
                return [[tl, tr, br, bl, tl]]
            case .ellipse:
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                let steps = 96
                var points: [CGPoint] = []
                for i in 0...steps {
                    let t: CGFloat = CGFloat(i) / CGFloat(steps) * 2 * CGFloat.pi
                    let px: CGFloat = rect.midX + rect.width / 2 * cos(t)
                    let py: CGFloat = rect.midY + rect.height / 2 * sin(t)
                    points.append(CGPoint(x: px, y: py))
                }
                return [points]
            }
        }

        private func path(for kind: ShapeKind, from a: CGPoint, to b: CGPoint) -> CGPath {
            let path = CGMutablePath()
            for line in polylines(for: kind, from: a, to: b) {
                guard let first = line.first else { continue }
                path.move(to: first)
                for p in line.dropFirst() { path.addLine(to: p) }
            }
            return path
        }

        private func densify(_ line: [CGPoint], step: CGFloat = 3) -> [CGPoint] {
            guard var previous = line.first else { return [] }
            var result = [previous]
            for p in line.dropFirst() {
                let dx = p.x - previous.x
                let dy = p.y - previous.y
                let distance = hypot(dx, dy)
                let count = max(1, Int((distance / step).rounded(.up)))
                for i in 1...count {
                    let t = CGFloat(i) / CGFloat(count)
                    result.append(CGPoint(x: previous.x + dx * t, y: previous.y + dy * t))
                }
                previous = p
            }
            return result
        }

        private func commitShape(from a: CGPoint, to b: CGPoint, in canvas: PKCanvasView) {
            if hypot(b.x - a.x, b.y - a.y) < 6 { return }
            let width = parent.state.penWidth
            let ink = PKInk(.pen, color: UIColor(parent.state.penColor))
            var strokes: [PKStroke] = []
            for line in polylines(for: parent.state.shape, from: a, to: b) {
                let points = densify(line)
                if points.count < 2 { continue }
                let controlPoints = points.enumerated().map { (i, p) in
                    PKStrokePoint(location: p,
                                  timeOffset: Double(i) * 0.002,
                                  size: CGSize(width: width, height: width),
                                  opacity: 1,
                                  force: 1,
                                  azimuth: 0,
                                  altitude: .pi / 2)
                }
                let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
                strokes.append(PKStroke(ink: ink, path: path))
            }
            if strokes.isEmpty { return }
            let before = canvas.drawing
            var after = before
            after.strokes.append(contentsOf: strokes)
            apply(after, undoingTo: before)
        }

        /// Swaps the drawing and registers undo and redo, so shapes behave like normal strokes.
        private func apply(_ new: PKDrawing, undoingTo old: PKDrawing) {
            guard let canvas = canvas else { return }
            canvas.undoManager?.registerUndo(withTarget: self) { target in
                target.apply(old, undoingTo: new)
            }
            canvas.drawing = new
            parent.onChange(new)
            parent.state.refreshUndo()
        }
    }
}
