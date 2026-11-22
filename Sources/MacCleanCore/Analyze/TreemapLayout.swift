import CoreGraphics
import Foundation

/// A positioned rectangle in a nested squarified treemap.
public struct TreemapCell: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    /// Path of the depth-0 ancestor (direct child of the analyzed directory), used for list selection sync.
    public let topLevelPath: String
    public let parentName: String
    public let size: Int64
    public let itemCount: Int
    public let isDir: Bool
    public let depth: Int
    public let groupIndex: Int
    public let rect: CGRect
    public let children: [TreemapCell]

    public init(path: String, name: String, topLevelPath: String, parentName: String,
                size: Int64, itemCount: Int, isDir: Bool, depth: Int, groupIndex: Int,
                rect: CGRect, children: [TreemapCell] = []) {
        self.path = path
        self.name = name
        self.topLevelPath = topLevelPath
        self.parentName = parentName
        self.size = size
        self.itemCount = itemCount
        self.isDir = isDir
        self.depth = depth
        self.groupIndex = groupIndex
        self.rect = rect
        self.children = children
    }
}

/// Computes a hierarchical Squarified Treemap layout (Bruls, Huizing, van Wijk)
/// from an `AnalyzeResult` and its optional `AnalyzeNode` tree.
public enum TreemapLayout {
    private struct Item {
        let path: String
        let name: String
        let topLevelPath: String
        let parentName: String
        let size: Int64
        let itemCount: Int
        let isDir: Bool
        let groupIndex: Int
        let node: AnalyzeNode?
    }

    /// Generates top-level treemap cells (with nested children up to `maxDepth`) inside `bounds`.
    public static func compute(
        result: AnalyzeResult,
        in bounds: CGRect,
        maxDepth: Int = 2,
        maxItemsPerLevel: Int = 36
    ) -> [TreemapCell] {
        guard bounds.width > 8, bounds.height > 8, result.totalSize > 0 else { return [] }
        let rawRootName = (result.root as NSString).lastPathComponent
        let rootName = (rawRootName.isEmpty || rawRootName == "/")
            ? FileManager.default.displayName(atPath: "/")
            : rawRootName
        let dirsByPath: [String: AnalyzeNode] = Dictionary(
            uniqueKeysWithValues: (result.tree?.dirs ?? []).map { ($0.path, $0) }
        )

        let topEntries = Array(result.entries.filter { $0.size > 0 }.prefix(maxItemsPerLevel))
        let items: [Item] = topEntries.enumerated().map { idx, entry in
            Item(
                path: entry.path,
                name: entry.name,
                topLevelPath: entry.path,
                parentName: rootName,
                size: entry.size,
                itemCount: entry.itemCount,
                isDir: entry.isDir,
                groupIndex: idx,
                node: dirsByPath[entry.path]
            )
        }

        return layoutItems(
            items,
            in: bounds,
            depth: 0,
            maxDepth: maxDepth,
            maxItemsPerLevel: maxItemsPerLevel
        )
    }

    /// Finds the deepest cell containing `point` (or nil if outside all cells).
    public static func hitTest(_ cells: [TreemapCell], at point: CGPoint) -> TreemapCell? {
        for cell in cells where cell.rect.contains(point) {
            if let childHit = hitTest(cell.children, at: point) {
                return childHit
            }
            return cell
        }
        return nil
    }

    // MARK: - Recursive layout

    private static func layoutItems(
        _ items: [Item],
        in bounds: CGRect,
        depth: Int,
        maxDepth: Int,
        maxItemsPerLevel: Int
    ) -> [TreemapCell] {
        let positive = items.filter { $0.size > 0 }
        guard !positive.isEmpty, bounds.width >= 6, bounds.height >= 6 else { return [] }

        let rects = squarify(sizes: positive.map { Double($0.size) }, in: bounds)
        var out: [TreemapCell] = []
        out.reserveCapacity(positive.count)

        for (i, item) in positive.enumerated() {
            let r = rects[i]
            guard r.width >= 2, r.height >= 2 else { continue }

            var childCells: [TreemapCell] = []
            // Subdivide directories when there is enough room for a header + inner tiles
            if depth < maxDepth, item.isDir, let node = item.node,
               r.width >= 54, r.height >= 42 {
                let headerHeight: CGFloat = depth == 0 ? 19 : 16
                let pad: CGFloat = depth == 0 ? 3 : 2
                let innerRect = CGRect(
                    x: r.minX + pad,
                    y: r.minY + headerHeight,
                    width: r.width - pad * 2,
                    height: r.height - headerHeight - pad
                )
                if innerRect.width >= 20, innerRect.height >= 16 {
                    let subItems = childItems(
                        of: node,
                        topLevelPath: item.topLevelPath,
                        groupIndex: item.groupIndex,
                        limit: max(12, maxItemsPerLevel / (depth + 2))
                    )
                    if !subItems.isEmpty {
                        childCells = layoutItems(
                            subItems,
                            in: innerRect,
                            depth: depth + 1,
                            maxDepth: maxDepth,
                            maxItemsPerLevel: maxItemsPerLevel
                        )
                    }
                }
            }

            out.append(
                TreemapCell(
                    path: item.path,
                    name: item.name,
                    topLevelPath: item.topLevelPath,
                    parentName: item.parentName,
                    size: item.size,
                    itemCount: item.itemCount,
                    isDir: item.isDir,
                    depth: depth,
                    groupIndex: item.groupIndex,
                    rect: r,
                    children: childCells
                )
            )
        }
        return out
    }

    private static func childItems(
        of node: AnalyzeNode,
        topLevelPath: String,
        groupIndex: Int,
        limit: Int
    ) -> [Item] {
        var all: [Item] = []
        all.reserveCapacity(node.dirs.count + node.files.count)
        for d in node.dirs where d.size > 0 {
            all.append(
                Item(
                    path: d.path,
                    name: d.name,
                    topLevelPath: topLevelPath,
                    parentName: node.name,
                    size: d.size,
                    itemCount: d.itemCount,
                    isDir: true,
                    groupIndex: groupIndex,
                    node: d
                )
            )
        }
        for f in node.files where f.size > 0 {
            all.append(
                Item(
                    path: (node.path == "/" ? "/" : node.path + "/") + f.name,
                    name: f.name,
                    topLevelPath: topLevelPath,
                    parentName: node.name,
                    size: f.size,
                    itemCount: f.itemCount,
                    isDir: false,
                    groupIndex: groupIndex,
                    node: nil
                )
            )
        }
        all.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        return Array(all.prefix(limit))
    }

    // MARK: - Squarified Treemap Algorithm

    /// Splits `bounds` into rectangles proportional to `sizes` (assumed > 0 and sorted descending).
    static func squarify(sizes: [Double], in bounds: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0, !sizes.isEmpty else {
            return Array(repeating: .zero, count: sizes.count)
        }
        let area = Double(bounds.width * bounds.height)
        let scaled = sizes.map { $0 / total * area }

        var results = Array(repeating: CGRect.zero, count: sizes.count)
        var remaining = bounds
        var rowIndices: [Int] = []
        var rowAreas: [Double] = []

        for i in scaled.indices {
            let nextArea = scaled[i]
            if rowAreas.isEmpty {
                rowIndices.append(i)
                rowAreas.append(nextArea)
                continue
            }
            let side = Double(min(remaining.width, remaining.height))
            let currentWorst = worstAspectRatio(rowAreas, sideLength: side)
            let candidateWorst = worstAspectRatio(rowAreas + [nextArea], sideLength: side)
            if candidateWorst <= currentWorst {
                rowIndices.append(i)
                rowAreas.append(nextArea)
            } else {
                remaining = layoutRow(indices: rowIndices, areas: rowAreas, in: remaining, out: &results)
                rowIndices = [i]
                rowAreas = [nextArea]
            }
        }
        if !rowIndices.isEmpty {
            _ = layoutRow(indices: rowIndices, areas: rowAreas, in: remaining, out: &results)
        }
        return results
    }

    private static func worstAspectRatio(_ areas: [Double], sideLength w: Double) -> Double {
        guard !areas.isEmpty, w > 0 else { return .infinity }
        let sum = areas.reduce(0, +)
        guard sum > 0 else { return .infinity }
        var maxArea = 0.0
        var minArea = Double.greatestFiniteMagnitude
        for a in areas {
            if a > maxArea { maxArea = a }
            if a < minArea { minArea = a }
        }
        guard minArea > 0 else { return .infinity }
        let w2 = w * w
        let s2 = sum * sum
        return max((w2 * maxArea) / s2, s2 / (w2 * minArea))
    }

    private static func layoutRow(
        indices: [Int],
        areas: [Double],
        in rect: CGRect,
        out: inout [CGRect]
    ) -> CGRect {
        let rowArea = areas.reduce(0, +)
        guard rowArea > 0, rect.width > 0, rect.height > 0 else { return rect }

        let horizontalSplit = rect.width >= rect.height
        if horizontalSplit {
            // Lay out a vertical strip along the left edge of `rect`
            let stripWidth = min(rect.width, CGFloat(rowArea / Double(rect.height)))
            var y = rect.minY
            for (idx, a) in zip(indices, areas) {
                let h = idx == indices.last
                    ? max(0, rect.maxY - y)
                    : min(rect.maxY - y, stripWidth > 0 ? CGFloat(a) / stripWidth : 0)
                out[idx] = CGRect(x: rect.minX, y: y, width: stripWidth, height: max(0, h))
                y += h
            }
            return CGRect(
                x: rect.minX + stripWidth,
                y: rect.minY,
                width: max(0, rect.width - stripWidth),
                height: rect.height
            )
        } else {
            // Lay out a horizontal strip along the top edge of `rect`
            let stripHeight = min(rect.height, CGFloat(rowArea / Double(rect.width)))
            var x = rect.minX
            for (idx, a) in zip(indices, areas) {
                let w = idx == indices.last
                    ? max(0, rect.maxX - x)
                    : min(rect.maxX - x, stripHeight > 0 ? CGFloat(a) / stripHeight : 0)
                out[idx] = CGRect(x: x, y: rect.minY, width: max(0, w), height: stripHeight)
                x += w
            }
            return CGRect(
                x: rect.minX,
                y: rect.minY + stripHeight,
                width: rect.width,
                height: max(0, rect.height - stripHeight)
            )
        }
    }
}
