import Foundation

/// 清理项选择策略。
///
/// 产品原则：所有扫描结果默认不选中；只有用户主动操作（逐项勾选、模块全选、
/// 全选可清理项）才会改变选择状态。AI 结论、缓存结果或任何自动流程都不得
/// 调用本策略之外的路径修改选择状态。
public enum CleanupSelectionPolicy {
    /// 扫描完成后的初始选择：永远为空集合。
    public static func initialSelection(from items: [CleanableItem]) -> Set<UUID> {
        _ = items
        return []
    }

    /// 用户主动触发“全选”时，只选择通过本地可执行性检查的项。
    ///
    /// `isEligible` 由调用方注入（例如排除本地安全 guard 判定为不可执行的目标），
    /// 本策略不做任何风险或推荐判断。
    public static func selectAll(
        from items: [CleanableItem],
        isEligible: (CleanableItem) -> Bool
    ) -> Set<UUID> {
        Set(items.lazy.filter(isEligible).map(\.id))
    }
}
