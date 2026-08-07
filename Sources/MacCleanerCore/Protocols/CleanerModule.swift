import Foundation

public protocol CleanerModule: Sendable {
    var identifier: ModuleIdentifier { get }
    var displayName: String { get }
    var description: String { get }

    /// 通过共享上下文扫描：元数据读取和文件任务并发由 context 统一协调。
    func scan(context: ScanContext) async throws -> ScanResult
    func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport
    func isAvailable() -> Bool
}
