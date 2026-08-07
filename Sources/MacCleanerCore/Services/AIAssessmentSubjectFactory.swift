import Foundation

/// 把本地扫描事实转换为 AI subject。只使用可验证的元数据事实，
/// 不加入文件内容、旧规则或任何本地判断。
public struct AIAssessmentSubjectFactory: Sendable {
    private let fingerprintGenerator: AIFingerprintGenerator
    /// 读取当前文件元数据（mtime 等）。修改时间只存在于文件系统，
    /// 不入扫描模型；指纹需要它来保证内容变化后缓存正确失效。
    private let metadataReader: @Sendable (String) -> FileMetadata?

    public init(
        fingerprintGenerator: AIFingerprintGenerator = AIFingerprintGenerator(),
        metadataReader: @escaping @Sendable (String) -> FileMetadata? = {
            try? POSIXFileMetadataProvider().metadataSync(at: POSIXFileMetadataProvider.normalized($0))
        }
    ) {
        self.fingerprintGenerator = fingerprintGenerator
        self.metadataReader = metadataReader
    }

    /// 清理对象 subject。`fileIdentity == nil` 时仍可分析，
    /// 指纹以 device/inode 为 0、类型为 other 明确编码空身份；
    /// 执行删除时本地 guard 仍会拒绝没有身份的目标。
    /// allocatedSize 取扫描记录的实际占用；modificationTime 取当前 lstat，
    /// 内容变化（即使大小不变）会产生新指纹，避免错误复用旧缓存。
    public func cleanupSubject(for item: CleanableItem) throws -> AIAssessmentSubject {
        let identity = item.fileIdentity
        let modificationTime = metadataReader(item.path).map {
            Date(timeIntervalSince1970: TimeInterval($0.modificationTimeNanoseconds) / 1_000_000_000)
        }
        let fingerprint = try fingerprintGenerator.cleanupFingerprint(
            CleanupFingerprintInput(
                path: item.path,
                device: identity?.device ?? 0,
                inode: identity?.inode ?? 0,
                objectKind: identity?.kind ?? .other,
                allocatedSize: UInt64(max(0, item.allocatedSize)),
                modificationTime: modificationTime,
                module: item.category,
                tags: item.evidenceTags
            )
        )
        let evidence = CleanupAIEvidence(
            path: item.path,
            objectKind: identity?.kind ?? .other,
            logicalSize: UInt64(max(0, item.size)),
            allocatedSize: UInt64(max(0, item.allocatedSize)),
            modificationTime: modificationTime,
            module: item.category,
            tags: item.evidenceTags
        )
        return .cleanup(
            id: "cleanup:\(item.id.uuidString)",
            fingerprint: fingerprint,
            evidence: evidence
        )
    }

    /// 进程 subject。写入 PID、真实路径、basename、bundle ID、user、
    /// CPU、RSS、运行时长和签名状态；不加入原始 ps 行或 argv。
    /// 身份无法解析时指纹以 startTimeTicks 为 0 明确编码空身份。
    public func processSubject(for process: RunningProcess) throws -> AIAssessmentSubject {
        let identity = process.identity
        let executablePath = identity?.executablePath ?? process.path
        let fingerprint = try fingerprintGenerator.processFingerprint(
            ProcessFingerprintInput(
                pid: process.id,
                executablePath: executablePath,
                bundleIdentifier: identity?.bundleIdentifier,
                startTimeTicks: identity?.startTimeTicks ?? 0,
                signedByApple: process.signedByApple
            )
        )
        let evidence = ProcessAIEvidence(
            pid: process.id,
            executablePath: executablePath,
            executableName: process.name,
            bundleIdentifier: identity?.bundleIdentifier,
            owner: process.user,
            cpuPercent: process.cpuPercent,
            residentMemoryBytes: process.residentMemoryBytes,
            elapsedSeconds: process.elapsedSeconds,
            signedByApple: process.signedByApple
        )
        return .process(
            id: "process:\(process.id)",
            fingerprint: fingerprint,
            evidence: evidence
        )
    }
}
