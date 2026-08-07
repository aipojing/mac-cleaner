import Testing
import Foundation
@testable import MacCleanerCore

extension CleanableItem {
    /// 测试构造：直接指定路径、模块、标签和物理身份。
    static func fixture(
        path: String,
        module: ModuleIdentifier = .developerCaches,
        tags: [String] = [],
        kind: FileObjectKind = .regularFile,
        device: UInt64 = 1,
        inode: UInt64 = 100,
        size: Int64 = 4_096,
        allocatedSize: Int64? = nil,
        linkCount: UInt64 = 1,
        withIdentity: Bool = true
    ) -> CleanableItem {
        CleanableItem(
            path: path,
            displayName: (path as NSString).lastPathComponent,
            size: size,
            category: module,
            evidenceTags: tags,
            fileIdentity: withIdentity ? FileIdentity(device: device, inode: inode, kind: kind) : nil,
            allocatedSize: allocatedSize,
            linkCount: linkCount
        )
    }
}

@Suite("Candidate merger")
struct CandidateMergerTests {
    @Test("相同规范化路径合并 tags 和来源模块")
    func mergesSamePath() {
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/cache/./a", module: .developerCaches, tags: ["npm"]),
            .fixture(path: "/tmp/cache/a", module: .largeFiles, tags: ["large-file"]),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].sourceModules == [.developerCaches, .largeFiles])
        #expect(Set(merged[0].evidenceTags) == ["npm", "large-file"])
    }

    @Test("不同路径的硬链接保留两个事实，但物理占用只计一次")
    func countsHardlinksOnceWithoutMergingPaths() {
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/a", device: 1, inode: 10, allocatedSize: 4096, linkCount: 2),
            .fixture(path: "/tmp/b", device: 1, inode: 10, allocatedSize: 4096, linkCount: 2),
        ])
        #expect(merged.count == 2)
        #expect(PhysicalSizeCalculator.uniqueAllocatedBytes(in: merged) == 4096)
        #expect(PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: [merged[0]],
            allKnownItems: merged
        ) == 0)
        #expect(PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: merged,
            allKnownItems: merged
        ) == 4096)
    }

    @Test("父目录候选覆盖子项时只计父目录一次")
    func parentDirectoryOwnsDescendants() {
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/cache", kind: .directory, allocatedSize: 10_000),
            .fixture(path: "/tmp/cache/a", kind: .regularFile, allocatedSize: 4_096),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].path == "/tmp/cache")
        #expect(merged[0].allocatedSize == 10_000)
    }

    @Test("符号链接不与目标 inode 合并，独立保留")
    func symlinkKeepsOwnIdentity() {
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/target", kind: .regularFile, device: 1, inode: 20),
            .fixture(path: "/tmp/link", kind: .symbolicLink, device: 1, inode: 21),
        ])
        #expect(merged.count == 2)
    }

    @Test("主 category 按固定优先级而不是输入顺序")
    func primaryCategoryFollowsFixedPriority() {
        // largeFiles 在 allCases 中排在 developerCaches 之后
        let merged = CandidateMerger().merge([
            .fixture(path: "/tmp/x", module: .largeFiles, tags: ["large-file"]),
            .fixture(path: "/tmp/x", module: .developerCaches, tags: ["npm"]),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].category == .developerCaches)
        #expect(merged[0].sourceModules == [.developerCaches, .largeFiles])
    }

    @Test("合并后展示名取主 category 候选")
    func displayNameComesFromPrimary() {
        let primary = CleanableItem(
            path: "/tmp/y", displayName: "npm 缓存", size: 100,
            category: .developerCaches, evidenceTags: ["npm"]
        )
        let secondary = CleanableItem(
            path: "/tmp/y", displayName: "tmp/y", size: 100,
            category: .largeFiles, evidenceTags: ["large-file"]
        )
        let merged = CandidateMerger().merge([secondary, primary])
        #expect(merged.count == 1)
        #expect(merged[0].displayName == "npm 缓存")
    }
}

@Suite("Physical size calculator")
struct PhysicalSizeCalculatorTests {
    @Test("无身份条目逐项计入，硬链接按 inode 去重")
    func uniqueBytesHandleMixedItems() {
        let items: [CleanableItem] = [
            .fixture(path: "/tmp/a", device: 1, inode: 1, allocatedSize: 100, withIdentity: false),
            .fixture(path: "/tmp/b", device: 1, inode: 2, allocatedSize: 200),
            .fixture(path: "/tmp/c", device: 1, inode: 2, allocatedSize: 200, linkCount: 2),
        ]
        #expect(PhysicalSizeCalculator.uniqueAllocatedBytes(in: items) == 300)
    }

    @Test("linkCount 大于已知路径数时选中全部已知路径也不计入")
    func unknownHardlinkPathsBlockReclaim() {
        // inode 有 3 个硬链接，但扫描只发现 2 个路径
        let items: [CleanableItem] = [
            .fixture(path: "/tmp/a", device: 1, inode: 5, allocatedSize: 4096, linkCount: 3),
            .fixture(path: "/tmp/b", device: 1, inode: 5, allocatedSize: 4096, linkCount: 3),
        ]
        #expect(PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: items,
            allKnownItems: items
        ) == 0)
    }

    @Test("普通文件选中即计入")
    func singleLinkFileReclaimsOnSelect() {
        let item = CleanableItem.fixture(path: "/tmp/a", allocatedSize: 2048)
        #expect(PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: [item],
            allKnownItems: [item]
        ) == 2048)
    }

    @Test("跨模块硬链接只归属一个模块且小计之和等于全局总计")
    func moduleBreakdownAttributesPhysicalObjectOnce() {
        let items: [CleanableItem] = [
            .fixture(
                path: "/tmp/dev-link",
                module: .developerCaches,
                device: 1,
                inode: 42,
                allocatedSize: 4096,
                linkCount: 2
            ),
            .fixture(
                path: "/tmp/app-link",
                module: .applicationCaches,
                device: 1,
                inode: 42,
                allocatedSize: 4096,
                linkCount: 2
            ),
        ]

        let breakdown = PhysicalSizeCalculator.estimatedReclaimableBytesByModule(
            selected: items,
            allKnownItems: items
        )
        let global = PhysicalSizeCalculator.estimatedReclaimableBytes(
            selected: items,
            allKnownItems: items
        )

        #expect(breakdown[.developerCaches] == 4096)
        #expect(breakdown[.applicationCaches, default: 0] == 0)
        #expect(breakdown.values.reduce(0, +) == global)
    }
}
