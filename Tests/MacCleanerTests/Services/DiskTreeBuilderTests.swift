import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Disk tree builder")
struct DiskTreeBuilderTests {
    private func makeFixture() throws -> String {
        let root = NSTemporaryDirectory().appending("tree-builder-\(UUID().uuidString)")
        let fm = FileManager.default

        // 小目录（不展开）
        let small = (root as NSString).appendingPathComponent("small")
        try fm.createDirectory(atPath: small, withIntermediateDirectories: true)
        try Data(count: 1024).write(to: URL(fileURLWithPath: (small as NSString).appendingPathComponent("a.bin")))

        // 大目录（>10MB，展开一级）
        let big = (root as NSString).appendingPathComponent("big")
        try fm.createDirectory(atPath: big, withIntermediateDirectories: true)
        try Data(count: 11 * 1024 * 1024).write(to: URL(fileURLWithPath: (big as NSString).appendingPathComponent("b.bin")))
        let bigSub = (big as NSString).appendingPathComponent("sub")
        try fm.createDirectory(atPath: bigSub, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: URL(fileURLWithPath: (bigSub as NSString).appendingPathComponent("c.bin")))

        // 根目录直属文件
        try Data(count: 4096).write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("root.bin")))

        // 硬链接：与 root.bin 同一 inode，整棵树只计一次
        try fm.linkItem(
            atPath: (root as NSString).appendingPathComponent("root.bin"),
            toPath: (small as NSString).appendingPathComponent("root-link.bin")
        )

        // 跳过目录
        let trash = (root as NSString).appendingPathComponent(".Trash")
        try fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try Data(count: 8192).write(to: URL(fileURLWithPath: (trash as NSString).appendingPathComponent("t.bin")))

        return root
    }

    @Test("单次遍历构建：大小正确、大目录展开、小目录为叶子")
    func buildsTreeInOnePass() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let tree = await DiskTreeBuilder().buildTree(at: root, maxDepth: 2)

        let big = try #require(tree.children.first { $0.name == "big" })
        let small = try #require(tree.children.first { $0.name == "small" })
        let rootFile = try #require(tree.children.first { $0.name == "root.bin" })

        #expect(big.children.contains { $0.name == "sub" }, ">10MB 目录应展开")
        #expect(small.children.isEmpty, "小目录应为叶子")
        #expect(!tree.children.contains { $0.name == ".Trash" }, "跳过目录不应出现")

        // 根大小 = big + small + root.bin（硬链接不重复计）
        let expected = big.size + small.size + rootFile.size
        #expect(tree.size == expected, "根大小应等于各分支之和（硬链接只计一次）")
        #expect(tree.size > 11 * 1024 * 1024)
    }

    @Test("硬链接对象整棵树只计一次 allocated size")
    func hardLinksCountedOnce() async throws {
        // 目录里只有同一文件的两条硬链接：目录大小应等于一份，而不是两份
        let root = NSTemporaryDirectory().appending("tree-hardlink-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let original = (root as NSString).appendingPathComponent("orig.bin")
        try Data(count: 4096).write(to: URL(fileURLWithPath: original))
        try fm.linkItem(atPath: original, toPath: (root as NSString).appendingPathComponent("copy.bin"))

        let tree = await DiskTreeBuilder().buildTree(at: root, maxDepth: 2)

        #expect(tree.size == 4096, "同一 inode 的两条路径只应计一次，实际 \(tree.size)")
    }
}
