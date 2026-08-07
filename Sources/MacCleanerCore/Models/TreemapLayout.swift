import Foundation
import CoreGraphics

public struct TreemapTile: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let size: Int64
    public let rect: CGRect
    public let depth: Int
    public let colorIndex: Int
    public let isDirectory: Bool

    public init(node: DirectoryNode, rect: CGRect, depth: Int, colorIndex: Int) {
        self.id = node.id
        self.name = node.name
        self.path = node.path
        self.size = node.size
        self.rect = rect
        self.depth = depth
        self.colorIndex = colorIndex
        self.isDirectory = node.isDirectory
    }
}

public struct TreemapLayout: Sendable {
    public let tiles: [TreemapTile]

    /// Squarified treemap 算法
    public static func compute(root: DirectoryNode, in rect: CGRect, maxDepth: Int = 2) -> TreemapLayout {
        var tiles: [TreemapTile] = []
        layoutChildren(
            children: root.children,
            rect: rect,
            parentSize: root.size,
            depth: 0,
            maxDepth: maxDepth,
            colorIndex: 0,
            tiles: &tiles
        )
        return TreemapLayout(tiles: tiles)
    }

    private static func layoutChildren(
        children: [DirectoryNode],
        rect: CGRect,
        parentSize: Int64,
        depth: Int,
        maxDepth: Int,
        colorIndex: Int,
        tiles: inout [TreemapTile]
    ) {
        guard parentSize > 0, !children.isEmpty, rect.width > 1, rect.height > 1 else { return }

        let sorted = children.sorted { $0.size > $1.size }
        let rects = squarify(items: sorted.map { Double($0.size) }, in: rect, totalArea: Double(parentSize))

        for (index, child) in sorted.enumerated() {
            guard index < rects.count else { break }
            let childRect = rects[index]
            guard childRect.width > 2, childRect.height > 2 else { continue }

            let ci = depth == 0 ? index : colorIndex

            tiles.append(TreemapTile(node: child, rect: childRect, depth: depth, colorIndex: ci))

            if depth < maxDepth, child.isDirectory, !child.children.isEmpty {
                let inset = childRect.insetBy(dx: 1, dy: 1)
                if inset.width > 4, inset.height > 4 {
                    layoutChildren(
                        children: child.children,
                        rect: inset,
                        parentSize: child.size,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        colorIndex: ci,
                        tiles: &tiles
                    )
                }
            }
        }
    }

    /// Squarified layout: 把加权面积分配到矩形中，尽量保持正方形
    private static func squarify(items: [Double], in rect: CGRect, totalArea: Double) -> [CGRect] {
        guard !items.isEmpty, totalArea > 0 else { return [] }

        let area = Double(rect.width * rect.height)
        let ratios = items.map { $0 / totalArea }

        var rects: [CGRect] = []
        var x = Double(rect.minX)
        var y = Double(rect.minY)
        let isHorizontal = rect.width >= rect.height

        for ratio in ratios {
            let itemArea = ratio * area
            if isHorizontal {
                let w = itemArea / Double(rect.height)
                rects.append(CGRect(x: x, y: Double(rect.minY), width: w, height: Double(rect.height)))
                x += w
            } else {
                let h = itemArea / Double(rect.width)
                rects.append(CGRect(x: Double(rect.minX), y: y, width: Double(rect.width), height: h))
                y += h
            }
        }

        return rects
    }
}
