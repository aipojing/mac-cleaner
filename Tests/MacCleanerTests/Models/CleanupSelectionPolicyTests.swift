import Testing
@testable import MacCleanerCore

@Suite("Cleanup selection policy")
struct CleanupSelectionPolicyTests {
    @Test("初始状态不选择任何项")
    func initialSelectionIsEmpty() {
        let items = [
            CleanableItem(
                path: "/tmp/a",
                displayName: "a",
                size: 10,
                category: .developerCaches
            ),
            CleanableItem(
                path: "/tmp/b",
                displayName: "b",
                size: 20,
                category: .systemLogs
            ),
        ]

        #expect(CleanupSelectionPolicy.initialSelection(from: items).isEmpty)
    }

    @Test("用户点击全选才返回可执行项")
    func explicitSelectAllUsesEligibility() {
        let items = [
            CleanableItem(
                path: "/tmp/a",
                displayName: "a",
                size: 10,
                category: .developerCaches
            ),
            CleanableItem(
                path: "/",
                displayName: "root",
                size: 20,
                category: .systemLogs
            ),
        ]

        let ids = CleanupSelectionPolicy.selectAll(
            from: items,
            isEligible: { $0.path != "/" }
        )

        #expect(ids == Set([items[0].id]))
    }
}
