import Foundation

/// DuplicateFilesModule 最近一次扫描的执行层记录：重复组成员清单与
/// 每个候选路径的抽样指纹。`clean` 据此校验“每组至少保留一份”不变量，
/// 并在删除前重验文件内容是否在扫描后漂移。
///
/// 语义说明：模块只能知道自己扫到的组。`clean` 收到某组的删除列表时：
/// - 该组有扫描记录：要求“扫描到的组内路径不能全部在删除列表中”，
///   否则整组拒绝删除；
/// - 该组无扫描记录（如 clean 被独立调用）：按“传入 items 构成完整一组”
///   处理，同组条目 ≥2 视为整组清空而拒绝；单条目无法证明属于重复组，放行。
actor DuplicateScanRegistry {
    struct FileRecord: Sendable {
        /// 所在重复组的 full hash（即 CleanableItem.subcategory）。
        let groupHash: String
        /// 扫描时的逻辑大小（sampled hash 的抽样偏移依据）。
        let logicalSize: Int64
        /// 扫描时的三段抽样指纹，用于删除前的内容漂移重验。
        let sampledHash: String
    }

    private(set) var groupMembers: [String: Set<String>] = [:]
    private(set) var fileRecords: [String: FileRecord] = [:]

    /// 用一次扫描的结果整体替换记录（新一轮扫描以事实为准）。
    func replace(groupMembers: [String: Set<String>], fileRecords: [String: FileRecord]) {
        self.groupMembers = groupMembers
        self.fileRecords = fileRecords
    }

    /// 删除成功后移除路径：后续 clean 按剩余成员继续校验不变量，
    /// 组内只剩一份时再删会被拒绝。
    func removePaths(_ paths: [String]) {
        for path in paths {
            guard let record = fileRecords.removeValue(forKey: path) else { continue }
            groupMembers[record.groupHash]?.remove(path)
            if groupMembers[record.groupHash]?.isEmpty == true {
                groupMembers.removeValue(forKey: record.groupHash)
            }
        }
    }
}
