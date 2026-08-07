import Foundation
import MacCleanerCore

/// 搜索性能门槛：10,000 条合成文档、20 个固定查询。
/// p95 不超过 100 ms 且两轮结果顺序一致，否则 exit(1)。

// MARK: - 固定 seed 伪随机（LCG，保证两次运行生成相同文档）

struct LcgRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11
    }

    mutating func pick<T>(_ array: [T]) -> T {
        array[Int(next() % UInt64(array.count))]
    }

    mutating func int(_ upper: Int) -> Int {
        Int(next() % UInt64(upper))
    }
}

// MARK: - 合成文档

let basenames = [
    "npm", "Cache", "DerivedData", "gradle", "Docker.raw", "photo",
    "报告", "缓存", "build", "node_modules", "backup", "日志",
]
let dirs = ["Caches", "Developer", "Library", "Documents", "tmp", "Downloads", "构建", "应用"]
let tagPool = ["cache", "developer-tool", "npm", "large-file", "log", "开发工具缓存", "应用缓存", "docker"]
let aiSnippets = ["图像处理服务", "构建产物缓存", "system cache data", "可安全删除的临时文件", nil, nil]
let risks: [AIRiskLevel?] = [.low, .medium, .high, .unknown, nil, nil]
let recommendations: [AIRecommendation?] = [.delete, .inspect, .keep, .unknown, nil, nil]
let confidences: [AIConfidence?] = [.low, .medium, .high, nil]
let statuses: [AssessmentStatus] = AssessmentStatus.allCases
let modules: [ModuleIdentifier?] = ModuleIdentifier.allCases.map { $0 as ModuleIdentifier? } + [nil]

func makeDocuments(count: Int, seed: UInt64) -> [SearchDocument] {
    var rng = LcgRandom(seed: seed)
    return (0..<count).map { index in
        let basename = rng.pick(basenames) + (rng.int(4) == 0 ? "\(index)" : "")
        let path = "/\(rng.pick(dirs))/\(rng.pick(dirs))/\(basename)"
        let tags = (0...rng.int(3)).map { _ in rng.pick(tagPool) }
        return SearchDocument(
            id: "doc-\(index)",
            basename: basename,
            path: path,
            tags: tags,
            bundleIdentifier: rng.int(5) == 0 ? "com.example.\(rng.int(1_000))" : nil,
            aiText: rng.pick(aiSnippets),
            module: rng.pick(modules),
            allocatedSize: Int64(rng.next() % 10_000_000_000),
            risk: rng.pick(risks),
            recommendation: rng.pick(recommendations),
            confidence: rng.pick(confidences),
            assessmentStatus: rng.pick(statuses)
        )
    }
}

let queries = [
    "npm", "cache", "构建", "缓存", "docker", "photo", "DerivedData",
    "报告", "log", "backup", "图像处理", "system cache", "build 产物",
    "开发 缓存", "Library", "gradle", "临时文件", "node", "raw", "不存在的词xyz",
]

// MARK: - 运行

let documents = makeDocuments(count: 10_000, seed: 42)
let engine = ResultSearchEngine(documents: documents)

// 预热 5 次
for _ in 0..<5 {
    for query in queries {
        _ = engine.search(.init(text: query))
    }
}

var durations: [Double] = []
var firstRun: [[String]] = []
var stableOrder = true

for round in 0..<2 {
    var roundResults: [[String]] = []
    for query in queries {
        let start = ContinuousClock.now
        let results = engine.search(.init(text: query))
        let elapsed = ContinuousClock.now - start
        if round == 1 {
            // attoseconds → 毫秒：1 ms = 1e15 attoseconds
            durations.append(Double(elapsed.components.attoseconds) / 1e15)
        }
        roundResults.append(results.map(\.id))
    }
    if round == 0 {
        firstRun = roundResults
    } else if roundResults != firstRun {
        stableOrder = false
    }
}

durations.sort()
func percentile(_ p: Double) -> Double {
    guard !durations.isEmpty else { return 0 }
    let index = min(durations.count - 1, Int((p * Double(durations.count)).rounded(.up)) - 1)
    return durations[max(0, index)]
}

let p50 = percentile(0.50)
let p95 = percentile(0.95)

func format(_ ms: Double) -> String {
    String(format: "%.3f", ms)
}

print("""
{"documents":\(documents.count),"queries":\(queries.count),"p50_ms":\(format(p50)),"p95_ms":\(format(p95)),"stable_order":\(stableOrder)}
""")

if p95 > 100 || !stableOrder {
    exit(1)
}
