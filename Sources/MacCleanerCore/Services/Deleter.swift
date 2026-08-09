import Foundation
import Darwin

public struct Deleter: Sendable {
    private let policyCatalog: any DeletionPolicyProviding
    private let identityProvider: any FileIdentityProviding

    public init(
        policyCatalog: any DeletionPolicyProviding = DeletionPolicyCatalog(),
        identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()
    ) {
        self.policyCatalog = policyCatalog
        self.identityProvider = identityProvider
    }

    public func delete(
        items: [CleanableItem],
        module: ModuleIdentifier,
        dryRun: Bool = false,
        useTrash: Bool = true,
        onProgress: (@Sendable (String, Int, Int) -> Void)? = nil
    ) -> CleanupReport {
        var deleted: [CleanedItem] = []
        var failed: [FailedItem] = []
        let total = items.count
        let fm = FileManager.default

        // 按模块取删除策略，构造执行层 guard。AI 层没有 policy 写入口。
        let policy = policyCatalog.policy(for: module)
        let guardrail = DeletionGuard(
            allowedRoots: policy.allowedRoots,
            identityProvider: identityProvider,
            protectedExactPaths: policy.protectedExactPaths,
            protectedSubtrees: policy.protectedSubtrees
        )

        for (index, item) in items.enumerated() {
            onProgress?(item.displayName, index + 1, total)

            // 执行前（含 dry-run）统一验证：允许根、受保护路径、
            // 符号链接、扫描后身份是否变化，以及强制模块的内容漂移。
            // 失败只记录，不降级删除。
            switch validate(item, with: guardrail, enforceContentDrift: policy.rejectOnContentDrift) {
            case .failure(let failure):
                failed.append(failure)
                continue
            case .success:
                break
            }

            if dryRun {
                deleted.append(CleanedItem(path: item.path, size: item.size))
                continue
            }

            // 真正执行前再验证一次身份：校验与删除之间目标可能被替换，
            // 缩小路径替换竞态窗口；失败同样只记录不删除。
            // 删除直接使用本次验证返回的规范化路径（父目录符号链接已解析），
            // 避免校验与删除各做一次路径解析导致删除被重定向。
            // 这只能缩小 TOCTOU 窗口而非消除；彻底方案需基于目录 fd 的
            // unlinkat（当前未实现）。
            let executionPath: String
            switch validate(item, with: guardrail, enforceContentDrift: policy.rejectOnContentDrift) {
            case .failure(let failure):
                failed.append(failure)
                continue
            case .success(let canonicalPath):
                executionPath = canonicalPath
            }

            do {
                if useTrash {
                    try fm.trashItem(at: URL(fileURLWithPath: executionPath), resultingItemURL: nil)
                } else {
                    try fm.removeItem(atPath: executionPath)
                }

                // 删除后验证：确认目标已不存在
                let verified = !fm.fileExists(atPath: executionPath)
                // 移到废纸篓的文件还占用磁盘空间，直到用户清空废纸篓
                let freed = useTrash ? Int64(0) : (verified ? item.size : 0)
                deleted.append(CleanedItem(
                    path: item.path,
                    expectedSize: item.size,
                    actualFreed: freed,
                    verified: verified,
                    movedToTrash: useTrash
                ))
            } catch {
                let reason = classifyDeletionError(error)
                failed.append(FailedItem(
                    path: item.path,
                    error: error.localizedDescription,
                    reason: reason,
                    expectedSize: item.size
                ))
            }
        }

        let expectedSize = items.reduce(Int64(0)) { $0 + $1.size }
        let actualFreed = deleted.reduce(Int64(0)) { $0 + $1.actualFreed }

        return CleanupReport(
            module: module,
            deletedItems: deleted,
            failedItems: failed,
            dryRun: dryRun,
            expectedSize: expectedSize,
            actualFreed: actualFreed
        )
    }

    /// 单条目验证结果：成功给出用于执行删除的规范化路径，失败给出 FailedItem。
    private enum ValidationOutcome {
        case success(String)
        case failure(FailedItem)
    }

    /// 验证单个条目；成功返回用于执行删除的规范化路径，失败返回 FailedItem。
    private func validate(
        _ item: CleanableItem,
        with guardrail: DeletionGuard,
        enforceContentDrift: Bool
    ) -> ValidationOutcome {
        let target: DeletionGuard.ValidatedTarget
        do {
            target = try guardrail.validatedTarget(path: item.path, expectedIdentity: item.fileIdentity)
        } catch let guardError as DeletionGuardError {
            return .failure(FailedItem(
                path: item.path,
                error: Self.describe(guardError),
                reason: Self.reason(for: guardError),
                expectedSize: item.size
            ))
        } catch {
            return .failure(FailedItem(
                path: item.path,
                error: "无法确认文件身份",
                reason: .identityUnavailable,
                expectedSize: item.size
            ))
        }

        // 内容漂移检测：身份（device/inode）未变不代表内容未变，
        // 文件可能在扫描后被原地改写。只对策略开启的模块（large-files）强制。
        if enforceContentDrift, contentDrifted(item, at: target.canonicalPath) {
            return .failure(FailedItem(
                path: item.path,
                error: "文件内容在扫描后已变化（修改时间或大小不一致）",
                reason: .contentModified,
                expectedSize: item.size
            ))
        }

        return .success(target.canonicalPath)
    }

    /// 对验证过的规范化路径重新 lstat，比对扫描时记录的 mtime（纳秒）与 size。
    /// 未记录指纹的条目（旧构造点、合并条目、读取失败）跳过检测；
    /// lstat 失败按漂移处理（拒绝删除）。
    private func contentDrifted(_ item: CleanableItem, at canonicalPath: String) -> Bool {
        guard let expectedMtime = item.recordedModificationNanoseconds,
              let expectedSize = item.recordedContentSize
        else { return false }

        var st = stat()
        guard lstat(canonicalPath, &st) == 0 else { return true }

        let currentMtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(st.st_mtimespec.tv_nsec)
        return currentMtime != expectedMtime || Int64(st.st_size) != expectedSize
    }

    /// 将 guard 拒绝原因映射到报告失败原因。
    private static func reason(for error: DeletionGuardError) -> FailureReason {
        switch error {
        case .targetMissing:
            return .notFound
        case .outsideAllowedRoots, .protectedRoot, .protectedSubtree, .symbolicLink:
            return .unsafeTarget
        case .identityChanged:
            return .identityChanged
        case .identityUnavailable:
            return .identityUnavailable
        }
    }

    private static func describe(_ error: DeletionGuardError) -> String {
        switch error {
        case .targetMissing:
            return "目标不存在或无法访问"
        case .outsideAllowedRoots:
            return "目标超出本模块允许的清理范围"
        case .protectedRoot:
            return "目标是受保护的系统或用户路径"
        case .protectedSubtree:
            return "目标位于受保护的系统目录内"
        case .symbolicLink:
            return "目标是符号链接，已拒绝执行"
        case .identityChanged:
            return "文件在扫描后已被替换或移动"
        case .identityUnavailable:
            return "无法确认文件身份"
        }
    }

    private func classifyDeletionError(_ error: Error) -> FailureReason {
        let nsError = error as NSError
        switch nsError.code {
        case NSFileWriteNoPermissionError, CocoaError.fileWriteNoPermission.rawValue:
            return .permissionDenied
        case NSFileNoSuchFileError, CocoaError.fileNoSuchFile.rawValue,
             CocoaError.fileReadNoSuchFile.rawValue:
            return .notFound
        default:
            let desc = error.localizedDescription.lowercased()
            if desc.contains("permission") || desc.contains("not permitted") {
                return .permissionDenied
            }
            if desc.contains("busy") || desc.contains("in use") || desc.contains("locked") {
                return .fileInUse
            }
            if desc.contains("no space") {
                return .diskFull
            }
            return .unknown
        }
    }
}
