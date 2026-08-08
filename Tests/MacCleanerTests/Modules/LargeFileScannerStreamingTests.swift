import Foundation
import Testing
@testable import MacCleanerCore

/// 线程安全的实时更新收集器：回调在扫描线程触发，断言在主测试任务读取。
final class LargeFileUpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [LargeFileScanUpdate] = []

    func append(_ update: LargeFileScanUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func snapshot() -> [LargeFileScanUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

@Suite("Large file scanner streaming")
struct LargeFileScannerStreamingTests {
    private func makeFixture(files: [(String, Int)]) throws -> String {
        let root = NSTemporaryDirectory().appending("large-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for (name, size) in files {
            try Data(repeating: 0xAB, count: size)
                .write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent(name)))
        }
        return root
    }

    @Test("大文件扫描在完成前发布候选，并以最终结果收尾")
    func streamsCandidatesBeforeFinalResult() async throws {
        let root = try makeFixture(files: [
            ("a.bin", 8 * 1024),
            ("b.bin", 64 * 1024),
            ("c.bin", 16 * 1024),
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let collector = LargeFileUpdateCollector()
        let context = ScanContext(onLargeFileUpdate: { collector.append($0) })
        let result = try await LargeFileScannerModule(
            scanRoot: root, minAllocatedSize: 1, limit: 2
        ).scan(context: context)

        let updates = collector.snapshot()
        #expect(updates.contains { !$0.isFinal })
        #expect(updates.last?.isFinal == true)
        #expect(updates.last?.items.map(\.path) == result.items.map(\.path))
        // 实时快照与最终结果一致：Top 2，按实际占用降序
        #expect(result.items.map(\.path) == ["\(root)/b.bin", "\(root)/c.bin"])
        #expect(updates.last?.matchedFileCount == 3)
    }

    @Test("同一 device/inode 的硬链接在累计物理占用中只计一次")
    func hardLinksCountedOnceInMatchedSize() async throws {
        let root = try makeFixture(files: [("a.bin", 32 * 1024)])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.linkItem(
            atPath: (root as NSString).appendingPathComponent("a.bin"),
            toPath: (root as NSString).appendingPathComponent("b.bin")
        )

        let collector = LargeFileUpdateCollector()
        let context = ScanContext(onLargeFileUpdate: { collector.append($0) })
        let result = try await LargeFileScannerModule(
            scanRoot: root, minAllocatedSize: 1, limit: 10
        ).scan(context: context)

        let final = try #require(collector.snapshot().last)
        #expect(final.isFinal)
        #expect(final.matchedFileCount == 2)
        let singleFileSize = try #require(result.items.first?.allocatedSize)
        #expect(final.matchedAllocatedSize == singleFileSize)
    }

    @Test("无处理器时扫描结果与既有语义一致")
    func scanWithoutHandlerKeepsExistingBehavior() async throws {
        let root = try makeFixture(files: [
            ("a.bin", 8 * 1024),
            ("b.bin", 64 * 1024),
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = try await LargeFileScannerModule(
            scanRoot: root, minAllocatedSize: 1, limit: 10
        ).scan(context: ScanContext())

        #expect(result.items.map(\.path) == ["\(root)/b.bin", "\(root)/a.bin"])
        #expect(result.items.allSatisfy { $0.fileIdentity != nil })
    }
}
