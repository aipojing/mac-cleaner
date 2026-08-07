import Testing
@testable import MacCleanerCore

@Suite("Deletion policy catalog")
struct DeletionPolicyCatalogTests {
    private let catalog = DeletionPolicyCatalog(home: "/Users/test")

    @Test("每个模块都有非空且不含 / 的允许根目录")
    func everyModuleHasNonEmptyRoots() {
        for module in ModuleIdentifier.allCases {
            let policy = catalog.policy(for: module)
            #expect(!policy.allowedRoots.isEmpty, "\(module) 允许根为空")
            #expect(
                !policy.allowedRoots.contains("/"),
                "\(module) 允许根包含 /"
            )
        }
    }

    @Test("受保护基线至少包含 / 、home 与系统目录")
    func protectedBaseline() {
        let policy = catalog.policy(for: .systemLogs)
        #expect(policy.protectedExactPaths.contains("/"))
        #expect(policy.protectedExactPaths.contains("/Users/test"))
        for subtree in ["/System", "/usr/bin", "/usr/lib", "/usr/sbin", "/usr/share", "/bin", "/sbin", "/private/var/db"] {
            #expect(policy.protectedSubtrees.contains(subtree), "缺少受保护子树 \(subtree)")
        }
    }

    @Test("Docker contexts 不在任何允许根中")
    func dockerContextsNotAllowed() {
        for module in ModuleIdentifier.allCases {
            let policy = catalog.policy(for: module)
            #expect(
                !policy.allowedRoots.contains("/Users/test/.docker/contexts"),
                "\(module) 允许根包含 docker contexts"
            )
        }
    }

    @Test("大文件与重复文件允许 home 后代，但 home 本身受保护")
    func homeDescendantsAllowedButHomeProtected() {
        for module in [ModuleIdentifier.largeFiles, .duplicateFiles] {
            let policy = catalog.policy(for: module)
            #expect(policy.allowedRoots.contains("/Users/test"))
            #expect(policy.protectedExactPaths.contains("/Users/test"))
        }
    }

    @Test("日志模块允许根限定在 Library/Logs")
    func systemLogsRoots() {
        let policy = catalog.policy(for: .systemLogs)
        #expect(policy.allowedRoots.contains("/Users/test/Library/Logs"))
        #expect(policy.allowedRoots.contains("/Users/test/Library/Logs/DiagnosticReports"))
    }
}
