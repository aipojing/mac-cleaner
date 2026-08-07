import ArgumentParser
import Foundation
import MacCleanerCore

public struct ListCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出可用清理模块"
    )

    @Flag(name: .long, help: "JSON 格式输出")
    var json: Bool = false

    public init() {}

    public mutating func run() async throws {
        let modules = ModuleRegistry.allModules()

        if json {
            var output: [[String: Any]] = []
            for module in modules {
                output.append([
                    "id": module.identifier.rawValue,
                    "name": module.displayName,
                    "description": module.description,
                    "available": module.isAvailable(),
                ])
            }
            if let data = try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print("\(ANSIStyle.bold)📦 可用清理模块\(ANSIStyle.reset)\n")

        TableRenderer.render(
            columns: [
                .init(header: "ID", minWidth: 12),
                .init(header: "名称", minWidth: 12),
                .init(header: "说明", minWidth: 30),
                .init(header: "状态", minWidth: 6),
            ],
            rows: modules.map { module in
                let status = module.isAvailable()
                    ? "\(ANSIStyle.green)可用\(ANSIStyle.reset)"
                    : "\(ANSIStyle.dim)不可用\(ANSIStyle.reset)"
                return [
                    module.identifier.rawValue,
                    module.displayName,
                    module.description,
                    status,
                ]
            }
        )

        print("\n\(ANSIStyle.dim)使用 'mac-cleaner scan --modules <id>' 扫描指定模块\(ANSIStyle.reset)")
    }
}
