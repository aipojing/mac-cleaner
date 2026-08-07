import Foundation

public struct ModuleRegistry {
    public static func allModules() -> [any CleanerModule] {
        [
            DeveloperCachesModule(),
            IOSSimulatorsModule(),
            XcodeModule(),
            AIToolCachesModule(),
            ApplicationCachesModule(),
            DockerModule(),
            SystemLogsModule(),
            AndroidSDKModule(),
            LargeFileScannerModule(),
        ]
    }

    public static func availableModules() -> [any CleanerModule] {
        allModules().filter { $0.isAvailable() }
    }

    public static func module(for id: ModuleIdentifier) -> (any CleanerModule)? {
        allModules().first { $0.identifier == id }
    }

    public static func modules(for ids: [ModuleIdentifier]) -> [any CleanerModule] {
        let idSet = Set(ids)
        return allModules().filter { idSet.contains($0.identifier) }
    }
}
