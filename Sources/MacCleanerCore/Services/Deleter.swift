import Foundation

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
            // 符号链接、扫描后身份是否变化。失败只记录，不降级删除。
            if let failure = validate(item, with: guardrail) {
                failed.append(failure)
                continue
            }

            if dryRun {
                deleted.append(CleanedItem(path: item.path, size: item.size))
                continue
            }

            // 真正执行前再验证一次身份：校验与删除之间目标可能被替换，
            // 缩小路径替换竞态窗口；失败同样只记录不删除。
            if let failure = validate(item, with: guardrail) {
                failed.append(failure)
                continue
            }

            do {
                if useTrash {
                    try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                } else {
                    try fm.removeItem(atPath: item.path)
                }

                // 删除后验证：确认原始路径已不存在
                let verified = !fm.fileExists(atPath: item.path)
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

    /// 验证单个条目；失败返回 FailedItem，成功返回 nil。
    private func validate(_ item: CleanableItem, with guardrail: DeletionGuard) -> FailedItem? {
        do {
            _ = try guardrail.validate(path: item.path, expectedIdentity: item.fileIdentity)
            return nil
        } catch let guardError as DeletionGuardError {
            return FailedItem(
                path: item.path,
                error: Self.describe(guardError),
                reason: Self.reason(for: guardError),
                expectedSize: item.size
            )
        } catch {
            return FailedItem(
                path: item.path,
                error: "无法确认文件身份",
                reason: .identityUnavailable,
                expectedSize: item.size
            )
        }
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
