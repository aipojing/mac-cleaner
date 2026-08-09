import Foundation

public struct ApplicationCachesModule: CleanerModule {
    public let identifier = ModuleIdentifier.applicationCaches
    public let displayName = "应用缓存"
    public let description = "~/Library/Caches 应用缓存"

    private let scanner = DiskScanner()
    private let home = DiskScanner.homeDirectory
    private let minDisplaySize: Int64 = 50 * 1024 * 1024
    private let identityProvider: any FileIdentityProviding

    public init(identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()) {
        self.identityProvider = identityProvider
    }

    public func isAvailable() -> Bool {
        scanner.directoryExists(at: "\(home)/Library/Caches")
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()

        // 顺序型模块：整个元数据读取过程占用一个文件任务许可。
        return try await context.fileTaskLimiter.withPermit {
            let cachesPath = "\(home)/Library/Caches"

            let dirs = scanner.subdirectories(at: cachesPath)
                .filter { !($0 as NSString).lastPathComponent.hasPrefix("com.apple.") }

            let sizes = scanner.directorySizesBatch(paths: dirs)

            var items: [CleanableItem] = []
            for dir in dirs {
                let size = sizes[dir] ?? 0
                guard size >= minDisplaySize else { continue }

                let name = (dir as NSString).lastPathComponent
                let app = Self.knownApps[name]

                items.append(CleanableItem(
                    path: dir,
                    displayName: app?.name ?? name,
                    size: size,
                    category: .applicationCaches,
                    subcategory: name,
                    evidenceTags: ["cache", "application", app?.tag ?? "unknown-app"]
                ))
            }

            items.sort { $0.size > $1.size }

            return ScanResult(
                module: .applicationCaches,
                items: await context.recordIdentities(of: Array(items.prefix(30))),
                scanDuration: Date().timeIntervalSince(start)
            )
        }
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        // 应用缓存可能含用户数据（如第三方通讯应用的缓存），
        // 一律走废纸篓保证可恢复，不做永久删除。
        Deleter().delete(items: items, module: .applicationCaches, dryRun: dryRun, useTrash: true)
    }

    // MARK: - 已知应用映射

    private struct AppInfo {
        let name: String
        let tag: String
    }

    private static let knownApps: [String: AppInfo] = [
        // 浏览器
        "Google": .init(name: "Google Chrome", tag: "browser"),
        "com.google.Chrome": .init(name: "Google Chrome", tag: "browser"),
        "org.mozilla.firefox": .init(name: "Firefox", tag: "browser"),
        "com.microsoft.edgemac": .init(name: "Microsoft Edge", tag: "browser"),
        "com.brave.Browser": .init(name: "Brave Browser", tag: "browser"),
        "company.thebrowser.Browser": .init(name: "Arc", tag: "browser"),

        // IDE / 编辑器
        "JetBrains": .init(name: "JetBrains IDE", tag: "ide"),
        "com.microsoft.VSCode": .init(name: "VS Code", tag: "ide"),
        "dev.zed.Zed": .init(name: "Zed", tag: "ide"),
        "com.sublimetext.4": .init(name: "Sublime Text", tag: "ide"),
        "Trae": .init(name: "Trae", tag: "ide"),

        // 通讯
        "LarkShell": .init(name: "飞书", tag: "messaging"),
        "com.tencent.xinWeChat": .init(name: "微信", tag: "messaging"),
        "com.electron.lark": .init(name: "飞书", tag: "messaging"),
        "com.tencent.qq": .init(name: "QQ", tag: "messaging"),
        "com.alibaba.DingTalkMac": .init(name: "钉钉", tag: "messaging"),
        "com.slack.Slack": .init(name: "Slack", tag: "messaging"),
        "us.zoom.xos": .init(name: "Zoom", tag: "messaging"),
        "ru.keepcoder.Telegram": .init(name: "Telegram", tag: "messaging"),
        "com.skype.skype": .init(name: "Skype", tag: "messaging"),

        // 音视频 / 设计
        "com.spotify.client": .init(name: "Spotify", tag: "media"),
        "com.netease.163music": .init(name: "网易云音乐", tag: "media"),
        "com.apple.Music": .init(name: "Apple Music", tag: "media"),
        "com.bohemiancoding.sketch3": .init(name: "Sketch", tag: "media"),
        "com.figma.Desktop": .init(name: "Figma", tag: "media"),

        // 包管理 / 开发工具
        "Yarn": .init(name: "Yarn 缓存", tag: "app"),
        "Homebrew": .init(name: "Homebrew 缓存", tag: "app"),
        "微信开发者工具": .init(name: "微信开发者工具", tag: "ide"),
        "ms-playwright": .init(name: "Playwright 浏览器", tag: "app"),
        "CocoaPods": .init(name: "CocoaPods 缓存", tag: "app"),
        "pnpm": .init(name: "pnpm 缓存", tag: "app"),

        // 其他常见
        "com.docker.docker": .init(name: "Docker Desktop", tag: "app"),
        "com.1password.1password": .init(name: "1Password", tag: "app"),
        "com.raycast.macos": .init(name: "Raycast", tag: "app"),
        "com.notion.id": .init(name: "Notion", tag: "app"),
    ]
}
