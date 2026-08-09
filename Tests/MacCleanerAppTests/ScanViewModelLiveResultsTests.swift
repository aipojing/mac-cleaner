import Foundation
import Testing
import MacCleanerCore
@testable import DevClean

private extension CleanableItem {
    static func liveFixture(path: String, size: Int64) -> CleanableItem {
        CleanableItem(
            path: path,
            displayName: (path as NSString).lastPathComponent,
            size: size,
            category: .largeFiles,
            allocatedSize: size
        )
    }
}

private extension LargeFileScanUpdate {
    static func liveFixture(
        items: [CleanableItem],
        matchedFileCount: Int? = nil,
        matchedAllocatedSize: Int64? = nil,
        isFinal: Bool = false
    ) -> LargeFileScanUpdate {
        LargeFileScanUpdate(
            items: items,
            matchedFileCount: matchedFileCount ?? items.count,
            matchedAllocatedSize: matchedAllocatedSize ?? items.reduce(0) { $0 + $1.allocatedSize },
            isFinal: isFinal
        )
    }
}

@MainActor
@Suite("Scan view model live large-file results")
struct ScanViewModelLiveResultsTests {
    @Test("实时大文件快照会替换状态，取消会清空临时结果")
    func clearsLiveItemsWhenCancelled() {
        let viewModel = ScanViewModel()
        viewModel.applyLargeFileUpdate(.liveFixture(items: [.liveFixture(path: "/tmp/a", size: 200)]))
        #expect(viewModel.liveLargeFileItems.count == 1)

        viewModel.cancel()
        #expect(viewModel.liveLargeFileItems.isEmpty)
        #expect(viewModel.liveLargeFileMatchCount == 0)
        #expect(viewModel.totalDiscoveredSize == 0)
    }

    @Test("后续快照替换而非追加，且绝不写入正式结果")
    func appliesSnapshotWithoutTouchingResults() {
        let viewModel = ScanViewModel()
        viewModel.applyLargeFileUpdate(.liveFixture(
            items: [.liveFixture(path: "/tmp/a", size: 200)],
            matchedFileCount: 1,
            matchedAllocatedSize: 200
        ))
        viewModel.applyLargeFileUpdate(.liveFixture(
            items: [
                .liveFixture(path: "/tmp/b", size: 900),
                .liveFixture(path: "/tmp/a", size: 200),
            ],
            matchedFileCount: 3,
            matchedAllocatedSize: 1500,
            isFinal: true
        ))

        #expect(viewModel.liveLargeFileItems.map(\.path) == ["/tmp/b", "/tmp/a"])
        #expect(viewModel.liveLargeFileMatchCount == 3)
        #expect(viewModel.liveLargeFileMatchedSize == 1500)
        #expect(viewModel.results.isEmpty, "实时快照不得写入正式结果")
    }

    @Test("实时大文件快照会更新扫描页显示的已发现占用")
    func updatesDisplayedDiscoveredSizeFromLiveSnapshot() {
        let viewModel = ScanViewModel()

        viewModel.applyLargeFileUpdate(.liveFixture(
            items: [.liveFixture(path: "/tmp/a", size: 200)],
            matchedFileCount: 3,
            matchedAllocatedSize: 1_500
        ))

        #expect(viewModel.totalDiscoveredSize == 1_500)
        #expect(viewModel.results.isEmpty, "实时快照不得写入正式结果")
    }

    @Test("重置会清空实时临时结果")
    func clearsLiveItemsWhenReset() {
        let viewModel = ScanViewModel()
        viewModel.applyLargeFileUpdate(.liveFixture(items: [.liveFixture(path: "/tmp/a", size: 200)]))

        viewModel.reset()
        #expect(viewModel.liveLargeFileItems.isEmpty)
        #expect(viewModel.liveLargeFileMatchCount == 0)
        #expect(viewModel.liveLargeFileMatchedSize == 0)
    }

    @Test("仅单独选中大文件模块时视为大文件实时扫描")
    func detectsLargeFileOnlyScan() {
        let viewModel = ScanViewModel()
        #expect(!viewModel.isLargeFileScan)

        viewModel.selectedModuleIDs = [.largeFiles]
        #expect(viewModel.isLargeFileScan)

        viewModel.selectedModuleIDs = [.largeFiles, .developerCaches]
        #expect(!viewModel.isLargeFileScan)
    }
}
