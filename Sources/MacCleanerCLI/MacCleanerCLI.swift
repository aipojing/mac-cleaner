import ArgumentParser
import MacCleanerCore

@main
struct MacCleaner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-cleaner",
        abstract: "macOS 磁盘清理工具",
        version: "1.0.0",
        subcommands: [ScanCommand.self, CleanCommand.self, ListCommand.self],
        defaultSubcommand: nil
    )

    mutating func run() async throws {
        let interactive = InteractiveCommand()
        try await interactive.run()
    }
}
