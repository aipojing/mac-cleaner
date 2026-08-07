import Foundation

public actor AppUninstallerService {
    private let scanner: DiskScanner
    private let home: String
    private let identityProvider: any FileIdentityProviding

    public init(
        scanner: DiskScanner = DiskScanner(),
        identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()
    ) {
        self.scanner = scanner
        self.home = DiskScanner.homeDirectory
        self.identityProvider = identityProvider
    }

    // MARK: - 删除策略

    /// App bundle 只允许 /Applications 与 ~/Applications 的直接 .app 子项。
    private var appBundlePolicy: DeletionPolicy {
        DeletionPolicy(
            allowedRoots: ["/Applications", "\(home)/Applications"],
            protectedExactPaths: ["/", home],
            protectedSubtrees: Self.protectedSubtrees
        )
    }

    /// 残留只允许明确的 Application Support、Preferences、Caches、Logs、
    /// LaunchAgents、LaunchDaemons、Saved Application State、Containers、
    /// Group Containers、Application Scripts、HTTPStorages、WebKit 与
    /// DiagnosticReports 根目录。
    private var residualPolicy: DeletionPolicy {
        DeletionPolicy(
            allowedRoots: [
                "\(home)/Library/Application Support",
                "\(home)/Library/Preferences",
                "\(home)/Library/Caches",
                "\(home)/Library/Logs",
                "\(home)/Library/LaunchAgents",
                "/Library/LaunchDaemons",
                "\(home)/Library/Saved Application State",
                "\(home)/Library/Containers",
                "\(home)/Library/Group Containers",
                "\(home)/Library/Application Scripts",
                "\(home)/Library/HTTPStorages",
                "\(home)/Library/WebKit",
                "\(home)/Library/Logs/DiagnosticReports",
                "/Library/Logs/DiagnosticReports",
            ],
            protectedExactPaths: ["/", home],
            protectedSubtrees: Self.protectedSubtrees
        )
    }

    private static let protectedSubtrees = [
        "/System", "/usr/bin", "/usr/lib", "/usr/sbin", "/usr/share",
        "/bin", "/sbin", "/private/var/db",
    ]

    private func makeGuard(for policy: DeletionPolicy) -> DeletionGuard {
        DeletionGuard(
            allowedRoots: policy.allowedRoots,
            identityProvider: identityProvider,
            protectedExactPaths: policy.protectedExactPaths,
            protectedSubtrees: policy.protectedSubtrees
        )
    }

    // MARK: - 扫描已安装应用

    public func scanApplications() async -> [InstalledApp] {
        let appDirs = ["/Applications", "\(home)/Applications"]
        var apps: [InstalledApp] = []

        for dir in appDirs {
            guard scanner.directoryExists(at: dir) else { continue }
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            let appPaths = contents
                .filter { $0.hasSuffix(".app") }
                .map { (dir as NSString).appendingPathComponent($0) }

            // 并行计算应用大小
            let sizes = scanner.directorySizesBatch(paths: appPaths)

            for appPath in appPaths {
                guard let app = parseApp(at: appPath, size: sizes[appPath] ?? 0) else { continue }
                apps.append(app)
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func parseApp(at path: String, size: Int64) -> InstalledApp? {
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        guard !bundleID.isEmpty else { return nil }

        let name = Self.resolvedName(plist: plist, bundle: Bundle(path: path), path: path)
        let version = plist["CFBundleShortVersionString"] as? String ?? ""

        let iconFile = plist["CFBundleIconFile"] as? String
        let iconPath = iconFile.map {
            (path as NSString).appendingPathComponent("Contents/Resources/\($0)")
        }

        // 记录扫描身份；失败时保持 nil，卸载确认页禁用该条目选择。
        let identity = try? identityProvider.identity(at: path)

        return InstalledApp(
            name: name, bundleID: bundleID, version: version,
            path: path, bundleSize: size, iconPath: iconPath,
            fileIdentity: identity
        )
    }

    /// 解析应用显示名：优先本地化 InfoPlist.strings（如「微信开发者工具」），
    /// 再退到 Info.plist 的 CFBundleDisplayName/CFBundleName，最后用文件名。
    static func resolvedName(plist: [String: Any], bundle: Bundle?, path: String) -> String {
        let localized = bundle?.localizedInfoDictionary
        return localized?["CFBundleDisplayName"] as? String
            ?? plist["CFBundleDisplayName"] as? String
            ?? localized?["CFBundleName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - 查找残留文件

    public func findResiduals(for app: InstalledApp) async -> AppResidualFiles {
        let locations: [(id: String, label: String, paths: [String])] = [
            ("app-support", "Application Support", [
                "\(home)/Library/Application Support/\(app.bundleID)",
                "\(home)/Library/Application Support/\(app.name)",
            ]),
            ("preferences", "Preferences",
                findMatchingPreferences(appName: app.name, bundleID: app.bundleID)
            ),
            ("caches", "Caches", [
                "\(home)/Library/Caches/\(app.bundleID)",
            ]),
            ("logs", "Logs", [
                "\(home)/Library/Logs/\(app.bundleID)",
                "\(home)/Library/Logs/\(app.name)",
            ]),
            ("launch-agents", "LaunchAgents",
                findMatchingLaunchAgents(app: app)
            ),
            ("launch-daemons", "LaunchDaemons",
                findMatchingLaunchDaemons(app: app)
            ),
            ("saved-state", "Saved Application State", [
                "\(home)/Library/Saved Application State/\(app.bundleID).savedState",
            ]),
            ("containers", "Containers", [
                "\(home)/Library/Containers/\(app.bundleID)",
            ]),
            ("group-containers", "Group Containers",
                findMatchingGroupContainers(bundleID: app.bundleID)
            ),
            ("app-scripts", "Application Scripts", [
                "\(home)/Library/Application Scripts/\(app.bundleID)",
            ]),
            ("http-storages", "HTTPStorages", [
                "\(home)/Library/HTTPStorages/\(app.bundleID)",
            ]),
            ("webkit", "WebKit", [
                "\(home)/Library/WebKit/\(app.bundleID)",
            ]),
            ("crash-reports", "Crash Reports",
                findMatchingCrashReports(appName: app.name, bundleID: app.bundleID)
            ),
        ]

        let groups = await withTaskGroup(of: ResidualGroup?.self) { group in
            for loc in locations {
                let locID = loc.id
                let locLabel = loc.label
                let locPaths = loc.paths
                group.addTask {
                    let items = self.probeLocation(paths: locPaths)
                    guard !items.isEmpty else { return nil }
                    return ResidualGroup(id: locID, label: locLabel, items: items)
                }
            }

            var results: [ResidualGroup] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        return AppResidualFiles(groups: groups)
    }

    private nonisolated func probeLocation(paths: [String]) -> [ResidualItem] {
        let fm = FileManager.default
        var items: [ResidualItem] = []

        for path in paths {
            guard fm.fileExists(atPath: path) else { continue }
            let name = (path as NSString).lastPathComponent
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            let size: Int64 = isDir.boolValue ? scanner.directorySize(at: path) : {
                let attrs = try? fm.attributesOfItem(atPath: path)
                return attrs?[.size] as? Int64 ?? 0
            }()
            // 记录扫描身份；失败时保持 nil，卸载执行会被 guard 拒绝。
            let identity = try? identityProvider.identity(at: path)
            items.append(ResidualItem(path: path, name: name, size: size, fileIdentity: identity))
        }

        return items
    }

    // MARK: - 边界匹配（替代旧子串匹配）

    /// Preferences 目录：bundle ID 边界匹配或精确 App 名匹配。
    private func findMatchingPreferences(appName: String, bundleID: String) -> [String] {
        let prefPath = "\(home)/Library/Preferences"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: prefPath) else { return [] }
        return contents
            .filter { filename in
                AppResidualMatcher.matchesFilename(filename, bundleID: bundleID)
                    || AppResidualMatcher.matchesAppNameFilename(filename, appName: appName)
            }
            .map { (prefPath as NSString).appendingPathComponent($0) }
    }

    /// LaunchAgents：解析 plist 的 Label / Program / ProgramArguments，
    /// 只有 bundle ID 边界匹配或程序路径位于 app bundle 内才返回。
    private func findMatchingLaunchAgents(app: InstalledApp) -> [String] {
        matchingLaunchItems(
            directory: "\(home)/Library/LaunchAgents",
            app: app
        )
    }

    private func findMatchingLaunchDaemons(app: InstalledApp) -> [String] {
        matchingLaunchItems(
            directory: "/Library/LaunchDaemons",
            app: app
        )
    }

    private func matchingLaunchItems(directory: String, app: InstalledApp) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }

        var results: [String] = []
        for filename in contents where filename.hasSuffix(".plist") {
            let path = (directory as NSString).appendingPathComponent(filename)
            guard launchItemMatches(path: path, app: app) else { continue }
            results.append(path)
        }
        return results
    }

    private func launchItemMatches(path: String, app: InstalledApp) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }

        // 1) Label 边界匹配
        if let label = plist["Label"] as? String,
           AppResidualMatcher.matchesLaunchAgentLabel(label, bundleID: app.bundleID) {
            return true
        }

        // 2) Program 或 ProgramArguments[0] 位于 app bundle 内
        let programPaths: [String]
        if let program = plist["Program"] as? String {
            programPaths = [program]
        } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
            programPaths = [first]
        } else {
            programPaths = []
        }
        return programPaths.contains {
            AppResidualMatcher.launchAgentProgramIsInsideAppBundle(programPath: $0, appPath: app.path)
        }
    }

    /// Group Containers：只接受 "group.<bundleID>" 或 "group.<bundleID>.<suffix>"。
    private func findMatchingGroupContainers(bundleID: String) -> [String] {
        let gcPath = "\(home)/Library/Group Containers"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: gcPath) else { return [] }
        return contents
            .filter { AppResidualMatcher.matchesGroupContainer($0, bundleID: bundleID) }
            .map { (gcPath as NSString).appendingPathComponent($0) }
    }

    /// 崩溃报告：只接受精确 app 名 stem 或 bundle ID 边界，不使用任意位置子串。
    private func findMatchingCrashReports(appName: String, bundleID: String) -> [String] {
        var results: [String] = []
        let reportDirs = [
            "\(home)/Library/Logs/DiagnosticReports",
            "/Library/Logs/DiagnosticReports",
        ]
        for dir in reportDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let matches = contents.filter {
                AppResidualMatcher.matchesAppNameFilename($0, appName: appName)
                    || AppResidualMatcher.matchesFilename($0, bundleID: bundleID)
            }
            results.append(contentsOf: matches.map { (dir as NSString).appendingPathComponent($0) })
        }
        return results
    }

    // MARK: - 卸载

    public func uninstall(app: InstalledApp, residualItems: [ResidualItem]) -> UninstallReport {
        let fm = FileManager.default
        var bytesMovedToTrash: Int64 = 0
        var appRemoved = false
        var removed = 0
        var failures = 0

        // 移动 .app 到废纸篓。执行前验证：
        // 允许根（/Applications、~/Applications）+ 直接 .app 子项 + 扫描身份一致。
        let appGuard = makeGuard(for: appBundlePolicy)
        let appParent = (app.path as NSString).deletingLastPathComponent
        let isDirectAppBundle = app.path.hasSuffix(".app")
            && (appParent == "/Applications" || appParent == "\(home)/Applications")

        if isDirectAppBundle,
           app.fileIdentity != nil,
           let _ = try? appGuard.validate(path: app.path, expectedIdentity: app.fileIdentity) {
            // 删除前检查存在性（guard 已验证，这里防御并发变化）
            if fm.fileExists(atPath: app.path) {
                do {
                    try fm.trashItem(at: URL(fileURLWithPath: app.path), resultingItemURL: nil)
                    bytesMovedToTrash += app.bundleSize
                    appRemoved = true
                } catch {
                    failures += 1
                }
            } else {
                failures += 1
            }
        } else {
            failures += 1
        }

        // 删除残留文件：每个目标必须同时满足发现时 identity 与执行时 identity 一致。
        let residualGuard = makeGuard(for: residualPolicy)
        for item in residualItems {
            guard item.fileIdentity != nil,
                  let _ = try? residualGuard.validate(path: item.path, expectedIdentity: item.fileIdentity)
            else {
                failures += 1
                continue
            }
            guard fm.fileExists(atPath: item.path) else { continue }
            do {
                try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                bytesMovedToTrash += item.size
                removed += 1
            } catch {
                failures += 1
            }
        }

        return UninstallReport(
            appName: app.name, appRemoved: appRemoved,
            residualsRemoved: removed, failures: failures,
            bytesMovedToTrash: bytesMovedToTrash
        )
    }
}

/// 应用卸载服务抽象：ViewModel 依赖本协议，测试可替换为内存实现。
public protocol AppUninstalling: Sendable {
    func scanApplications() async -> [InstalledApp]
    func findResiduals(for app: InstalledApp) async -> AppResidualFiles
    func uninstall(app: InstalledApp, residualItems: [ResidualItem]) async -> UninstallReport
}

extension AppUninstallerService: AppUninstalling {}
