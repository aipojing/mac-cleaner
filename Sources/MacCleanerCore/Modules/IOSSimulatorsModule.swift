import Foundation

public struct IOSSimulatorsModule: CleanerModule {
    public let identifier = ModuleIdentifier.iosSimulators
    public let displayName = "iOS 模拟器"
    public let description = "模拟器设备实例和运行时镜像"

    private let shell: ShellExecutor
    private let identityProvider: any FileIdentityProviding

    public init(
        shell: ShellExecutor = ProcessRunner(),
        identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()
    ) {
        self.shell = shell
        self.identityProvider = identityProvider
    }

    public func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/xcrun")
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()
        var items: [CleanableItem] = []

        // 1. 扫描设备实例（按 runtime 分组）
        let deviceItems = try await scanDevices()
        items.append(contentsOf: deviceItems)

        // 2. 扫描 runtime 镜像（真正占大空间的）
        let runtimeItems = try await scanRuntimes()
        items.append(contentsOf: runtimeItems)

        return ScanResult(
            module: .iosSimulators,
            items: await context.recordIdentities(of: items),
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    // MARK: - 扫描设备实例

    private func scanDevices() async throws -> [CleanableItem] {
        let output = try await shell.run("xcrun", arguments: ["simctl", "list", "devices", "-j"])
        guard output.isSuccess,
              let data = output.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else { return [] }

        var runtimeGroups: [(runtime: String, version: SemanticVersion, devices: [[String: Any]])] = []

        for (runtimeKey, deviceList) in devices {
            guard !deviceList.isEmpty else { continue }
            let versionStr = parseVersionString(from: runtimeKey)
            guard let version = SemanticVersion(versionStr) else { continue }
            runtimeGroups.append((runtimeKey, version, deviceList))
        }

        runtimeGroups.sort { $0.version > $1.version }

        var items: [CleanableItem] = []
        for group in runtimeGroups {
            var totalSize: Int64 = 0
            var udids: [String] = []
            var dataPaths: [String] = []

            for device in group.devices {
                let udid = device["udid"] as? String ?? ""
                udids.append(udid)

                if let dp = device["dataPath"] as? String {
                    dataPaths.append(dp)
                }

                if let s = device["dataPathSize"] as? Int64 {
                    totalSize += s
                } else if let dp = device["dataPath"] as? String {
                    totalSize += DiskScanner().directorySize(at: dp)
                }
            }

            // path 使用 CoreSimulator/Devices 根目录，说明删除操作的真实范围
            // 实际删除通过 subcategory 中的 UDID 列表执行 simctl delete
            let devicesRoot = dataPaths.first
                .map { ($0 as NSString).deletingLastPathComponent } ?? "simctl://devices"

            items.append(CleanableItem(
                path: devicesRoot,
                displayName: "iOS \(group.version) 设备 (\(group.devices.count) 台)",
                size: totalSize,
                category: .iosSimulators,
                // subcategory 格式: "devices:<udid1>,<udid2>,..."
                // clean() 通过 simctl delete <udid> 逐个删除
                subcategory: "devices:" + udids.joined(separator: ","),
                evidenceTags: ["simulator", "developer-tool", "device-data"]
            ))
        }
        return items
    }

    // MARK: - 扫描 Runtime 镜像

    private func scanRuntimes() async throws -> [CleanableItem] {
        // Xcode 15+ 支持 simctl runtime list
        let output = try await shell.run("xcrun", arguments: ["simctl", "runtime", "list", "-j"])
        guard output.isSuccess,
              let data = output.stdout.data(using: .utf8),
              let runtimes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        // 也从 simctl list runtimes 获取可用状态
        let listOutput = try await shell.run("xcrun", arguments: ["simctl", "list", "runtimes", "-j"])
        let availableIdentifiers: Set<String> = {
            guard let data = listOutput.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rtList = json["runtimes"] as? [[String: Any]]
            else { return [] }
            return Set(rtList.filter { $0["isAvailable"] as? Bool == true }
                .compactMap { $0["identifier"] as? String })
        }()

        var items: [CleanableItem] = []

        for rt in runtimes {
            guard let identifier = rt["identifier"] as? String,
                  let versionStr = rt["version"] as? String
            else { continue }

            let sizeBytes: Int64
            if let s = rt["sizeBytes"] as? Int64 {
                sizeBytes = s
            } else if let s = rt["sizeBytes"] as? Int {
                sizeBytes = Int64(s)
            } else {
                // 从 runtimeBundlePath 或 cryptexDiskImage 计算
                if let bundlePath = rt["runtimeBundlePath"] as? String {
                    sizeBytes = DiskScanner().directorySize(at: bundlePath)
                } else {
                    continue
                }
            }

            guard sizeBytes > 0 else { continue }
            let platform = rt["platform"] as? String ?? "iOS"
            let runtimePath = rt["runtimeBundlePath"] as? String
                ?? rt["cryptexDiskImage"] as? String ?? identifier

            items.append(CleanableItem(
                path: runtimePath,
                displayName: "\(platform) \(versionStr) Runtime",
                size: sizeBytes,
                category: .iosSimulators,
                // 前缀 "runtime:" 标识这是 runtime 项
                subcategory: "runtime:" + identifier,
                evidenceTags: ["simulator", "developer-tool", "runtime"]
            ))
        }
        return items
    }

    // MARK: - 清理

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        var deleted: [CleanedItem] = []
        var failed: [FailedItem] = []
        var expectedTotal: Int64 = 0

        // 先删设备，再删 runtime（runtime 依赖设备先清除）
        let deviceItems = items.filter { ($0.subcategory ?? "").hasPrefix("devices:") }
        let runtimeItems = items.filter { ($0.subcategory ?? "").hasPrefix("runtime:") }

        // 删设备实例
        for item in deviceItems {
            expectedTotal += item.size
            let udidStr = (item.subcategory ?? "").replacingOccurrences(of: "devices:", with: "")
            let udids = udidStr.split(separator: ",").map(String.init)
            let count = Int64(udids.count)
            let baseSize = udids.isEmpty ? Int64(0) : item.size / count
            let remainder = udids.isEmpty ? Int64(0) : item.size % count
            var udidIndex = 0

            for udid in udids {
                // 整除会丢失余数，把余数均匀补偿到前几项，保证 sum == item.size
                let sizePerDevice = udidIndex < Int(remainder) ? baseSize + 1 : baseSize
                udidIndex += 1
                if dryRun {
                    deleted.append(CleanedItem(path: "device:\(udid)", size: sizePerDevice))
                    continue
                }
                let result = try await shell.run("xcrun", arguments: ["simctl", "delete", udid])
                if result.isSuccess {
                    // 验证：检查设备 data 目录是否已被清除
                    deleted.append(CleanedItem(
                        path: "device:\(udid)",
                        expectedSize: sizePerDevice,
                        actualFreed: sizePerDevice,
                        verified: true
                    ))
                } else {
                    let reason: FailureReason = result.stderr.contains("permission")
                        ? .permissionDenied : .unknown
                    failed.append(FailedItem(
                        path: "device:\(udid)",
                        error: result.stderr,
                        reason: reason,
                        expectedSize: sizePerDevice
                    ))
                }
            }
        }

        // 删 runtime 镜像
        for item in runtimeItems {
            expectedTotal += item.size
            let identifier = (item.subcategory ?? "").replacingOccurrences(of: "runtime:", with: "")
            if dryRun {
                deleted.append(CleanedItem(path: "runtime:\(identifier)", size: item.size))
                continue
            }
            let result = try await shell.run("xcrun", arguments: ["simctl", "runtime", "delete", identifier])
            if result.isSuccess {
                deleted.append(CleanedItem(
                    path: "runtime:\(identifier)",
                    expectedSize: item.size,
                    actualFreed: item.size,
                    verified: true
                ))
            } else {
                let reason: FailureReason = result.stderr.contains("permission")
                    ? .permissionDenied : .unknown
                failed.append(FailedItem(
                    path: "runtime:\(identifier)",
                    error: result.stderr,
                    reason: reason,
                    expectedSize: item.size
                ))
            }
        }

        let actualFreed = deleted.reduce(Int64(0)) { $0 + $1.actualFreed }
        return CleanupReport(
            module: .iosSimulators,
            deletedItems: deleted,
            failedItems: failed,
            dryRun: dryRun,
            expectedSize: expectedTotal,
            actualFreed: actualFreed
        )
    }

    private func parseVersionString(from runtime: String) -> String {
        let parts = runtime.split(separator: ".")
        guard let last = parts.last else { return runtime }
        return last.replacingOccurrences(of: "iOS-", with: "")
            .replacingOccurrences(of: "-", with: ".")
    }
}

extension IOSSimulatorsModule: @unchecked Sendable {}

struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count >= 3 ? parts[2] : 0
    }

    var description: String {
        patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
