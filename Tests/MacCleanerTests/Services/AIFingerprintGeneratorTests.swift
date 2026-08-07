import Foundation
import Testing
@testable import MacCleanerCore

@Suite("AI fingerprint generator")
struct AIFingerprintGeneratorTests {
    @Test("相同字段顺序无关且指纹稳定")
    func deterministicCleanupFingerprint() throws {
        let generator = AIFingerprintGenerator()
        let first = try generator.cleanupFingerprint(.fixture(tags: ["cache", "npm"]))
        let second = try generator.cleanupFingerprint(.fixture(tags: ["npm", "cache"]))
        #expect(first == second)
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
    }

    @Test("重复 tags 不改变指纹")
    func duplicateTagsAreIgnored() throws {
        let generator = AIFingerprintGenerator()
        let first = try generator.cleanupFingerprint(.fixture(tags: ["cache", "npm"]))
        let second = try generator.cleanupFingerprint(.fixture(tags: ["cache", "cache", "npm"]))
        #expect(first == second)
    }

    @Test("大小、mtime 或 inode 改变会使实例指纹失效")
    func cleanupInstanceChangesInvalidate() throws {
        let generator = AIFingerprintGenerator()
        let first = try generator.cleanupFingerprint(.fixture(inode: 1, allocatedSize: 10))
        let second = try generator.cleanupFingerprint(.fixture(inode: 2, allocatedSize: 10))
        let third = try generator.cleanupFingerprint(.fixture(inode: 1, allocatedSize: 11))
        let fourth = try generator.cleanupFingerprint(
            .fixture(inode: 1, allocatedSize: 10, modificationTime: Date(timeIntervalSince1970: 2))
        )
        #expect(first != second)
        #expect(first != third)
        #expect(first != fourth)
    }

    @Test("进程启动时间变化会使 PID 指纹失效")
    func processRestartInvalidatesFingerprint() throws {
        let generator = AIFingerprintGenerator()
        #expect(
            try generator.processFingerprint(.fixture(startTimeTicks: 1)) !=
                generator.processFingerprint(.fixture(startTimeTicks: 2))
        )
    }

    @Test("相同进程事实指纹稳定")
    func processFingerprintIsStable() throws {
        let generator = AIFingerprintGenerator()
        let first = try generator.processFingerprint(.fixture())
        let second = try generator.processFingerprint(.fixture())
        #expect(first == second)
    }
}

private extension CleanupFingerprintInput {
    static func fixture(
        path: String = "/Users/me/Library/Caches/example",
        device: UInt64 = 16_777_216,
        inode: UInt64 = 42,
        objectKind: FileObjectKind = .directory,
        allocatedSize: UInt64 = 4_096,
        modificationTime: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        module: ModuleIdentifier = .applicationCaches,
        tags: [String] = ["cache"]
    ) -> CleanupFingerprintInput {
        CleanupFingerprintInput(
            path: path,
            device: device,
            inode: inode,
            objectKind: objectKind,
            allocatedSize: allocatedSize,
            modificationTime: modificationTime,
            module: module,
            tags: tags
        )
    }
}

private extension ProcessFingerprintInput {
    static func fixture(
        pid: Int32 = 4_242,
        executablePath: String = "/Applications/Example.app/Contents/MacOS/Example",
        bundleIdentifier: String? = "com.example.app",
        startTimeTicks: UInt64 = 9_999,
        signedByApple: Bool? = false
    ) -> ProcessFingerprintInput {
        ProcessFingerprintInput(
            pid: pid,
            executablePath: executablePath,
            bundleIdentifier: bundleIdentifier,
            startTimeTicks: startTimeTicks,
            signedByApple: signedByApple
        )
    }
}
