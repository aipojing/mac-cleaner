import ArgumentParser
import Foundation
import MacCleanerCore

public struct ScanCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "扫描磁盘占用"
    )

    @Option(name: .long, help: "指定模块，逗号分隔 (dev-caches,simulators,xcode,ai-caches,app-caches,large-files)")
    var modules: String?

    @Flag(name: .long, help: "JSON 格式输出")
    var json: Bool = false

    public init() {}

    public mutating func run() async throws {
        let selectedModules: [any CleanerModule]
        if let moduleList = modules {
            let names = moduleList.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            var ids: [ModuleIdentifier] = []
            var unknown: [String] = []
            for name in names {
                if let id = ModuleIdentifier(rawValue: name) {
                    ids.append(id)
                } else {
                    unknown.append(name)
                }
            }
            guard unknown.isEmpty else {
                throw ValidationError(
                    "未识别的模块: \(unknown.joined(separator: ", "))。可用模块: \(ModuleIdentifier.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            selectedModules = ModuleRegistry.modules(for: ids).filter { $0.isAvailable() }
        } else {
            selectedModules = ModuleRegistry.availableModules()
        }

        if selectedModules.isEmpty {
            print("没有可用的清理模块")
            return
        }

        if !json {
            print("\(ANSIStyle.bold)🔍 开始扫描...\(ANSIStyle.reset)\n")
        }

        // 统一扫描入口：共享 ScanContext，模块级有界并发
        let coordinator = ScanCoordinator(modules: selectedModules)
        let scanned = try await coordinator.scan()

        var allResults: [ScanResult] = []
        let filter = ScanResultFilter(exclusionManager: ExclusionManager.shared)
        for result in scanned {
            let filtered = await filter.apply(to: result)
            allResults.append(filtered)
            if !json {
                print("  扫描 \(filtered.module.displayName)... \(ANSIStyle.green)✔\(ANSIStyle.reset) \(filtered.items.count) 项, \(ANSIStyle.coloredSize(filtered.totalSize))")
            }
        }

        if json {
            printJSON(results: allResults)
        } else {
            printTable(results: allResults)
        }
    }

    private func printTable(results: [ScanResult]) {
        print("")
        TableRenderer.render(
            columns: [
                .init(header: "模块", minWidth: 16),
                .init(header: "项目数", minWidth: 6, alignment: .right),
                .init(header: "总大小", minWidth: 10, alignment: .right),
            ],
            rows: results.map { result in
                [
                    result.module.displayName,
                    "\(result.items.count)",
                    ANSIStyle.coloredSize(result.totalSize),
                ]
            }
        )

        let totalSize = PhysicalSizeCalculator.uniqueAllocatedBytes(in: results.flatMap(\.items))
        print("")
        print("\(ANSIStyle.bold)全部候选\(ANSIStyle.reset): \(ANSIStyle.coloredSize(totalSize))")
    }

    private func printJSON(results: [ScanResult]) {
        var output: [[String: Any]] = []
        for result in results {
            var moduleData: [String: Any] = [
                "module": result.module.rawValue,
                "totalSize": result.totalSize,
                "itemCount": result.items.count,
            ]
            var itemsData: [[String: Any]] = []
            for item in result.items {
                // 只输出原始事实，不输出伪装成本地判断的 risk/recommended
                itemsData.append([
                    "path": item.path,
                    "displayName": item.displayName,
                    "size": item.size,
                    "subcategory": item.subcategory ?? "",
                    "evidenceTags": item.evidenceTags,
                ])
            }
            moduleData["items"] = itemsData
            output.append(moduleData)
        }

        if let data = try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
