import Foundation

public struct ModuleRegistry {
    public static func allModules(
        largeFileMinimumAllocatedSize: Int64 = LargeFileScannerModule.defaultMinimumAllocatedSize
    ) -> [any CleanerModule] {
        [
            DeveloperCachesModule(),
            IOSSimulatorsModule(),
            XcodeModule(),
            AIToolCachesModule(),
            ApplicationCachesModule(),
            DockerModule(),
            SystemLogsModule(),
            AndroidSDKModule(),
            LargeFileScannerModule(minAllocatedSize: largeFileMinimumAllocatedSize),
        ]
    }

    public static func availableModules() -> [any CleanerModule] {
        allModules().filter { $0.isAvailable() }
    }

    public static func module(for id: ModuleIdentifier) -> (any CleanerModule)? {
        allModules().first { $0.identifier == id }
    }

    public static func modules(
        for ids: [ModuleIdentifier],
        largeFileMinimumAllocatedSize: Int64 = LargeFileScannerModule.defaultMinimumAllocatedSize
    ) -> [any CleanerModule] {
        let idSet = Set(ids)
        return allModules(largeFileMinimumAllocatedSize: largeFileMinimumAllocatedSize)
            .filter { idSet.contains($0.identifier) }
    }
}
