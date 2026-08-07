import Foundation

public enum ModuleIdentifier: String, CaseIterable, Codable, Sendable {
    case developerCaches = "dev-caches"
    case iosSimulators = "simulators"
    case xcode = "xcode"
    case aiToolCaches = "ai-caches"
    case applicationCaches = "app-caches"
    case largeFiles = "large-files"
    case duplicateFiles = "duplicate-files"
    case docker = "docker"
    case systemLogs = "system-logs"
    case androidSDK = "android-sdk"

    public var displayName: String {
        switch self {
        case .developerCaches: return "开发者缓存"
        case .iosSimulators: return "iOS 模拟器"
        case .xcode: return "Xcode"
        case .aiToolCaches: return "AI 工具缓存"
        case .applicationCaches: return "应用缓存"
        case .largeFiles: return "大文件"
        case .duplicateFiles: return "重复文件"
        case .docker: return "Docker"
        case .systemLogs: return "系统日志"
        case .androidSDK: return "Android SDK"
        }
    }

    public var description: String {
        switch self {
        case .developerCaches:
            return "Gradle/Maven/npm/Cargo/Go/pip/SwiftPM/Homebrew 缓存"
        case .iosSimulators:
            return "旧版本 iOS 模拟器"
        case .xcode:
            return "DerivedData/Archives/DeviceSupport"
        case .aiToolCaches:
            return "AI 编程助手和智能工具缓存"
        case .applicationCaches:
            return "~/Library/Caches 应用缓存"
        case .largeFiles:
            return "主目录下 >100MB 的大文件"
        case .duplicateFiles:
            return "相同内容的重复文件"
        case .docker:
            return "Docker Desktop 磁盘镜像和缓存"
        case .systemLogs:
            return "应用日志、诊断报告和崩溃日志"
        case .androidSDK:
            return "旧版 platforms/build-tools/NDK/system-images/AVD"
        }
    }
}
