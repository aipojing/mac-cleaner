import Testing
import Foundation
@testable import MacCleanerCore

/// 测试专用策略目录：只允许测试临时目录。
struct TestDeletionPolicyCatalog: DeletionPolicyProviding {
    let allowedRoots: [String]

    func policy(for module: ModuleIdentifier) -> DeletionPolicy {
        DeletionPolicy(
            allowedRoots: allowedRoots,
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System", "/usr/bin", "/usr/lib", "/bin", "/sbin"]
        )
    }
}

@Suite("Deleter Tests")
struct DeleterTests {
    private let identityProvider = POSIXFileIdentityProvider()

    private func createTempDir() -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("deleter-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func createTempFile(in dir: String? = nil, name: String = "test.txt", size: Int64 = 1024) -> String {
        let base = dir ?? createTempDir()
        let filePath = (base as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: filePath, contents: Data(count: Int(size)))
        return filePath
    }

    private func cleanupPath(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeDeleter(allowedRoots: [String]) -> Deleter {
        Deleter(policyCatalog: TestDeletionPolicyCatalog(allowedRoots: allowedRoots))
    }

    /// 带真实身份的条目：模拟扫描阶段记录了身份。
    private func makeItem(
        path: String, size: Int64,
        recordIdentity: Bool = true
    ) -> CleanableItem {
        CleanableItem(
            path: path,
            displayName: "Test",
            size: size,
            category: .developerCaches,
            fileIdentity: recordIdentity ? try? identityProvider.identity(at: path) : nil
        )
    }

    @Test("Deleter verifies file is gone after deletion")
    func verifiesAfterDelete() throws {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let path = createTempFile(in: dir)

        let item = makeItem(path: path, size: 1024)
        let report = makeDeleter(allowedRoots: [dir]).delete(
            items: [item], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.successCount == 1)
        #expect(report.failureCount == 0)
        #expect(report.deletedItems.first?.verified == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Deleter reports notFound for missing files")
    func reportsNotFound() {
        let item = makeItem(
            path: "/tmp/nonexistent-\(UUID().uuidString)/file.txt",
            size: 500,
            recordIdentity: false
        )
        let report = makeDeleter(allowedRoots: ["/tmp"]).delete(
            items: [item], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.failureCount == 1)
        #expect(report.successCount == 0)
        #expect(report.failedItems.first?.reason == .notFound)
    }

    @Test("Dry run does not delete files")
    func dryRunPreservesFiles() {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let path = createTempFile(in: dir)

        let item = makeItem(path: path, size: 1024)
        let report = makeDeleter(allowedRoots: [dir]).delete(
            items: [item], module: .developerCaches,
            dryRun: true, useTrash: false
        )

        #expect(report.successCount == 1)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Report tracks expected vs actual size")
    func tracksExpectedVsActual() {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let path = createTempFile(in: dir, size: 2048)

        let item = makeItem(path: path, size: 2048)
        let report = makeDeleter(allowedRoots: [dir]).delete(
            items: [item], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.expectedSize == 2048)
        #expect(report.actualFreed == 2048)
        #expect(report.discrepancy == 0)
    }

    @Test("Report has discrepancy when some items fail")
    func discrepancyOnPartialFailure() {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let path = createTempFile(in: dir, size: 1024)

        let goodItem = makeItem(path: path, size: 1024)
        let badItem = makeItem(
            path: "/tmp/nonexistent-\(UUID().uuidString)",
            size: 2048,
            recordIdentity: false
        )
        let report = makeDeleter(allowedRoots: [dir, "/tmp"]).delete(
            items: [goodItem, badItem], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.expectedSize == 3072)
        #expect(report.actualFreed == 1024)
        #expect(report.discrepancy == 2048)
    }

    @Test("Progress callback is called for each item")
    func progressCallback() {
        let items = (0..<3).map { i in
            makeItem(path: "/tmp/fake-\(i)", size: 100, recordIdentity: false)
        }

        let progressBox = ProgressBox()
        let sendableProgress: @Sendable (String, Int, Int) -> Void = { name, current, total in
            progressBox.record(name: name, current: current, total: total)
        }
        _ = makeDeleter(allowedRoots: ["/tmp"]).delete(
            items: items, module: .developerCaches,
            dryRun: true, useTrash: false,
            onProgress: sendableProgress
        )

        let calls = progressBox.calls
        #expect(calls.count == 3)
        #expect(calls[0].1 == 1)
        #expect(calls[2].1 == 3)
        #expect(calls[0].2 == 3)
    }

    @Test("身份缺失的目标被拒绝执行")
    func rejectsMissingIdentity() {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let path = createTempFile(in: dir)

        let item = makeItem(path: path, size: 1024, recordIdentity: false)
        let report = makeDeleter(allowedRoots: [dir]).delete(
            items: [item], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.successCount == 0)
        #expect(report.failureCount == 1)
        #expect(report.failedItems.first?.reason == .identityUnavailable)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("扫描后 inode 变化的目标被拒绝")
    func rejectsChangedIdentity() {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let path = createTempFile(in: dir)

        // 模拟扫描时记录的身份与当前不同（inode 已被替换）
        let stale = FileIdentity(device: 999_999, inode: 42, kind: .regularFile)
        let item = CleanableItem(
            path: path, displayName: "Stale", size: 1024,
            category: .developerCaches, fileIdentity: stale
        )
        let report = makeDeleter(allowedRoots: [dir]).delete(
            items: [item], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.successCount == 0)
        #expect(report.failureCount == 1)
        #expect(report.failedItems.first?.reason == .identityChanged)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("符号链接目标被拒绝")
    func rejectsSymlink() throws {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let target = createTempFile(in: dir, name: "target.txt")
        let link = (dir as NSString).appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: target
        )

        let identity = try identityProvider.identity(at: link)
        let item = CleanableItem(
            path: link, displayName: "Link", size: 1024,
            category: .developerCaches, fileIdentity: identity
        )
        let report = makeDeleter(allowedRoots: [dir]).delete(
            items: [item], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.successCount == 0)
        #expect(report.failureCount == 1)
        #expect(report.failedItems.first?.reason == .unsafeTarget)
        // 链接与目标都必须还在
        #expect(FileManager.default.fileExists(atPath: link))
        #expect(FileManager.default.fileExists(atPath: target))
    }

    @Test("超出允许根目录的目标被拒绝")
    func rejectsOutsideAllowedRoots() {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let outside = createTempDir()
        defer { cleanupPath(outside) }
        let path = createTempFile(in: outside)

        let item = makeItem(path: path, size: 1024)
        // 只允许 dir，不允许 outside
        let report = makeDeleter(allowedRoots: [dir]).delete(
            items: [item], module: .developerCaches,
            dryRun: false, useTrash: false
        )

        #expect(report.successCount == 0)
        #expect(report.failureCount == 1)
        #expect(report.failedItems.first?.reason == .unsafeTarget)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("dry-run 也执行安全校验并报告拒绝")
    func dryRunValidatesToo() {
        let item = makeItem(path: "/tmp/fake-\(UUID().uuidString)", size: 100, recordIdentity: false)
        let report = makeDeleter(allowedRoots: ["/tmp"]).delete(
            items: [item], module: .developerCaches,
            dryRun: true, useTrash: false
        )
        #expect(report.successCount == 0)
        #expect(report.failureCount == 1)
    }
}

/// 线程安全的进度记录盒。
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, Int, Int)] = []

    func record(name: String, current: Int, total: Int) {
        lock.lock()
        storage.append((name, current, total))
        lock.unlock()
    }

    var calls: [(String, Int, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("FailedItem Classification Tests")
struct FailedItemClassificationTests {

    @Test("Classifies permission errors")
    func classifiesPermission() {
        let item = FailedItem(path: "/test", error: "Operation not permitted")
        #expect(item.reason == .permissionDenied)

        let item2 = FailedItem(path: "/test", error: "Permission denied")
        #expect(item2.reason == .permissionDenied)
    }

    @Test("Classifies file-in-use errors")
    func classifiesInUse() {
        let item = FailedItem(path: "/test", error: "Resource busy")
        #expect(item.reason == .fileInUse)
    }

    @Test("Classifies not-found errors")
    func classifiesNotFound() {
        let item = FailedItem(path: "/test", error: "No such file or directory")
        #expect(item.reason == .notFound)
    }

    @Test("Unknown errors classified as unknown")
    func classifiesUnknown() {
        let item = FailedItem(path: "/test", error: "Something weird happened")
        #expect(item.reason == .unknown)
    }

    @Test("FailureReason has localized descriptions")
    func localizedDescriptions() {
        for reason in [
            FailureReason.permissionDenied, .fileInUse, .notFound, .diskFull,
            .unsafeTarget, .identityChanged, .identityUnavailable, .unknown,
        ] {
            #expect(!reason.localizedDescription.isEmpty)
        }
    }
}

@Suite("CleanupReport Tests")
struct CleanupReportTests {

    @Test("Report computes totals from deleted items")
    func computesTotals() {
        let report = CleanupReport(
            module: .developerCaches,
            deletedItems: [
                CleanedItem(path: "/a", expectedSize: 100, actualFreed: 100, verified: true),
                CleanedItem(path: "/b", expectedSize: 200, actualFreed: 200, verified: true),
            ]
        )
        #expect(report.totalFreed == 300)
        #expect(report.expectedSize == 300)
    }

    @Test("hasPermissionFailures detects permission errors")
    func detectsPermissions() {
        let report = CleanupReport(
            module: .developerCaches,
            failedItems: [
                FailedItem(path: "/x", error: "denied", reason: .permissionDenied),
            ]
        )
        #expect(report.hasPermissionFailures)
    }

    @Test("No permission failures when only other errors")
    func noPermissionFailures() {
        let report = CleanupReport(
            module: .developerCaches,
            failedItems: [
                FailedItem(path: "/x", error: "busy", reason: .fileInUse),
            ]
        )
        #expect(!report.hasPermissionFailures)
    }
}

/// 可脚本化身份提供者：前 successCalls 次 identity 返回 first，之后返回 second，
/// 用于模拟「校验通过后、真正删除前目标被替换」的竞态。
final class FlipFlopIdentityProvider: FileIdentityProviding, @unchecked Sendable {
    private let posix = POSIXFileIdentityProvider()
    private let first: FileIdentity
    private let second: FileIdentity
    private(set) var identityCalls = 0

    init(first: FileIdentity, second: FileIdentity) {
        self.first = first
        self.second = second
    }

    func exists(at path: String) -> Bool { posix.exists(at: path) }

    func identity(at path: String) throws -> FileIdentity {
        identityCalls += 1
        return identityCalls <= 1 ? first : second
    }

    func canonicalParent(of path: String) throws -> String {
        try posix.canonicalParent(of: path)
    }

    func resolvedPath(_ path: String) -> String {
        posix.resolvedPath(path)
    }
}

extension DeleterTests {
    @Test("校验与删除之间目标被替换时，执行前的再次校验拒绝删除")
    func revalidationRejectsReplacedTarget() throws {
        let dir = createTempDir()
        defer { cleanupPath(dir) }
        let filePath = createTempFile(in: dir)

        let scanned = try POSIXFileIdentityProvider().identity(at: filePath)
        let replaced = FileIdentity(device: scanned.device, inode: scanned.inode + 1, kind: scanned.kind)
        let provider = FlipFlopIdentityProvider(first: scanned, second: replaced)
        let deleter = Deleter(
            policyCatalog: TestDeletionPolicyCatalog(allowedRoots: [dir]),
            identityProvider: provider
        )
        let item = CleanableItem(
            path: filePath, displayName: "t", size: 1024,
            category: .developerCaches, fileIdentity: scanned
        )

        let report = deleter.delete(items: [item], module: .developerCaches, dryRun: false, useTrash: false)

        #expect(report.successCount == 0)
        #expect(report.failedItems.first?.reason == .identityChanged)
        #expect(FileManager.default.fileExists(atPath: filePath), "身份变化时不得删除目标")
    }
}
