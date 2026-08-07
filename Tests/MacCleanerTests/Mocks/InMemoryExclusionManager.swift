import Foundation
@testable import MacCleanerCore

/// 内存版排除管理器：用于测试，不触碰真实文件系统与持久化。
struct InMemoryExclusionManager: ExclusionManaging {
    private let excludedPaths: Set<String>
    private let patterns: [String]

    init(excludedPaths: Set<String> = [], patterns: [String] = []) {
        self.excludedPaths = excludedPaths
        self.patterns = patterns
    }

    func applyExclusions(to items: [CleanableItem], module: ModuleIdentifier) async -> [CleanableItem] {
        items.filter { item in
            let pathExcluded = excludedPaths.contains { excluded in
                item.path == excluded || item.path.hasPrefix(excluded + "/")
            }
            guard !pathExcluded else { return false }
            for pattern in patterns where pattern.contains("*") {
                let regex = Self.compileGlob(pattern)
                if let regex,
                   regex.firstMatch(in: item.path, range: NSRange(item.path.startIndex..., in: item.path)) != nil {
                    return false
                }
            }
            return true
        }
    }

    private static func compileGlob(_ pattern: String) -> NSRegularExpression? {
        var regex = "^"
        for c in pattern {
            if c == "*" {
                regex += "[^/]*"
            } else if c == "?" {
                regex += "[^/]"
            } else if ".+^${}()|[]\\".contains(c) {
                regex += "\\\(c)"
            } else {
                regex += String(c)
            }
        }
        regex += "$"
        return try? NSRegularExpression(pattern: regex)
    }
}
