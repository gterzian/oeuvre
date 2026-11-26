import CoreGraphics
import Foundation

/// The grid drawn over one capture. Labels are local to `origin`: a refined
/// capture has its own descriptor, so a cell name from the refined image maps
/// back through the region it came from.
struct GridDescriptor: Codable, Equatable, Sendable {
    var origin: CGRect
    var columns: Int
    var rows: Int

    var cellWidth: CGFloat { origin.width / CGFloat(max(columns, 1)) }
    var cellHeight: CGFloat { origin.height / CGFloat(max(rows, 1)) }

    static func make(viewport: CGSize, cellSize: CGFloat) -> GridDescriptor {
        let columns = max(4, Int(ceil(viewport.width / max(cellSize, 24))))
        let rows = max(3, Int(ceil(viewport.height / max(cellSize, 24))))
        return GridDescriptor(origin: CGRect(origin: .zero, size: viewport), columns: columns, rows: rows)
    }

    /// The descriptor for a region captured at higher resolution. The refined
    /// grid keeps roughly the same number of cells per coarse cell, doubled so
    /// a small control has a cell of its own.
    func refined(region: CGRect) -> GridDescriptor {
        let clipped = region.intersection(origin)
        let base = clipped.isEmpty ? origin : clipped
        let coarseColumns = max(1, Int(ceil(base.width / max(cellWidth, 1))))
        let coarseRows = max(1, Int(ceil(base.height / max(cellHeight, 1))))
        return GridDescriptor(
            origin: base,
            columns: max(2, coarseColumns * 2),
            rows: max(2, coarseRows * 2)
        )
    }

    func cellRect(label: String) -> CGRect? {
        guard let address = CellAddress(label: label) else { return nil }
        guard address.column >= 0, address.column < columns,
              address.row >= 0, address.row < rows
        else { return nil }
        return CGRect(
            x: origin.minX + CGFloat(address.column) * cellWidth,
            y: origin.minY + CGFloat(address.row) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    /// The point a pointer action names: the cell's center, moved by the
    /// fractions inside the cell when the model aims at a smaller target.
    func point(label: String, at fractions: CGPoint?) -> CGPoint? {
        guard let rect = cellRect(label: label) else { return nil }
        let at = fractions ?? CGPoint(x: 0.5, y: 0.5)
        let x = rect.minX + max(0, min(1, at.x)) * rect.width
        let y = rect.minY + max(0, min(1, at.y)) * rect.height
        return CGPoint(x: x, y: y)
    }

    func cellLabel(for point: CGPoint) -> String? {
        guard origin.contains(point) else { return nil }
        let column = Int(floor((point.x - origin.minX) / max(cellWidth, 1)))
        let row = Int(floor((point.y - origin.minY) / max(cellHeight, 1)))
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        return "\(CellAddress.columnLabel(column))\(row + 1)"
    }

    var caption: String {
        "grid A-\(CellAddress.columnLabel(columns - 1)) by 1-\(rows), \(Int(origin.width)) by \(Int(origin.height)) points"
    }
}

struct CellAddress: Equatable, Sendable {
    var column: Int
    var row: Int

    init?(label: String) {
        let upper = label.trimmingCharacters(in: .whitespaces).uppercased()
        var letters = ""
        var digits = ""
        for character in upper {
            if character.isLetter {
                guard digits.isEmpty else { return nil }
                letters.append(character)
            } else if character.isNumber {
                digits.append(character)
            } else {
                return nil
            }
        }
        guard !letters.isEmpty, !digits.isEmpty, let row = Int(digits), row > 0 else { return nil }
        var column = 0
        for scalar in letters.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            column = column * 26 + Int(scalar.value - 64)
        }
        self.column = column - 1
        self.row = row - 1
    }

    static func columnLabel(_ index: Int) -> String {
        var value = max(0, index) + 1
        var result = ""
        while value > 0 {
            value -= 1
            let scalar = UnicodeScalar(65 + value % 26)!
            result = String(scalar) + result
            value /= 26
        }
        return result
    }
}
