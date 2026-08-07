import Foundation
import Testing
@testable import MacCleanerCore

extension FileIdentity {
    static func fixture(
        device: UInt64 = 16_777_216,
        inode: UInt64 = 42,
        kind: FileObjectKind = .directory
    ) -> FileIdentity {
        FileIdentity(device: device, inode: inode, kind: kind)
    }
}

extension CleanableItem {
    static func fixture(
        path: String = "/tmp/cache",
        displayName: String = "cache",
        size: Int64 = 16,
        category: ModuleIdentifier = .developerCaches,
        subcategory: String? = "npm",
        evidenceTags: [String] = ["cache", "developer-tool", "npm"],
        fileIdentity: FileIdentity? = .fixture()
    ) -> CleanableItem {
        CleanableItem(
            path: path,
            displayName: displayName,
            size: size,
            category: category,
            subcategory: subcategory,
            evidenceTags: evidenceTags,
            fileIdentity: fileIdentity
        )
    }
}

@Suite("Cleanable item evidence")
struct CleanableItemEvidenceTests {
    @Test("模型只含原始事实，不含本地风险和推荐")
    func storesFacts() {
        let item = CleanableItem(
            path: "/tmp/cache",
            displayName: "cache",
            size: 16,
            category: .developerCaches,
            subcategory: "npm",
            evidenceTags: ["cache", "developer-tool", "npm"],
            fileIdentity: .fixture()
        )

        #expect(item.evidenceTags == ["cache", "developer-tool", "npm"])
        #expect(item.subcategory == "npm")
        #expect(item.size == 16)
    }

    @Test("标签去空、去重并按字典序固定，保证指纹稳定")
    func tagsNormalized() {
        let item = CleanableItem(
            path: "/tmp/cache",
            displayName: "cache",
            size: 1,
            category: .xcode,
            evidenceTags: ["xcode", " cache ", "cache", "", "developer-tool"]
        )

        #expect(item.evidenceTags == ["cache", "developer-tool", "xcode"])
    }

    @Test("事实标签不编码风险或推荐判断")
    func tagsContainNoJudgment() {
        let item = CleanableItem.fixture()
        let banned = ["safe", "dangerous", "recommended", "destructive", "risk"]
        for tag in item.evidenceTags {
            #expect(!banned.contains(tag))
        }
    }
}
