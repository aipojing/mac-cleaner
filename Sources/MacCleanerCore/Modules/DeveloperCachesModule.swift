import Foundation

public struct DeveloperCachesModule: CleanerModule {
    public let identifier = ModuleIdentifier.developerCaches
    public let displayName = "开发者缓存"
    public let description = "Gradle/Maven/npm/Yarn/pnpm/CocoaPods/Homebrew/Cargo/Go/pip/SwiftPM 缓存"

    private let scanner = DiskScanner()
    private let home = DiskScanner.homeDirectory
    private let identityProvider: any FileIdentityProviding

    public init(identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()) {
        self.identityProvider = identityProvider
    }

    public func isAvailable() -> Bool {
        let paths = [
            "\(home)/.gradle",
            "\(home)/.m2",
            "\(home)/.npm",
            "\(home)/Library/Caches/Yarn",
            "\(home)/Library/pnpm",
            "\(home)/.cocoapods",
            "\(home)/.pub-cache",
            "/usr/local/Cellar",
            "/opt/homebrew/Cellar",
            "\(home)/.cargo",
            "\(home)/go",
            "\(home)/.cache/pip",
            "\(home)/Library/Caches/org.swift.swiftpm",
        ]
        return paths.contains { scanner.directoryExists(at: $0) }
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()
        let limiter = context.fileTaskLimiter

        let items = await withTaskGroup(of: [CleanableItem].self) { group in
            group.addTask { (try? await limiter.withPermit { self.scanGradle() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanMaven() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanNpm() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanYarn() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanPnpm() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanCocoaPods() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanPubCache() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanHomebrew() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanCargo() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanGo() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanPip() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanSwiftPM() }) ?? [] }

            var all: [CleanableItem] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        // 取消时子任务返回空结果；此处传播取消，不输出残缺结果。
        try Task.checkCancellation()

        return ScanResult(
            module: .developerCaches,
            items: await context.recordIdentities(of: items),
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        Deleter().delete(items: items, module: .developerCaches, dryRun: dryRun, useTrash: false)
    }

    // MARK: - Gradle

    private func scanGradle() -> [CleanableItem] {
        var items: [CleanableItem] = []
        let gradlePath = "\(home)/.gradle"
        guard scanner.directoryExists(at: gradlePath) else { return items }

        let cachesPath = "\(gradlePath)/caches"
        if scanner.directoryExists(at: cachesPath) {
            let dirs = scanner.subdirectories(at: cachesPath)

            for dir in dirs {
                let name = (dir as NSString).lastPathComponent
                if GradleVersion.isSharedDirectory(name) || name == "modules-2" { continue }

                let size = scanner.directorySize(at: dir)
                guard size > 0 else { continue }

                items.append(CleanableItem(
                    path: dir,
                    displayName: "Gradle caches/\(name)",
                    size: size,
                    category: .developerCaches,
                    subcategory: "gradle",
                    evidenceTags: ["cache", "developer-tool", "gradle"]
                ))
            }
        }

        let daemonPath = "\(gradlePath)/daemon"
        if scanner.directoryExists(at: daemonPath) {
            let size = scanner.directorySize(at: daemonPath)
            if size > 0 {
                items.append(CleanableItem(
                    path: daemonPath,
                    displayName: "Gradle daemon 日志",
                    size: size,
                    category: .developerCaches,
                    subcategory: "gradle",
                    evidenceTags: ["cache", "developer-tool", "gradle"]
                ))
            }
        }

        let wrapperPath = "\(gradlePath)/wrapper/dists"
        if scanner.directoryExists(at: wrapperPath) {
            let dirs = scanner.subdirectories(at: wrapperPath)

            for dir in dirs {
                let name = (dir as NSString).lastPathComponent
                let size = scanner.directorySize(at: dir)
                guard size > 0 else { continue }

                items.append(CleanableItem(
                    path: dir,
                    displayName: "Gradle wrapper/\(name)",
                    size: size,
                    category: .developerCaches,
                    subcategory: "gradle",
                    evidenceTags: ["cache", "developer-tool", "gradle"]
                ))
            }
        }

        return items
    }

    private func scanMaven() -> [CleanableItem] {
        let m2Path = "\(home)/.m2/repository"
        guard scanner.directoryExists(at: m2Path) else { return [] }
        let size = scanner.directorySize(at: m2Path)
        guard size > 0 else { return [] }
        return [CleanableItem(
            path: m2Path, displayName: "Maven 本地仓库", size: size,
            category: .developerCaches, subcategory: "maven",
            evidenceTags: ["cache", "developer-tool", "maven"]
        )]
    }

    private func scanNpm() -> [CleanableItem] {
        let npmPath = "\(home)/.npm"
        guard scanner.directoryExists(at: npmPath) else { return [] }
        let size = scanner.directorySize(at: npmPath)
        guard size > 0 else { return [] }
        return [CleanableItem(
            path: npmPath, displayName: "npm 缓存", size: size,
            category: .developerCaches, subcategory: "npm",
            evidenceTags: ["cache", "developer-tool", "npm"]
        )]
    }

    private func scanYarn() -> [CleanableItem] {
        let yarnPath = "\(home)/Library/Caches/Yarn"
        guard scanner.directoryExists(at: yarnPath) else { return [] }
        let size = scanner.directorySize(at: yarnPath)
        guard size > 0 else { return [] }
        return [CleanableItem(
            path: yarnPath, displayName: "Yarn 缓存", size: size,
            category: .developerCaches, subcategory: "yarn",
            evidenceTags: ["cache", "developer-tool", "yarn"]
        )]
    }

    private func scanPnpm() -> [CleanableItem] {
        var items: [CleanableItem] = []
        let paths = [
            ("\(home)/Library/pnpm", "pnpm store"),
            ("\(home)/Library/Caches/pnpm", "pnpm 缓存"),
        ]
        for (path, name) in paths {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                path: path, displayName: name, size: size,
                category: .developerCaches, subcategory: "pnpm",
                evidenceTags: ["cache", "developer-tool", "pnpm"]
            ))
        }
        return items
    }

    private func scanCocoaPods() -> [CleanableItem] {
        let podsPath = "\(home)/.cocoapods"
        guard scanner.directoryExists(at: podsPath) else { return [] }
        let size = scanner.directorySize(at: podsPath)
        guard size > 0 else { return [] }
        return [CleanableItem(
            path: podsPath, displayName: "CocoaPods 缓存", size: size,
            category: .developerCaches, subcategory: "cocoapods",
            evidenceTags: ["cache", "developer-tool", "cocoapods"]
        )]
    }

    private func scanPubCache() -> [CleanableItem] {
        let pubPath = "\(home)/.pub-cache"
        guard scanner.directoryExists(at: pubPath) else { return [] }
        let size = scanner.directorySize(at: pubPath)
        guard size > 0 else { return [] }
        return [CleanableItem(
            path: pubPath, displayName: "Dart/Flutter pub 缓存", size: size,
            category: .developerCaches, subcategory: "pub",
            evidenceTags: ["cache", "developer-tool", "pub"]
        )]
    }

    // MARK: - Homebrew

    private func scanHomebrew() -> [CleanableItem] {
        var items: [CleanableItem] = []

        // 下载缓存（Taps 是 tap 元数据仓库，不是缓存，不能删）
        let cachePaths = [
            "\(home)/Library/Caches/Homebrew",
        ]
        for cachePath in cachePaths {
            guard scanner.directoryExists(at: cachePath) else { continue }
            let size = scanner.directorySize(at: cachePath)
            guard size > 0 else { continue }
            let name = (cachePath as NSString).lastPathComponent
            items.append(CleanableItem(
                path: cachePath, displayName: "Homebrew \(name)", size: size,
                category: .developerCaches, subcategory: "homebrew",
                evidenceTags: ["cache", "developer-tool", "homebrew"]
            ))
        }

        // 旧版本：扫描 Cellar 中非最新的版本目录
        for cellarPath in ["/usr/local/Cellar", "/opt/homebrew/Cellar"] {
            guard scanner.directoryExists(at: cellarPath) else { continue }
            let formulaDirs = scanner.subdirectories(at: cellarPath)
            for formulaDir in formulaDirs {
                let versions = scanner.subdirectories(at: formulaDir)
                    .sorted { lhs, rhs in
                        // 按语义版本排序：提取版本号部分进行数值比较
                        let lv = (lhs as NSString).lastPathComponent
                        let rv = (rhs as NSString).lastPathComponent
                        return lv.compare(rv, options: .numeric) == .orderedAscending
                    }
                guard versions.count >= 2 else { continue }
                // 保留语义最新版本（排序后最后一个），标记其余为旧版本
                let oldVersions = versions.dropLast()
                let sizes = scanner.directorySizesBatch(paths: Array(oldVersions))
                for oldDir in oldVersions {
                    let size = sizes[oldDir] ?? 0
                    guard size > 0 else { continue }
                    let formula = (formulaDir as NSString).lastPathComponent
                    let version = (oldDir as NSString).lastPathComponent
                    items.append(CleanableItem(
                        path: oldDir,
                        displayName: "Homebrew \(formula) (\(version))",
                        size: size,
                        category: .developerCaches, subcategory: "homebrew",
                        evidenceTags: ["cache", "developer-tool", "homebrew"]
                    ))
                }
            }
        }

        return items
    }

    // MARK: - Cargo (Rust)

    private func scanCargo() -> [CleanableItem] {
        var items: [CleanableItem] = []
        let cargoPath = "\(home)/.cargo"
        guard scanner.directoryExists(at: cargoPath) else { return [] }

        let cacheDirs = [
            ("\(cargoPath)/registry/cache", "Cargo registry 缓存"),
            ("\(cargoPath)/registry/src", "Cargo registry 源码"),
            ("\(cargoPath)/git/db", "Cargo git 依赖"),
        ]

        for (path, name) in cacheDirs {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                path: path, displayName: name, size: size,
                category: .developerCaches, subcategory: "cargo",
                evidenceTags: ["cache", "developer-tool", "cargo"]
            ))
        }

        return items
    }

    // MARK: - Go

    private func scanGo() -> [CleanableItem] {
        var items: [CleanableItem] = []

        // GOPATH/pkg/mod/cache 是 go get 下载缓存
        let goModCachePaths = [
            "\(home)/go/pkg/mod/cache",
            "\(home)/go/pkg/mod",
        ]

        // 只取最具体的存在路径，避免重复计算
        for path in goModCachePaths {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            let name = path.hasSuffix("cache") ? "Go 模块下载缓存" : "Go 模块缓存"
            items.append(CleanableItem(
                path: path, displayName: name, size: size,
                category: .developerCaches, subcategory: "go",
                evidenceTags: ["cache", "developer-tool", "go"]
            ))
            break // 只取第一个匹配的
        }

        // Go build cache
        let goCachePath = "\(home)/Library/Caches/go-build"
        if scanner.directoryExists(at: goCachePath) {
            let size = scanner.directorySize(at: goCachePath)
            if size > 0 {
                items.append(CleanableItem(
                    path: goCachePath, displayName: "Go 构建缓存", size: size,
                    category: .developerCaches, subcategory: "go",
                    evidenceTags: ["cache", "developer-tool", "go"]
                ))
            }
        }

        return items
    }

    // MARK: - pip (Python)

    private func scanPip() -> [CleanableItem] {
        var items: [CleanableItem] = []

        let pipPaths = [
            ("\(home)/.cache/pip", "pip 下载缓存"),
            ("\(home)/Library/Caches/pip", "pip 下载缓存 (macOS)"),
        ]

        for (path, name) in pipPaths {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                path: path, displayName: name, size: size,
                category: .developerCaches, subcategory: "pip",
                evidenceTags: ["cache", "developer-tool", "pip"]
            ))
        }

        return items
    }

    // MARK: - SwiftPM

    private func scanSwiftPM() -> [CleanableItem] {
        var items: [CleanableItem] = []

        let spmPaths = [
            ("\(home)/Library/Caches/org.swift.swiftpm", "SwiftPM 缓存"),
            ("\(home)/Library/org.swift.swiftpm", "SwiftPM 数据"),
        ]

        for (path, name) in spmPaths {
            guard scanner.directoryExists(at: path) else { continue }
            let size = scanner.directorySize(at: path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                path: path, displayName: name, size: size,
                category: .developerCaches, subcategory: "swiftpm",
                evidenceTags: ["cache", "developer-tool", "swiftpm"]
            ))
        }

        return items
    }
}
