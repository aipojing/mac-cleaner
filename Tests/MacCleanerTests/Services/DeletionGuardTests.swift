import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Deletion guard")
struct DeletionGuardTests {
    private func makeGuard(
        allowedRoots: [String],
        identity: FileIdentity? = nil,
        exists: Bool = true,
        protectedExact: [String] = ["/", "/Users/test"],
        protectedSubtrees: [String] = ["/System", "/usr/bin", "/usr/lib", "/bin", "/sbin"]
    ) -> DeletionGuard {
        DeletionGuard(
            allowedRoots: allowedRoots,
            identityProvider: StubFileIdentityProvider(exists: exists, identity: identity),
            protectedExactPaths: protectedExact,
            protectedSubtrees: protectedSubtrees
        )
    }

    @Test("拒绝根目录和用户主目录")
    func rejectsBroadRoots() throws {
        let guardrail = makeGuard(allowedRoots: ["/Users/test/Library/Caches"])

        #expect(throws: DeletionGuardError.self) {
            try guardrail.validate(path: "/", expectedIdentity: nil)
        }
        #expect(throws: DeletionGuardError.self) {
            try guardrail.validate(path: "/Users/test", expectedIdentity: nil)
        }
    }

    @Test("目标不存在时拒绝")
    func rejectsMissingTarget() throws {
        let guardrail = makeGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests"],
            exists: false
        )
        #expect(throws: DeletionGuardError.targetMissing) {
            try guardrail.validate(path: "/tmp/mac-cleaner-tests/gone", expectedIdentity: nil)
        }
    }

    @Test("拒绝扫描后 inode 已变化的目标")
    func rejectsChangedIdentity() throws {
        let old = FileIdentity(device: 1, inode: 10, kind: .regularFile)
        let current = FileIdentity(device: 1, inode: 11, kind: .regularFile)
        let guardrail = DeletionGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests"],
            identityProvider: StubFileIdentityProvider(identity: current),
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System", "/usr/bin", "/usr/lib", "/bin", "/sbin"]
        )

        #expect(throws: DeletionGuardError.identityChanged) {
            try guardrail.validate(
                path: "/tmp/mac-cleaner-tests/cache.bin",
                expectedIdentity: old
            )
        }
    }

    @Test("拒绝最终路径为符号链接")
    func rejectsSymbolicLink() throws {
        let guardrail = DeletionGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests"],
            identityProvider: StubFileIdentityProvider(
                identity: FileIdentity(device: 1, inode: 10, kind: .symbolicLink)
            ),
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System", "/usr/bin", "/usr/lib", "/bin", "/sbin"]
        )

        #expect(throws: DeletionGuardError.symbolicLink) {
            try guardrail.validate(
                path: "/tmp/mac-cleaner-tests/link",
                expectedIdentity: nil
            )
        }
    }

    @Test("身份缺失时拒绝执行")
    func rejectsUnavailableIdentity() throws {
        let current = FileIdentity(device: 1, inode: 10, kind: .regularFile)
        let guardrail = DeletionGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests"],
            identityProvider: StubFileIdentityProvider(identity: current),
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System"]
        )
        #expect(throws: DeletionGuardError.identityUnavailable) {
            try guardrail.validate(
                path: "/tmp/mac-cleaner-tests/cache.bin",
                expectedIdentity: nil
            )
        }
    }

    @Test("超出允许根目录时拒绝")
    func rejectsOutsideAllowedRoots() throws {
        let current = FileIdentity(device: 1, inode: 10, kind: .regularFile)
        let guardrail = DeletionGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests/allowed"],
            identityProvider: StubFileIdentityProvider(identity: current),
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System"]
        )
        #expect(throws: DeletionGuardError.outsideAllowedRoots) {
            try guardrail.validate(
                path: "/tmp/mac-cleaner-tests/elsewhere/cache.bin",
                expectedIdentity: current
            )
        }
    }

    @Test("路径组件边界：相邻目录不命中允许根")
    func componentBoundary() throws {
        let current = FileIdentity(device: 1, inode: 10, kind: .regularFile)
        let guardrail = DeletionGuard(
            allowedRoots: ["/Users/a/Library/Caches"],
            identityProvider: StubFileIdentityProvider(identity: current),
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System"]
        )
        // /Users/a/Library/Caches2 不能命中 /Users/a/Library/Caches
        #expect(throws: DeletionGuardError.outsideAllowedRoots) {
            try guardrail.validate(
                path: "/Users/a/Library/Caches2/x",
                expectedIdentity: current
            )
        }
    }

    @Test("合法目标通过验证并返回身份")
    func allowsValidTarget() throws {
        let identity = FileIdentity(device: 1, inode: 10, kind: .regularFile)
        let guardrail = DeletionGuard(
            allowedRoots: ["/tmp/mac-cleaner-tests"],
            identityProvider: StubFileIdentityProvider(identity: identity),
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System"]
        )
        let result = try guardrail.validate(
            path: "/tmp/mac-cleaner-tests/cache.bin",
            expectedIdentity: identity
        )
        #expect(result == identity)
    }

    @Test("validatedTarget 返回解析符号链接父目录后的规范化路径")
    func validatedTargetReturnsCanonicalPath() throws {
        let fm = FileManager.default
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("guard-canonical-\(UUID().uuidString)")
        let real = (base as NSString).appendingPathComponent("real")
        try fm.createDirectory(atPath: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: base) }
        let file = (real as NSString).appendingPathComponent("cache.bin")
        fm.createFile(atPath: file, contents: Data(count: 8))
        let alias = (base as NSString).appendingPathComponent("alias")
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: real)

        let provider = POSIXFileIdentityProvider()
        let identity = try provider.identity(at: file)
        let guardrail = DeletionGuard(
            allowedRoots: [real],
            identityProvider: provider,
            protectedExactPaths: ["/"],
            protectedSubtrees: ["/System"]
        )

        let target = try guardrail.validatedTarget(
            path: (alias as NSString).appendingPathComponent("cache.bin"),
            expectedIdentity: identity
        )
        #expect(target.identity == identity)
        // canonicalPath 必须指向解析符号链接后的真实位置
        #expect(target.canonicalPath == provider.resolvedPath(file))
        #expect(!target.canonicalPath.contains("/alias/"))
    }
}
