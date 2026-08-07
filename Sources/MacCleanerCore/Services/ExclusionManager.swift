import Foundation

/// 排除管理统一协议。App、CLI 与定时扫描都通过 `ScanResultFilter`
/// 依赖本协议，保证所有入口使用同一套排除判断。
public protocol ExclusionManaging: Sendable {
    func applyExclusions(to items: [CleanableItem], module: ModuleIdentifier) async -> [CleanableItem]
}

/// 管理排除规则的持久化和过滤逻辑
public actor ExclusionManager: ExclusionManaging {
    public static let shared = ExclusionManager()

    private var config: ExclusionConfig
    private let storePath: String

    public init(storePath: String? = nil) {
        self.storePath = storePath ?? Self.defaultStorePath()
        self.config = Self.load(from: self.storePath)
    }

    // MARK: - 规则管理

    public var rules: [ExclusionRule] {
        config.rules
    }

    public var enabledRules: [ExclusionRule] {
        config.rules.filter(\.enabled)
    }

    public func addRule(_ rule: ExclusionRule) {
        config.rules.append(rule)
        save()
    }

    public func removeRule(id: UUID) {
        config.rules.removeAll { $0.id == id }
        save()
    }

    public func updateRule(_ rule: ExclusionRule) {
        guard let index = config.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        config.rules[index] = rule
        save()
    }

    public func toggleRule(id: UUID) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
        let rule = config.rules[index]
        config.rules[index] = rule.withEnabled(!rule.enabled)
        save()
    }

    // MARK: - 过滤管道

    /// 对扫描结果应用所有启用的排除规则
    public func applyExclusions(to items: [CleanableItem], module: ModuleIdentifier) -> [CleanableItem] {
        let activeRules = enabledRules.filter { rule in
            guard let modules = rule.modules else { return true }
            return modules.contains(module.rawValue)
        }

        guard !activeRules.isEmpty else { return items }

        // 预编译所有 glob 正则，避免对每个 item 重复编译
        let compiled = activeRules.map { rule -> (ExclusionRule, NSRegularExpression?) in
            if rule.type == .pathPattern, let pattern = rule.pattern, pattern.contains("*") {
                return (rule, Self.compileGlob(pattern))
            }
            return (rule, nil)
        }

        return items.filter { item in
            !compiled.contains { (rule, regex) in shouldExclude(item: item, rule: rule, compiledRegex: regex) }
        }
    }

    /// 判断单个 item 是否应被排除
    private func shouldExclude(item: CleanableItem, rule: ExclusionRule, compiledRegex: NSRegularExpression?) -> Bool {
        switch rule.type {
        case .pathPattern:
            guard let pattern = rule.pattern else { return false }
            return matchesGlob(path: item.path, pattern: pattern, compiledRegex: compiledRegex)

        case .recency:
            guard let days = rule.days else { return false }
            return isRecentlyModified(path: item.path, withinDays: days)

        case .minSize:
            guard let minBytes = rule.minBytes else { return false }
            return item.size < minBytes

        case .permanentKeep:
            guard let keepPath = rule.pattern else { return false }
            return item.path == keepPath || item.path.hasPrefix(keepPath + "/")
        }
    }

    // MARK: - 匹配逻辑

    /// 将 glob 模式编译为 NSRegularExpression
    private static func compileGlob(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    continue
                } else {
                    regex += "[^/]*"
                }
            } else if c == "?" {
                regex += "[^/]"
            } else if ".+^${}()|[]\\".contains(c) {
                regex += "\\\(c)"
            } else {
                regex += String(c)
            }
            i = pattern.index(after: i)
        }
        regex += "$"
        return try? NSRegularExpression(pattern: regex)
    }

    /// 简单的 glob 模式匹配（支持 * 和 **），使用预编译的正则
    private func matchesGlob(path: String, pattern: String, compiledRegex: NSRegularExpression?) -> Bool {
        // 精确路径匹配
        if !pattern.contains("*") {
            return path == pattern || path.hasPrefix(pattern + "/")
        }

        guard let regex = compiledRegex else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// 检查文件是否在最近 N 天内被修改
    private func isRecentlyModified(path: String, withinDays days: Int) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date
        else { return false }

        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return modDate > cutoff
    }

    // MARK: - 持久化

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(config) else { return }

        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    private static func load(from path: String) -> ExclusionConfig {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ExclusionConfig.self, from: data)) ?? .empty
    }

    private static func defaultStorePath() -> String {
        let home = DiskScanner.homeDirectory
        return "\(home)/Library/Application Support/MacCleaner/exclusions.json"
    }
}
