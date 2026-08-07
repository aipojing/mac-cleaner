import Foundation

public struct DockerModule: CleanerModule {
    public let identifier = ModuleIdentifier.docker
    public let displayName = "Docker"
    public let description = "Docker Desktop 磁盘镜像、构建缓存和容器数据"

    private let scanner = DiskScanner()
    private let home: String
    private let shell: ShellExecutor
    private let identityProvider: any FileIdentityProviding

    public init(
        homeDirectory: URL? = nil,
        shell: ShellExecutor = ProcessRunner(),
        identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()
    ) {
        self.home = homeDirectory?.path ?? DiskScanner.homeDirectory
        self.shell = shell
        self.identityProvider = identityProvider
    }

    public func isAvailable() -> Bool {
        let dockerDataPath = "\(home)/Library/Containers/com.docker.docker"
        return scanner.directoryExists(at: dockerDataPath)
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()

        // 顺序型模块：整个元数据读取过程占用一个文件任务许可。
        return try await context.fileTaskLimiter.withPermit {
        var items: [CleanableItem] = []

        // Docker Desktop 数据目录（包含虚拟磁盘镜像）
        let dataPath = "\(home)/Library/Containers/com.docker.docker/Data"
        if scanner.directoryExists(at: dataPath) {
            // Docker.raw / Docker.qcow2 虚拟磁盘
            let vmPaths = [
                "\(dataPath)/vms/0/data/Docker.raw",
                "\(dataPath)/vms/0/data/Docker.qcow2",
            ]
            for vmPath in vmPaths {
                if scanner.fileExists(at: vmPath) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: vmPath)
                    let size = attrs?[.size] as? Int64 ?? 0
                    if size > 0 {
                        items.append(CleanableItem(
                            path: vmPath,
                            displayName: "Docker 虚拟磁盘",
                            size: size,
                            category: .docker,
                            subcategory: "disk-image",
                            evidenceTags: ["cache", "container", "docker"]
                        ))
                    }
                }
            }
        }

        // Docker 构建缓存（buildx）。不扫描 ~/.docker/contexts：
        // contexts 包含用户配置的 context 元数据，不是纯缓存，删除风险过高。
        let buildCachePaths = [
            "\(home)/.docker/buildx",
        ]
        for path in buildCachePaths {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            let name = (path as NSString).lastPathComponent
            items.append(CleanableItem(
                path: path,
                displayName: "Docker \(name)",
                size: size,
                category: .docker,
                subcategory: "build-cache",
                evidenceTags: ["cache", "container", "docker"]
            ))
        }

        // Docker Desktop 应用缓存
        let cachesPaths = [
            "\(home)/Library/Caches/com.docker.docker",
            "\(home)/Library/Caches/Docker",
        ]
        for path in cachesPaths {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 100_000 else { continue } // 忽略几乎为空的缓存目录
            items.append(CleanableItem(
                path: path,
                displayName: "Docker 应用缓存",
                size: size,
                category: .docker,
                subcategory: "app-cache",
                evidenceTags: ["cache", "container", "docker"]
            ))
        }

        // Docker 日志（daemon.json 是配置文件，不是日志，不能删）
        let logPaths = [
            "\(home)/Library/Containers/com.docker.docker/Data/log",
        ]
        for path in logPaths {
            guard scanner.directoryExists(at: path) || scanner.fileExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                path: path,
                displayName: "Docker 日志",
                size: size,
                category: .docker,
                subcategory: "logs",
                evidenceTags: ["cache", "container", "docker"]
            ))
        }

        return ScanResult(
            module: .docker,
            items: await context.recordIdentities(of: items),
            scanDuration: Date().timeIntervalSince(start)
        )
        }
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        // 虚拟磁盘不能直接删除（需要 docker system prune），其他文件用 Deleter
        let diskImages = items.filter { $0.subcategory == "disk-image" }
        let regularItems = items.filter { $0.subcategory != "disk-image" }

        var allDeleted: [CleanedItem] = []
        var allFailed: [FailedItem] = []
        var expectedTotal: Int64 = 0
        var actualTotal: Int64 = 0

        // 常规文件删除
        if !regularItems.isEmpty {
            let report = Deleter().delete(
                items: regularItems, module: .docker,
                dryRun: dryRun, useTrash: false
            )
            allDeleted.append(contentsOf: report.deletedItems)
            allFailed.append(contentsOf: report.failedItems)
            expectedTotal += report.expectedSize
            actualTotal += report.actualFreed
        }

        // 虚拟磁盘通过提示用户在 Docker Desktop 中处理
        for item in diskImages {
            expectedTotal += item.size
            if dryRun {
                allDeleted.append(CleanedItem(path: item.path, size: item.size))
                actualTotal += item.size
            } else {
                allFailed.append(FailedItem(
                    path: item.path,
                    error: "Docker 虚拟磁盘需在 Docker Desktop → Settings → Resources 中清理",
                    reason: .unknown,
                    expectedSize: item.size
                ))
            }
        }

        return CleanupReport(
            module: .docker,
            deletedItems: allDeleted,
            failedItems: allFailed,
            dryRun: dryRun,
            expectedSize: expectedTotal,
            actualFreed: actualTotal
        )
    }
}
