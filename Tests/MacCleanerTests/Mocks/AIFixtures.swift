import Foundation
@testable import MacCleanerCore

extension AIAssessment {
    static func fixture(
        subjectID: String = "cleanup:fixture",
        fingerprint: String = String(repeating: "a", count: 64),
        summary: String = "缓存目录",
        explanation: String = "应用生成的缓存数据，删除后应用会按需重建。",
        risk: AIRiskLevel = .low,
        recommendation: AIRecommendation = .delete,
        confidence: AIConfidence = .medium,
        evidence: [String] = ["位于 Library/Caches 下"],
        model: String = "deepseek-v4-pro",
        assessedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> AIAssessment {
        try AIAssessment(
            subjectID: subjectID,
            fingerprint: fingerprint,
            summary: summary,
            explanation: explanation,
            risk: risk,
            recommendation: recommendation,
            confidence: confidence,
            evidence: evidence,
            model: model,
            assessedAt: assessedAt
        )
    }
}

extension CleanupAIEvidence {
    static func fixture(
        path: String = "/Users/me/Library/Caches/example",
        objectKind: FileObjectKind = .directory,
        logicalSize: UInt64 = 1_024,
        allocatedSize: UInt64 = 4_096,
        modificationTime: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        module: ModuleIdentifier = .applicationCaches,
        tags: [String] = ["cache"]
    ) -> CleanupAIEvidence {
        CleanupAIEvidence(
            path: path,
            objectKind: objectKind,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            modificationTime: modificationTime,
            module: module,
            tags: tags
        )
    }
}

extension ProcessAIEvidence {
    static func fixture(
        pid: Int32 = 4_242,
        executablePath: String = "/Applications/Example.app/Contents/MacOS/Example",
        executableName: String = "Example",
        bundleIdentifier: String? = "com.example.app",
        owner: String = "me",
        cpuPercent: Double = 1.5,
        residentMemoryBytes: UInt64 = 50_000_000,
        elapsedSeconds: UInt64? = 3_600,
        signedByApple: Bool? = false
    ) -> ProcessAIEvidence {
        ProcessAIEvidence(
            pid: pid,
            executablePath: executablePath,
            executableName: executableName,
            bundleIdentifier: bundleIdentifier,
            owner: owner,
            cpuPercent: cpuPercent,
            residentMemoryBytes: residentMemoryBytes,
            elapsedSeconds: elapsedSeconds,
            signedByApple: signedByApple
        )
    }
}

extension AIAssessmentSubject {
    static func cleanupFixture(
        id: String = "cleanup:fixture",
        fingerprint: String = String(repeating: "a", count: 64),
        evidence: CleanupAIEvidence = .fixture()
    ) -> AIAssessmentSubject {
        .cleanup(id: id, fingerprint: fingerprint, evidence: evidence)
    }

    static func processFixture(
        id: String = "process:fixture",
        fingerprint: String = String(repeating: "b", count: 64),
        evidence: ProcessAIEvidence = .fixture()
    ) -> AIAssessmentSubject {
        .process(id: id, fingerprint: fingerprint, evidence: evidence)
    }
}
