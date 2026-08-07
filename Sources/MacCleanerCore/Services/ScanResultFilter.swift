import Foundation

/// 统一排除过滤器：App、CLI 与定时扫描的唯一过滤入口。
/// 模块扫描结果产生后立即调用，保证所有入口使用同一套排除判断。
public struct ScanResultFilter: Sendable {
    private let exclusionManager: any ExclusionManaging

    public init(exclusionManager: any ExclusionManaging) {
        self.exclusionManager = exclusionManager
    }

    /// 对扫描结果应用排除规则，保留模块信息与扫描耗时
    public func apply(to result: ScanResult) async -> ScanResult {
        let kept = await exclusionManager.applyExclusions(to: result.items, module: result.module)
        return ScanResult(
            module: result.module,
            items: kept,
            scanDuration: result.scanDuration
        )
    }
}
