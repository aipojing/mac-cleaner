import Foundation
import Testing
@testable import MacCleanerCore

@Suite("File metadata")
struct FileMetadataTests {
    @Test("实际占用来自 st_blocks 而不是 st_size")
    func usesAllocatedBlocks() {
        let metadata = FileMetadata.fromStat(
            path: "/tmp/sparse",
            device: 1,
            inode: 2,
            mode: S_IFREG | 0o644,
            logicalSize: 1_000_000,
            blocks: 8,
            linkCount: 1,
            modificationTimeNanoseconds: 100
        )
        #expect(metadata.logicalSize == 1_000_000)
        #expect(metadata.allocatedSize == 4_096)
        #expect(metadata.kind == .regularFile)
        #expect(metadata.identity == FileIdentity(device: 1, inode: 2, kind: .regularFile))
    }

    @Test("负 block 数按 0 处理")
    func clampsNegativeBlocks() {
        let metadata = FileMetadata.fromStat(
            path: "/tmp/x",
            device: 1,
            inode: 2,
            mode: S_IFDIR | 0o755,
            logicalSize: 64,
            blocks: -8,
            linkCount: 2,
            modificationTimeNanoseconds: 0
        )
        #expect(metadata.allocatedSize == 0)
        #expect(metadata.kind == .directory)
    }

    @Test("符号链接保持自身类型且不跟随目标")
    func preservesSymlinkIdentity() async throws {
        let fixture = try SymlinkFixture.make()
        defer { fixture.cleanup() }

        let provider = POSIXFileMetadataProvider()
        let metadata = try await provider.metadata(at: fixture.link)
        #expect(metadata.kind == .symbolicLink)

        let targetMetadata = try await provider.metadata(at: fixture.target)
        #expect(targetMetadata.kind == .regularFile)
        #expect(metadata.identity.inode != targetMetadata.identity.inode)
    }

    @Test("路径标准化折叠 . .. 和重复斜杠，不解析最终符号链接")
    func normalizesPath() async throws {
        let fixture = try SymlinkFixture.make()
        defer { fixture.cleanup() }

        let provider = POSIXFileMetadataProvider()
        let messy = fixture.link + "/.././" + (fixture.target as NSString).lastPathComponent
        let metadata = try await provider.metadata(at: messy)
        #expect(metadata.path == fixture.target)
        #expect(metadata.kind == .regularFile)
    }

    @Test("不存在的路径抛出 notFound")
    func missingPathThrowsNotFound() async {
        let provider = POSIXFileMetadataProvider()
        await #expect(throws: MetadataError.self) {
            _ = try await provider.metadata(at: "/tmp/definitely-missing-\(UUID().uuidString)")
        }
    }
}

/// 真实文件系统上的符号链接夹具。
struct SymlinkFixture {
    let directory: String
    let target: String
    let link: String

    static func make() throws -> SymlinkFixture {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("symlink-fixture-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let target = (directory as NSString).appendingPathComponent("target.txt")
        try "hello".write(toFile: target, atomically: true, encoding: .utf8)
        let link = (directory as NSString).appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        return SymlinkFixture(directory: directory, target: target, link: link)
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}
