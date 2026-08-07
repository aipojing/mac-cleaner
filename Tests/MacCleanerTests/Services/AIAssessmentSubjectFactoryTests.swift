import Foundation
import Testing
@testable import MacCleanerCore

extension RunningProcess {
    static func fixture(
        pid: Int32 = 4_242,
        name: String = "Example",
        path: String = "/Applications/Example.app/Contents/MacOS/Example",
        user: String = "me",
        cpuPercent: Double = 1.5,
        residentMemoryBytes: UInt64 = 50_000_000,
        elapsedSeconds: UInt64? = 3_600,
        signedByApple: Bool? = false,
        identity: ProcessIdentity? = .fixture(
            pid: 4_242,
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            startTimeTicks: 9_999,
            bundleID: "com.example.app"
        )
    ) -> RunningProcess {
        RunningProcess(
            id: pid,
            name: name,
            path: path,
            user: user,
            cpuPercent: cpuPercent,
            residentMemoryBytes: residentMemoryBytes,
            elapsedSeconds: elapsedSeconds,
            signedByApple: signedByApple,
            identity: identity
        )
    }
}

@Suite("AI assessment subject factory")
struct AIAssessmentSubjectFactoryTests {
    @Test("subject factory 不加入文件内容或旧规则")
    func subjectUsesOnlyEvidence() throws {
        let subject = try AIAssessmentSubjectFactory().cleanupSubject(for: .fixture())
        let json = String(decoding: try JSONEncoder().encode(subject), as: UTF8.self)
        // 旧判断字段名动态拼接，避免源码审计误报
        let legacyRuleField = ["rule", "Key"].joined()
        let legacyRecommendField = ["is", "Recommended"].joined()
        #expect(!json.contains(legacyRuleField))
        #expect(!json.contains(legacyRecommendField))
        #expect(!json.contains("fileContent"))
    }

    @Test("相同事实生成相同指纹，跨扫描稳定")
    func fingerprintStableForSameFacts() throws {
        let factory = AIAssessmentSubjectFactory()
        let first = try factory.cleanupSubject(for: .fixture())
        let second = try factory.cleanupSubject(for: .fixture())
        #expect(first.fingerprint == second.fingerprint)
    }

    @Test("fileIdentity 为 nil 时仍可分析，指纹与有身份对象不同")
    func nilIdentityStillAnalyzable() throws {
        let factory = AIAssessmentSubjectFactory()
        let withIdentity = try factory.cleanupSubject(for: .fixture())
        let withoutIdentity = try factory.cleanupSubject(for: .fixture(fileIdentity: nil))
        #expect(withIdentity.fingerprint != withoutIdentity.fingerprint)
        guard case .cleanup = withoutIdentity else {
            Issue.record("应生成 cleanup subject")
            return
        }
    }

    @Test("evidence 包含路径、大小、模块和事实标签")
    func evidenceCarriesFacts() throws {
        let subject = try AIAssessmentSubjectFactory().cleanupSubject(for: .fixture())
        guard case let .cleanup(_, _, evidence) = subject else {
            Issue.record("应生成 cleanup subject")
            return
        }
        #expect(evidence.path == "/tmp/cache")
        #expect(evidence.module == .developerCaches)
        #expect(evidence.tags == ["cache", "developer-tool", "npm"])
        #expect(evidence.allocatedSize == 16)
    }

    @Test("进程 subject 不发送完整参数")
    func processSubjectOmitsArguments() throws {
        let subject = try AIAssessmentSubjectFactory().processSubject(for: .fixture())
        let json = String(decoding: try JSONEncoder().encode(subject), as: UTF8.self)
        #expect(!json.contains("--token"))
        #expect(!json.contains("arguments"))
    }

    @Test("进程 subject 携带 PID、路径、用户和资源事实")
    func processSubjectCarriesFacts() throws {
        let process = RunningProcess.fixture()
        let subject = try AIAssessmentSubjectFactory().processSubject(for: process)
        guard case let .process(_, fingerprint, evidence) = subject else {
            Issue.record("应生成 process subject")
            return
        }
        #expect(!fingerprint.isEmpty)
        #expect(evidence.pid == 4_242)
        #expect(evidence.executablePath == "/Applications/Example.app/Contents/MacOS/Example")
        #expect(evidence.executableName == "Example")
        #expect(evidence.owner == "me")
        #expect(evidence.cpuPercent == 1.5)
        #expect(evidence.residentMemoryBytes == 50_000_000)
        #expect(evidence.elapsedSeconds == 3_600)
    }

    @Test("相同进程事实生成相同指纹，CPU 变化不影响身份")
    func processFingerprintStable() throws {
        let factory = AIAssessmentSubjectFactory()
        let first = try factory.processSubject(for: .fixture())
        let second = try factory.processSubject(for: .fixture(cpuPercent: 99.9))
        #expect(first.fingerprint == second.fingerprint)
    }
}

extension AIAssessmentSubjectFactoryTests {
    @Test("逻辑大小与实际占用分别取自 size 与 allocatedSize")
    func sizesComeFromDistinctFields() throws {
        let item = CleanableItem(
            path: "/tmp/nonexistent-factory-test",
            displayName: "sparse",
            size: 1_000_000,
            category: .developerCaches,
            fileIdentity: .fixture(),
            allocatedSize: 4_096
        )
        let subject = try AIAssessmentSubjectFactory().cleanupSubject(for: item)
        guard case let .cleanup(_, _, evidence) = subject else {
            Issue.record("应生成 cleanup subject")
            return
        }
        #expect(evidence.logicalSize == 1_000_000)
        #expect(evidence.allocatedSize == 4_096)
    }

    @Test("内容变化导致 mtime 变化时指纹改变，不误用旧缓存")
    func fingerprintChangesWithModificationTime() throws {
        let dir = NSTemporaryDirectory().appending("factory-mtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("data.bin")
        try Data(count: 100).write(to: URL(fileURLWithPath: path))

        let factory = AIAssessmentSubjectFactory()
        let item = CleanableItem(
            path: path, displayName: "data.bin", size: 100,
            category: .applicationCaches, fileIdentity: .fixture()
        )

        let first = try factory.cleanupSubject(for: item)
        guard case let .cleanup(_, _, firstEvidence) = first else {
            Issue.record("应生成 cleanup subject")
            return
        }
        #expect(firstEvidence.modificationTime != nil, "真实文件必须携带 mtime")

        // 大小不变地改写内容并推进 mtime
        try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: path))
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: path)

        let second = try factory.cleanupSubject(for: item)
        #expect(first.fingerprint != second.fingerprint, "mtime 变化必须产生新指纹")
    }

    @Test("路径不可读时 mtime 明确为 nil，不阻塞分析")
    func unreadablePathKeepsNilMtime() throws {
        let item = CleanableItem(
            path: "/tmp/definitely-not-exists-\(UUID().uuidString)",
            displayName: "x", size: 1,
            category: .applicationCaches, fileIdentity: .fixture()
        )
        let subject = try AIAssessmentSubjectFactory().cleanupSubject(for: item)
        guard case let .cleanup(_, _, evidence) = subject else {
            Issue.record("应生成 cleanup subject")
            return
        }
        #expect(evidence.modificationTime == nil)
    }
}
