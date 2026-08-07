import Foundation
import MacCleanerCore

@Observable
@MainActor
final class DiskVisualizationViewModel {
    var isLoading = false
    var navigationStack: [DirectoryNode] = []
    var hoveredTile: TreemapTile?

    private let builder = DiskTreeBuilder()

    var currentNode: DirectoryNode? {
        navigationStack.last
    }

    var breadcrumbs: [DirectoryNode] {
        navigationStack
    }

    func loadRoot() {
        isLoading = true
        navigationStack = []
        Task {
            let root = await builder.buildTree(at: DiskScanner.homeDirectory, maxDepth: 2)
            navigationStack = [root]
            isLoading = false
        }
    }

    func drillInto(_ tile: TreemapTile) {
        guard tile.isDirectory else { return }
        isLoading = true
        Task {
            let node = await builder.buildTree(at: tile.path, maxDepth: 2)
            navigationStack.append(node)
            isLoading = false
        }
    }

    func navigateTo(index: Int) {
        guard index < navigationStack.count else { return }
        navigationStack = Array(navigationStack.prefix(index + 1))
    }
}
