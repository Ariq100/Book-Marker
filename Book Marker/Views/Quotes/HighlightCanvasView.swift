import SwiftUI
import UIKit

/// One highlighter stroke. Points and width are stored relative to the image (0...1 of its width
/// and height) so the same stroke renders correctly on screen at any zoom and at full resolution
/// when the highlighted photo is sent for extraction.
struct HighlightStroke: Equatable {
    var points: [CGPoint]
    /// Stroke width as a fraction of the image's width.
    var width: CGFloat
}

enum HighlightStyle {
    static let uiColor = UIColor(red: 1.0, green: 0.88, blue: 0.0, alpha: 1)
    static let color = Color(uiColor: uiColor)
    /// Every stroke is drawn opaque into one layer, then the layer is laid over the photo at this
    /// opacity with multiply blending — so overlapping strokes don't stack up darker, and the
    /// printed text stays black underneath, like a real highlighter pen.
    static let opacity: CGFloat = 0.45
}

/// Displays a photo and lets the user paint over text with a translucent highlighter, similar to
/// the Markup highlighter in Photos. In `.move` mode the photo can be pinched and dragged instead.
struct HighlightCanvasView: View {
    enum Mode: Hashable { case highlight, move }

    let image: UIImage
    @Binding var strokes: [HighlightStroke]
    var mode: Mode
    /// On-screen brush diameter in points; kept constant regardless of zoom.
    var brushSize: CGFloat

    @State private var currentStroke: HighlightStroke?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let imageRect = Self.aspectFitRect(for: image.size, in: geo.size)

            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                Canvas { context, _ in
                    let all = strokes + (currentStroke.map { [$0] } ?? [])
                    guard !all.isEmpty else { return }
                    context.blendMode = .multiply
                    context.opacity = HighlightStyle.opacity
                    context.drawLayer { layer in
                        for stroke in all {
                            layer.stroke(
                                Self.path(for: stroke, in: imageRect),
                                with: .color(HighlightStyle.color),
                                style: StrokeStyle(lineWidth: stroke.width * imageRect.width, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .clipped()
            .gesture(drawGesture(imageRect: imageRect, viewSize: geo.size), including: mode == .highlight ? .all : .none)
            .gesture(panGesture.simultaneously(with: zoomGesture), including: mode == .move ? .all : .none)
            .onTapGesture(count: 2) {
                guard mode == .move else { return }
                withAnimation(.spring(duration: 0.3)) { resetZoom() }
            }
        }
    }

    // MARK: - Gestures

    private func drawGesture(imageRect: CGRect, viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = normalizedPoint(value.location, imageRect: imageRect, viewSize: viewSize)
                if currentStroke == nil {
                    currentStroke = HighlightStroke(points: [point], width: brushSize / (imageRect.width * scale))
                } else {
                    currentStroke?.points.append(point)
                }
            }
            .onEnded { _ in
                if let stroke = currentStroke { strokes.append(stroke) }
                currentStroke = nil
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(baseScale * value.magnification, 1), 6) }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 { withAnimation(.spring(duration: 0.3)) { resetZoom() } }
            }
    }

    private func resetZoom() {
        scale = 1; baseScale = 1
        offset = .zero; baseOffset = .zero
    }

    /// Converts a touch location in the view into image-relative coordinates, undoing the
    /// zoom (applied around the view's center) and pan.
    private func normalizedPoint(_ location: CGPoint, imageRect: CGRect, viewSize: CGSize) -> CGPoint {
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let unzoomed = CGPoint(
            x: (location.x - center.x - offset.width) / scale + center.x,
            y: (location.y - center.y - offset.height) / scale + center.y
        )
        return CGPoint(
            x: (unzoomed.x - imageRect.minX) / imageRect.width,
            y: (unzoomed.y - imageRect.minY) / imageRect.height
        )
    }

    // MARK: - Geometry

    static func aspectFitRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func path(for stroke: HighlightStroke, in rect: CGRect) -> Path {
        var path = Path()
        let points = stroke.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        guard let first = points.first else { return path }
        path.move(to: first)
        // A single tap still leaves a round dot rather than nothing.
        if points.count == 1 {
            path.addLine(to: first)
        } else {
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
        return path
    }

    /// Bakes the strokes into a copy of the photo, exactly as they appear on screen.
    static func render(image: UIImage, strokes: [HighlightStroke]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rect = CGRect(origin: .zero, size: image.size)
        return UIGraphicsImageRenderer(size: image.size, format: format).image { renderer in
            image.draw(in: rect)
            let cg = renderer.cgContext
            cg.setBlendMode(.multiply)
            cg.setAlpha(HighlightStyle.opacity)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setStrokeColor(HighlightStyle.uiColor.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for stroke in strokes {
                cg.setLineWidth(stroke.width * rect.width)
                cg.addPath(path(for: stroke, in: rect).cgPath)
                cg.strokePath()
            }
            cg.endTransparencyLayer()
        }
    }
}
