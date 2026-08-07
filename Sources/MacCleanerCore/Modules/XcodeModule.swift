import Foundation

public struct XcodeModule: CleanerModule {
    public let identifier = ModuleIdentifier.xcode
    public let displayName = "Xcode"
    public let description = "DerivedData/Archives/DeviceSupport"

    private let scanner = DiskScanner()
    private let home = DiskScanner.homeDirectory
    private let identityProvider: any FileIdentityProviding

    public init(identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()) {
        self.identityProvider = identityProvider
    }

    public func isAvailable() -> Bool {
        scanner.directoryExists(at: "\(home)/Library/Developer/Xcode")
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()
        let limiter = context.fileTaskLimiter

        let items = await withTaskGroup(of: [CleanableItem].self) { group in
            group.addTask { (try? await limiter.withPermit { self.scanDerivedData() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanArchives() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanDeviceSupport() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanCoreSimulatorCaches() }) ?? [] }

            var all: [CleanableItem] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        // 取消时子任务返回空结果；此处传播取消，不输出残缺结果。
        try Task.checkCancellation()

        return ScanResult(
            module: .xcode,
            items: await context.recordIdentities(of: items),
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    private func scanDerivedData() -> [CleanableItem] {
        let derivedDataPath = "\(home)/Library/Developer/Xcode/DerivedData"
        guard scanner.directoryExists(at: derivedDataPath) else { return [] }

        let dirs = scanner.subdirectories(at: derivedDataPath)
            .filter { ($0 as NSString).lastPathComponent != "ModuleCache.noindex" }

        let sizes = scanner.directorySizesBatch(paths: dirs)
        let fm = FileManager.default

        return dirs.compactMap { dir in
            let dirName = (dir as NSString).lastPathComponent
            let size = sizes[dir] ?? 0
            guard size > 0 else { return nil }

            // 解析 info.plist 获取项目名称
            let projectName = parseProjectName(derivedDataDir: dir, fm: fm) ?? dirName
            let lastAccessed = lastAccessDate(at: dir, fm: fm)
            let daysSinceAccess = lastAccessed.map {
                Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0
            } ?? 0

            let staleHint = daysSinceAccess > 30 ? " (>\(daysSinceAccess)天未访问)" : ""

            return CleanableItem(
                path: dir,
                displayName: "\(projectName)\(staleHint)",
                size: size,
                category: .xcode,
                subcategory: "derived-data",
                evidenceTags: ["cache", "developer-tool", "xcode"]
            )
        }
    }

    /// 从 DerivedData 子目录的 info.plist 解析项目路径
    private func parseProjectName(derivedDataDir: String, fm: FileManager) -> String? {
        let plistPath = (derivedDataDir as NSString).appendingPathComponent("info.plist")
        guard let data = fm.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workspacePath = plist["WorkspacePath"] as? String
        else { return nil }

        // 从 WorkspacePath 提取项目名
        let filename = (workspacePath as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }

    private func lastAccessDate(at path: String, fm: FileManager) -> Date? {
        let attrs = try? fm.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }

    private func scanArchives() -> [CleanableItem] {
        let archivesPath = "\(home)/Library/Developer/Xcode/Archives"
        guard scanner.directoryExists(at: archivesPath) else { return [] }

        let dirs = scanner.subdirectories(at: archivesPath)
        let sizes = scanner.directorySizesBatch(paths: dirs)

        return dirs.compactMap { dir in
            let size = sizes[dir] ?? 0
            guard size > 0 else { return nil }
            let name = (dir as NSString).lastPathComponent

            return CleanableItem(
                path: dir,
                displayName: "Archives/\(name)",
                size: size,
                category: .xcode,
                subcategory: "archives",
                evidenceTags: ["cache", "developer-tool", "xcode"]
            )
        }
    }

    private func scanDeviceSupport() -> [CleanableItem] {
        let deviceSupportPath = "\(home)/Library/Developer/Xcode/iOS DeviceSupport"
        guard scanner.directoryExists(at: deviceSupportPath) else { return [] }

        let dirs = scanner.subdirectories(at: deviceSupportPath)
        let sizes = scanner.directorySizesBatch(paths: dirs)

        // 解析版本号并找到最新版本
        struct VersionedDir {
            let path: String
            let name: String
            let size: Int64
            let majorMinor: String // "18.3" 等
        }
        var versionedDirs: [VersionedDir] = []

        for dir in dirs {
            let size = sizes[dir] ?? 0
            guard size > 0 else { continue }
            let name = (dir as NSString).lastPathComponent
            // 目录名格式如 "18.3.2 (22G5027e)" 或 "17.5 (21F79)"
            let majorMinor = extractMajorMinor(from: name)
            versionedDirs.append(VersionedDir(
                path: dir, name: name, size: size,
                majorMinor: majorMinor ?? name
            ))
        }

        return versionedDirs.map { entry in
            CleanableItem(
                path: entry.path,
                displayName: "DeviceSupport/iOS \(entry.majorMinor)",
                size: entry.size,
                category: .xcode,
                subcategory: "device-support",
                evidenceTags: ["cache", "developer-tool", "xcode"]
            )
        }
    }

    /// 从 DeviceSupport 目录名提取 iOS 主版本号
    private func extractMajorMinor(from name: String) -> String? {
        // "18.3.2 (22G5027e)" → "18.3"
        let parts = name.split(separator: " ").first?.split(separator: ".") ?? []
        guard parts.count >= 2,
              let _ = Int(parts[0]),
              let _ = Int(parts[1])
        else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    private func scanCoreSimulatorCaches() -> [CleanableItem] {
        let coreSimCachePath = "\(home)/Library/Developer/CoreSimulator/Caches"
        guard scanner.directoryExists(at: coreSimCachePath) else { return [] }
        let size = scanner.directorySize(at: coreSimCachePath)
        guard size > 0 else { return [] }
        return [CleanableItem(
            path: coreSimCachePath,
            displayName: "CoreSimulator/Caches",
            size: size,
            category: .xcode,
            subcategory: "simulator-cache",
            evidenceTags: ["cache", "developer-tool", "xcode"]
        )]
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        Deleter().delete(items: items, module: .xcode, dryRun: dryRun, useTrash: false)
    }
}
