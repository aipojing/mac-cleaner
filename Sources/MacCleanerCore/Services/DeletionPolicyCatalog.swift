import Foundation

/// 单个模块的删除策略：允许根目录 + 受保护路径集合。
public struct DeletionPolicy: Sendable {
    public let allowedRoots: [String]
    public let protectedExactPaths: [String]
    public let protectedSubtrees: [String]

    public init(
        allowedRoots: [String],
        protectedExactPaths: [String],
        protectedSubtrees: [String]
    ) {
        self.allowedRoots = allowedRoots
        self.protectedExactPaths = protectedExactPaths
        self.protectedSubtrees = protectedSubtrees
    }
}

public protocol DeletionPolicyProviding: Sendable {
    func policy(for module: ModuleIdentifier) -> DeletionPolicy
}

/// 生产策略目录。允许根目录从注入的 home / developer directory 生成，
/// 不读取任何 AI 输出。所有模块共享同一套受保护路径基线。
public struct DeletionPolicyCatalog: DeletionPolicyProviding {
    private let home: String
    private let protectedExactPaths: [String]
    private let protectedSubtrees: [String]

    public init(home: String = DiskScanner.homeDirectory) {
        self.home = home
        self.protectedExactPaths = ["/", home]
        self.protectedSubtrees = [
            "/System",
            "/usr/bin",
            "/usr/lib",
            "/usr/sbin",
            "/usr/share",
            "/bin",
            "/sbin",
            "/private/var/db",
        ]
    }

    public func policy(for module: ModuleIdentifier) -> DeletionPolicy {
        DeletionPolicy(
            allowedRoots: allowedRoots(for: module),
            protectedExactPaths: protectedExactPaths,
            protectedSubtrees: protectedSubtrees
        )
    }

    private func allowedRoots(for module: ModuleIdentifier) -> [String] {
        switch module {
        case .developerCaches:
            return [
                "\(home)/.gradle/caches",
                "\(home)/.gradle/daemon",
                "\(home)/.gradle/wrapper/dists",
                "\(home)/.m2/repository",
                "\(home)/.npm",
                "\(home)/Library/Caches/Yarn",
                "\(home)/Library/pnpm",
                "\(home)/Library/Caches/pnpm",
                "\(home)/.cocoapods",
                "\(home)/.pub-cache",
                "\(home)/Library/Caches/Homebrew",
                "/usr/local/Cellar",
                "/opt/homebrew/Cellar",
                "\(home)/.cargo/registry/cache",
                "\(home)/.cargo/registry/src",
                "\(home)/.cargo/git/db",
                "\(home)/go/pkg/mod/cache",
                "\(home)/go/pkg/mod",
                "\(home)/.cache/pip",
                "\(home)/Library/Caches/pip",
                "\(home)/Library/Caches/go-build",
                "\(home)/Library/Caches/org.swift.swiftpm",
                "\(home)/Library/org.swift.swiftpm",
            ]
        case .iosSimulators:
            return [
                "\(home)/Library/Developer/CoreSimulator/Devices",
                "\(home)/Library/Developer/CoreSimulator/Profiles/Runtimes",
            ]
        case .xcode:
            return [
                "\(home)/Library/Developer/Xcode/DerivedData",
                "\(home)/Library/Developer/Xcode/Archives",
                "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
                "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
                "\(home)/Library/Developer/CoreSimulator/Caches",
            ]
        case .aiToolCaches:
            return AIToolCachesModule.homeRoots(home: home)
        case .applicationCaches:
            return ["\(home)/Library/Caches"]
        case .docker:
            return [
                "\(home)/Library/Containers/com.docker.docker/Data",
                "\(home)/.docker/buildx",
            ]
        case .systemLogs:
            return [
                "\(home)/Library/Logs",
                "\(home)/Library/Logs/DiagnosticReports",
            ]
        case .androidSDK:
            // 允许根：模块明确识别的 SDK 子目录候选（含环境变量指定的 SDK 根）
            // 与 AVD、Gradle 缓存。
            var roots: [String] = [
                "\(home)/.gradle/caches",
                "\(home)/.android/avd",
                "\(home)/.android/cache",
            ]
            for sdkRoot in AndroidSDKModule.sdkRootCandidates(home: home) {
                for sub in ["platforms", "build-tools", "ndk", "cmake", "system-images"] {
                    roots.append("\(sdkRoot)/\(sub)")
                }
            }
            return roots
        case .largeFiles, .duplicateFiles:
            return [home]
        }
    }
}
