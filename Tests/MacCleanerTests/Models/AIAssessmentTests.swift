import Foundation
import Testing
@testable import MacCleanerCore

@Suite("AI assessment models")
struct AIAssessmentTests {
    @Test("风险与建议互不推导")
    func riskAndRecommendationAreIndependent() throws {
        let value = try AIAssessment.fixture(risk: .high, recommendation: .keep)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AIAssessment.self, from: encoded)

        #expect(decoded.risk == .high)
        #expect(decoded.recommendation == .keep)
    }

    @Test("清理事实不包含文件内容字段")
    func cleanupEvidenceContainsMetadataOnly() throws {
        let subject = AIAssessmentSubject.cleanup(
            id: "cleanup:1",
            fingerprint: "abc",
            evidence: CleanupAIEvidence(
                path: "/Users/me/Library/Caches/x",
                objectKind: .directory,
                logicalSize: 10,
                allocatedSize: 16,
                modificationTime: Date(timeIntervalSince1970: 1),
                module: .applicationCaches,
                tags: ["cache"]
            )
        )
        let json = String(decoding: try JSONEncoder().encode(subject), as: UTF8.self)

        #expect(!json.contains("fileContent"))
        #expect(!json.contains("environment"))
        #expect(!json.contains("arguments"))
    }

    @Test("subject 编码带判别字段且只包含对应 evidence")
    func subjectEncodingHasDiscriminator() throws {
        let cleanup = AIAssessmentSubject.cleanupFixture()
        let cleanupJSON = String(decoding: try JSONEncoder().encode(cleanup), as: UTF8.self)
        #expect(cleanupJSON.contains("\"kind\":\"cleanup\""))
        #expect(cleanupJSON.contains("cleanup:"))
        #expect(!cleanupJSON.contains("residentMemoryBytes"))

        let process = AIAssessmentSubject.processFixture()
        let processJSON = String(decoding: try JSONEncoder().encode(process), as: UTF8.self)
        #expect(processJSON.contains("\"kind\":\"process\""))
        #expect(!processJSON.contains("logicalSize"))
    }

    @Test("字段长度约束由初始化器保证")
    func fieldLengthConstraints() throws {
        #expect(throws: AssessmentValidationError.self) {
            _ = try AIAssessment.fixture(summary: "")
        }
        #expect(throws: AssessmentValidationError.self) {
            _ = try AIAssessment.fixture(evidence: [])
        }
        #expect(throws: AssessmentValidationError.self) {
            _ = try AIAssessment.fixture(summary: String(repeating: "x", count: 81))
        }
        _ = try AIAssessment.fixture(summary: String(repeating: "x", count: 80))
    }

    @Test("视图状态只暴露缓存或新鲜结果")
    func stateExposesAssessment() throws {
        let value = try AIAssessment.fixture()
        #expect(AIAssessmentState.cached(value).assessment == value)
        #expect(AIAssessmentState.fresh(value).assessment == value)
        #expect(AIAssessmentState.loading(previous: value).assessment == value)
        #expect(AIAssessmentState.failed(message: "x", previous: value).assessment == value)
        #expect(AIAssessmentState.notConfigured.assessment == nil)
        #expect(AIAssessmentState.notAnalyzed.assessment == nil)
    }
}
