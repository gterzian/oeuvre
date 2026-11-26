import CoreGraphics
import CoreText
import Foundation

enum Compositor {
    static func compose(layers: [LayerSnapshot], viewport: CGSize) -> CGImage? {
        guard viewport.width > 1, viewport.height > 1 else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        let root = layers.first { $0.parent == nil }
        let rootWidth = max(1, root?.width ?? Int(viewport.width))
        let scaleX = viewport.width / CGFloat(rootWidth)
        let scaleY = viewport.height / CGFloat(max(1, root?.height ?? Int(viewport.height)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: Int(viewport.width.rounded()),
            height: Int(viewport.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: Int(viewport.width.rounded()) * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        // Work in top-left web coordinates for the whole composition.
        context.translateBy(x: 0, y: viewport.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: viewport))
        context.interpolationQuality = .high

        func absolute(_ layer: LayerSnapshot) -> CGAffineTransform {
            guard let parentID = layer.parent, let parent = byID[parentID] else {
                return layer.transform
            }
            return layer.transform.concatenating(absolute(parent))
        }

        func depth(_ layer: LayerSnapshot) -> Int {
            var depth = 0
            var current: LayerSnapshot? = layer
            while let parentID = current?.parent, let parent = byID[parentID] {
                depth += 1
                current = parent
            }
            return depth
        }

        let ordered = layers.sorted { lhs, rhs in
            let left = depth(lhs)
            let right = depth(rhs)
            if left != right { return left < right }
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.paintOrder < rhs.paintOrder
        }

        let worldToView = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: 0, ty: 0)
        for layer in ordered {
            guard let image = layer.image else { continue }
            let transform = absolute(layer)
            let parentTransform = layer.parent.flatMap { byID[$0] }.map(absolute) ?? .identity
            context.saveGState()
            if layer.parent != nil {
                let clip = layer.clipBounds.applying(parentTransform)
                let rect = CGRect(
                    x: clip.minX * scaleX,
                    y: clip.minY * scaleY,
                    width: clip.width * scaleX,
                    height: clip.height * scaleY
                ).intersection(CGRect(origin: .zero, size: viewport))
                if rect.isEmpty {
                    context.restoreGState()
                    continue
                }
                context.clip(to: rect)
            } else {
                context.clip(to: CGRect(origin: .zero, size: viewport))
            }
            context.concatenate(worldToView.concatenating(transform))
            // The context is top-left; a CGImage draws upright only after a
            // local vertical flip.
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(layer.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: CGFloat(layer.width), height: CGFloat(layer.height))
            )
            context.restoreGState()
            context.restoreGState()
        }
        return context.makeImage()
    }
}

enum GridOverlay {
    static func draw(on context: CGContext, image: CGImage, grid: GridDescriptor, viewport: CGSize) {
        let height = viewport.height
        let cellWidth = grid.cellWidth
        let cellHeight = grid.cellHeight
        guard cellWidth > 2, cellHeight > 2 else { return }

        context.saveGState()
        context.setLineWidth(1)
        for column in 0...grid.columns {
            let x = grid.origin.minX + CGFloat(column) * cellWidth
            let line = CGRect(x: x, y: 0, width: 1 / max(1, UIScreenScale.current), height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 0.35))
            context.fill(line)
            context.setFillColor(CGColor(gray: 0, alpha: 0.22))
            context.fill(line.offsetBy(dx: 0.5, dy: 0))
        }
        for row in 0...grid.rows {
            let y = grid.origin.minY + CGFloat(row) * cellHeight
            let line = CGRect(x: 0, y: height - y - 1, width: viewport.width, height: 1)
            context.setFillColor(CGColor(gray: 1, alpha: 0.35))
            context.fill(line)
            context.setFillColor(CGColor(gray: 0, alpha: 0.22))
            context.fill(line.offsetBy(dx: 0, dy: 0.5))
        }

        let fontSize = max(7, min(10, min(cellWidth, cellHeight) * 0.22))
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let label = "\(CellAddress.columnLabel(column))\(row + 1)"
                let x = grid.origin.minX + CGFloat(column) * cellWidth + 1.5
                let top = grid.origin.minY + CGFloat(row) * cellHeight + 1.5
                let sample = CGPoint(
                    x: x + 1,
                    y: CGFloat(image.height) * (top / max(0.001, height))
                )
                let luminance = ImageSupport.averageLuminance(image, at: sample)
                let fill = luminance < 0.45 ? CGColor(gray: 1, alpha: 0.95) : CGColor(gray: 0.05, alpha: 0.95)
                let stroke = luminance < 0.45 ? CGColor(gray: 0, alpha: 0.7) : CGColor(gray: 1, alpha: 0.7)
                drawText(
                    label,
                    at: CGPoint(x: x, y: top),
                    context: context,
                    canvasHeight: height,
                    font: font,
                    fill: fill,
                    stroke: stroke
                )
            }
        }

        // Edge labels repeat the names outside the page body's busiest area.
        let edgeFont = CTFontCreateWithName("Menlo-Bold" as CFString, max(8, fontSize), nil)
        for column in 0..<grid.columns {
            let label = CellAddress.columnLabel(column)
            let x = grid.origin.minX + (CGFloat(column) + 0.5) * cellWidth
            drawText(
                label,
                at: CGPoint(x: x - 3, y: 1),
                context: context,
                canvasHeight: height,
                font: edgeFont,
                fill: CGColor(gray: 1, alpha: 0.95),
                stroke: CGColor(gray: 0, alpha: 0.8)
            )
        }
        for row in 0..<grid.rows {
            let y = grid.origin.minY + (CGFloat(row) + 0.5) * cellHeight
            drawText(
                "\(row + 1)",
                at: CGPoint(x: 2, y: y - fontSize / 2),
                context: context,
                canvasHeight: height,
                font: edgeFont,
                fill: CGColor(gray: 1, alpha: 0.95),
                stroke: CGColor(gray: 0, alpha: 0.8)
            )
        }
        context.restoreGState()
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        context: CGContext,
        canvasHeight: CGFloat,
        font: CTFont,
        fill: CGColor,
        stroke: CGColor
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: fill,
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        context.setFillColor(fill)
        context.setStrokeColor(stroke)
        context.setLineWidth(2.2)
        context.setTextDrawingMode(.fillStroke)
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: point.x,
            y: canvasHeight - point.y - bounds.height - CTFontGetDescent(font)
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private enum UIScreenScale {
    static var current: CGFloat {
        #if canImport(AppKit)
        return NSScreen.main?.backingScaleFactor ?? 2
        #else
        return 2
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
