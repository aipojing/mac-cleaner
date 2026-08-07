import Foundation

public struct AndroidSDKModule: CleanerModule {
    public let identifier = ModuleIdentifier.androidSDK
    public let displayName = "Android SDK"
    public let description = "旧版 platforms/build-tools/NDK/system-images/AVD"

    private let scanner = DiskScanner()
    private let home = DiskScanner.homeDirectory
    private let identityProvider: any FileIdentityProviding

    public init(identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()) {
        self.identityProvider = identityProvider
    }

    /// SDK 根目录候选列表。扫描与删除策略共用同一份来源，
    /// 不读取 AI 输出。环境变量由调用方注入，默认读取当前进程环境。
    static func sdkRootCandidates(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        [
            environment["ANDROID_HOME"] ?? "",
            environment["ANDROID_SDK_ROOT"] ?? "",
            "\(home)/Library/Android/sdk",
            "\(home)/Android/Sdk",
            "\(home)/Documents/android-sdk-macosx",
        ].filter { !$0.isEmpty }
    }

    public func isAvailable() -> Bool {
        findSDKRoot() != nil || scanner.directoryExists(at: "\(home)/.android")
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()
        let limiter = context.fileTaskLimiter

        let items = await withTaskGroup(of: [CleanableItem].self) { group in
            group.addTask { (try? await limiter.withPermit { self.scanPlatforms() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanBuildTools() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanNDK() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanCMake() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanSystemImages() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanAVD() }) ?? [] }
            group.addTask { (try? await limiter.withPermit { self.scanAndroidCache() }) ?? [] }

            var all: [CleanableItem] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        // 取消时子任务返回空结果；此处传播取消，不输出残缺结果。
        try Task.checkCancellation()

        return ScanResult(
            module: .androidSDK,
            items: await context.recordIdentities(of: items),
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        Deleter().delete(items: items, module: .androidSDK, dryRun: dryRun, useTrash: false)
    }

    // MARK: - SDK Root Discovery

    /// 按优先级查找 Android SDK 根目录
    func findSDKRoot() -> String? {
        Self.sdkRootCandidates(home: home)
            .first { scanner.directoryExists(at: $0) }
    }

    // MARK: - Platforms (android-XX)

    private func scanPlatforms() -> [CleanableItem] {
        guard let sdkRoot = findSDKRoot() else { return [] }
        let platformsPath = "\(sdkRoot)/platforms"
        guard scanner.directoryExists(at: platformsPath) else { return [] }

        let dirs = scanner.subdirectories(at: platformsPath)
        let parsed: [(path: String, name: String, apiLevel: Int)] = dirs.compactMap { dir in
            let name = (dir as NSString).lastPathComponent
            guard let level = parseAPILevel(from: name) else { return nil }
            return (dir, name, level)
        }

        guard !parsed.isEmpty else { return [] }
        let sizes = scanner.directorySizesBatch(paths: parsed.map(\.path))

        return parsed.compactMap { entry in
            let size = sizes[entry.path] ?? 0
            guard size > 0 else { return nil }

            return CleanableItem(
                path: entry.path,
                displayName: "Android Platform \(entry.name)",
                size: size,
                category: .androidSDK,
                subcategory: "platforms",
                evidenceTags: ["cache", "developer-tool", "android"]
            )
        }
    }

    // MARK: - Build Tools

    private func scanBuildTools() -> [CleanableItem] {
        guard let sdkRoot = findSDKRoot() else { return [] }
        let buildToolsPath = "\(sdkRoot)/build-tools"
        guard scanner.directoryExists(at: buildToolsPath) else { return [] }

        let dirs = scanner.subdirectories(at: buildToolsPath)
        let parsed: [(path: String, name: String, version: SDKVersion)] = dirs.compactMap { dir in
            let name = (dir as NSString).lastPathComponent
            guard let version = SDKVersion(name) else { return nil }
            return (dir, name, version)
        }

        guard !parsed.isEmpty else { return [] }
        let sizes = scanner.directorySizesBatch(paths: parsed.map(\.path))

        return parsed.compactMap { entry in
            let size = sizes[entry.path] ?? 0
            guard size > 0 else { return nil }

            return CleanableItem(
                path: entry.path,
                displayName: "Build Tools \(entry.name)",
                size: size,
                category: .androidSDK,
                subcategory: "build-tools",
                evidenceTags: ["cache", "developer-tool", "android"]
            )
        }
    }

    // MARK: - NDK

    private func scanNDK() -> [CleanableItem] {
        guard let sdkRoot = findSDKRoot() else { return [] }
        let ndkPath = "\(sdkRoot)/ndk"
        guard scanner.directoryExists(at: ndkPath) else { return [] }

        let dirs = scanner.subdirectories(at: ndkPath)
        let parsed: [(path: String, name: String, version: SDKVersion)] = dirs.compactMap { dir in
            let name = (dir as NSString).lastPathComponent
            guard let version = SDKVersion(name) else { return nil }
            return (dir, name, version)
        }

        guard !parsed.isEmpty else { return [] }
        let sizes = scanner.directorySizesBatch(paths: parsed.map(\.path))

        return parsed.compactMap { entry in
            let size = sizes[entry.path] ?? 0
            guard size > 0 else { return nil }

            return CleanableItem(
                path: entry.path,
                displayName: "NDK \(entry.name)",
                size: size,
                category: .androidSDK,
                subcategory: "ndk",
                evidenceTags: ["cache", "developer-tool", "android"]
            )
        }
    }

    // MARK: - CMake

    private func scanCMake() -> [CleanableItem] {
        guard let sdkRoot = findSDKRoot() else { return [] }
        let cmakePath = "\(sdkRoot)/cmake"
        guard scanner.directoryExists(at: cmakePath) else { return [] }

        let dirs = scanner.subdirectories(at: cmakePath)
        let parsed: [(path: String, name: String, version: SDKVersion)] = dirs.compactMap { dir in
            let name = (dir as NSString).lastPathComponent
            guard let version = SDKVersion(name) else { return nil }
            return (dir, name, version)
        }

        guard parsed.count >= 2 else { return [] }
        let sizes = scanner.directorySizesBatch(paths: parsed.map(\.path))

        return parsed.compactMap { entry in
            let size = sizes[entry.path] ?? 0
            guard size > 0 else { return nil }

            return CleanableItem(
                path: entry.path,
                displayName: "CMake \(entry.name)",
                size: size,
                category: .androidSDK,
                subcategory: "cmake",
                evidenceTags: ["cache", "developer-tool", "android"]
            )
        }
    }

    // MARK: - System Images (emulator images)

    private func scanSystemImages() -> [CleanableItem] {
        guard let sdkRoot = findSDKRoot() else { return [] }
        let sysImgPath = "\(sdkRoot)/system-images"
        guard scanner.directoryExists(at: sysImgPath) else { return [] }

        // system-images/android-XX/google_apis/arm64-v8a/
        let apiDirs = scanner.subdirectories(at: sysImgPath)
        var items: [CleanableItem] = []

        for apiDir in apiDirs {
            let apiName = (apiDir as NSString).lastPathComponent
            guard parseAPILevel(from: apiName) != nil else { continue }

            let size = scanner.directorySize(at: apiDir)
            guard size > 0 else { continue }

            items.append(CleanableItem(
                path: apiDir,
                displayName: "模拟器镜像 \(apiName)",
                size: size,
                category: .androidSDK,
                subcategory: "system-images",
                evidenceTags: ["cache", "developer-tool", "android"]
            ))
        }

        return items
    }

    // MARK: - AVD (Android Virtual Devices)

    private func scanAVD() -> [CleanableItem] {
        let avdPath = "\(home)/.android/avd"
        guard scanner.directoryExists(at: avdPath) else { return [] }

        let dirs = scanner.subdirectories(at: avdPath)
        let sizes = scanner.directorySizesBatch(paths: dirs)

        return dirs.compactMap { dir in
            let size = sizes[dir] ?? 0
            guard size > 0 else { return nil }
            let name = (dir as NSString).lastPathComponent
                .replacingOccurrences(of: ".avd", with: "")

            return CleanableItem(
                path: dir,
                displayName: "AVD 虚拟设备 \(name)",
                size: size,
                category: .androidSDK,
                subcategory: "avd",
                evidenceTags: ["cache", "developer-tool", "android"]
            )
        }
    }

    // MARK: - .android/cache

    private func scanAndroidCache() -> [CleanableItem] {
        let cachePath = "\(home)/.android/cache"
        guard scanner.directoryExists(at: cachePath) else { return [] }
        let size = scanner.directorySize(at: cachePath)
        guard size > 0 else { return [] }

        return [CleanableItem(
            path: cachePath,
            displayName: "Android SDK 缓存",
            size: size,
            category: .androidSDK,
            subcategory: "cache",
            evidenceTags: ["cache", "developer-tool", "android"]
        )]
    }

    // MARK: - Version Parsing

    /// 从 "android-XX" 中提取 API level
    static func parseAPILevel(from name: String) -> Int? {
        let stripped = name.replacingOccurrences(of: "android-", with: "")
        return Int(stripped)
    }

    private func parseAPILevel(from name: String) -> Int? {
        Self.parseAPILevel(from: name)
    }
}

/// 版本号比较，支持 "35.0.0"、"3.22.1"、"21.0.6113669" 等格式
struct SDKVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ string: String) {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.components = parts
    }

    static func < (lhs: SDKVersion, rhs: SDKVersion) -> Bool {
        let maxLen = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxLen {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}
