import Testing
@testable import MacCleanerCore

@Suite("Module registry large-file configuration")
struct ModuleRegistryLargeFileConfigurationTests {
    @Test("大文件模块会接收调用方指定的最小占用阈值")
    func passesCustomLargeFileThresholdToScanner() {
        let threshold: Int64 = 200 * 1024 * 1024
        let modules = ModuleRegistry.modules(
            for: [.largeFiles],
            largeFileMinimumAllocatedSize: threshold
        )

        let scanner = modules.first as? LargeFileScannerModule
        #expect(scanner?.minimumAllocatedSize == threshold)
    }
}
