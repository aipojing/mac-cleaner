import SwiftUI
import MacCleanerCore

/// 统一 AI 结论展示卡片。只展示解释、风险、建议和依据，
/// 不含选择控件，不触发任何执行动作。
struct AIAssessmentCard: View {
    let assessment: AIAssessment
    /// true 表示结论来自本地缓存（非本次请求）
    let fromCache: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 这是什么
            Text(assessment.summary)
                .font(.body)
                .fontWeight(.semibold)

            // 删除/终止影响
            Text(assessment.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 风险 + 建议 + 置信度（三个独立字段）
            HStack(spacing: 8) {
                labelChip(
                    text: Self.riskLabel(assessment.risk),
                    color: Self.riskColor(assessment.risk)
                )
                labelChip(
                    text: Self.recommendationLabel(assessment.recommendation),
                    color: Self.recommendationColor(assessment.recommendation)
                )
                labelChip(
                    text: "置信度 \(Self.confidenceLabel(assessment.confidence))",
                    color: .secondary
                )
            }

            // 依据
            if !assessment.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(assessment.evidence, id: \.self) { line in
                        Text("· \(line)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // 来源信息
            HStack(spacing: 6) {
                if fromCache {
                    Text("来自本地缓存")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("\(assessment.model) · \(Self.timeFormatter.string(from: assessment.assessedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("AI 结论仅供参考")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func labelChip(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - 文案映射

    static func riskLabel(_ risk: AIRiskLevel) -> String {
        switch risk {
        case .low: return "低风险"
        case .medium: return "中风险"
        case .high: return "高风险"
        case .critical: return "极高风险"
        case .unknown: return "无法判断"
        }
    }

    static func riskColor(_ risk: AIRiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .orange
        case .high, .critical: return .red
        case .unknown: return .secondary
        }
    }

    static func recommendationLabel(_ recommendation: AIRecommendation) -> String {
        switch recommendation {
        case .delete: return "AI 建议操作"
        case .keep: return "AI 建议保留"
        case .inspect: return "建议人工核查"
        case .unknown: return "AI 无法判断"
        }
    }

    static func recommendationColor(_ recommendation: AIRecommendation) -> Color {
        switch recommendation {
        case .delete: return .blue
        case .keep: return .green
        case .inspect: return .orange
        case .unknown: return .secondary
        }
    }

    static func confidenceLabel(_ confidence: AIConfidence) -> String {
        switch confidence {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
