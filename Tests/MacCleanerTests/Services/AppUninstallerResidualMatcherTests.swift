import Testing
@testable import MacCleanerCore

@Suite("App residual matcher")
struct AppUninstallerResidualMatcherTests {
    @Test(arguments: [
        ("com.acme.notes.plist", "com.acme.notes", true),
        ("com.acme.notes.helper.plist", "com.acme.notes", true),
        ("com.acme.notes-backup.plist", "com.acme.notes", true),
        ("com.acme.notesplus.plist", "com.acme.notes", false),
        ("org.example.com.acme.notes.plist", "com.acme.notes", false),
    ])
    func bundleBoundary(candidate: String, bundleID: String, expected: Bool) {
        #expect(AppResidualMatcher.matchesFilename(candidate, bundleID: bundleID) == expected)
    }

    @Test("普通 App 名称不使用 contains")
    func appNameDoesNotMatchUnrelatedName() {
        #expect(!AppResidualMatcher.matchesAppNameFilename("NotesBackup.plist", appName: "Notes"))
        #expect(AppResidualMatcher.matchesAppNameFilename("Notes.plist", appName: "Notes"))
    }

    @Test("Group container 以 group. 前缀加 bundle ID 边界匹配")
    func groupContainerBoundary() {
        #expect(AppResidualMatcher.matchesGroupContainer("group.com.acme.notes", bundleID: "com.acme.notes"))
        #expect(AppResidualMatcher.matchesGroupContainer("group.com.acme.notes.shared", bundleID: "com.acme.notes"))
        #expect(!AppResidualMatcher.matchesGroupContainer("group.com.acme.notesplus", bundleID: "com.acme.notes"))
        #expect(!AppResidualMatcher.matchesGroupContainer("com.acme.notes", bundleID: "com.acme.notes"))
    }

    @Test("LaunchAgent plist 必须解析 Label 或程序路径后才匹配")
    func launchAgentRequiresIdentity() {
        // Label 边界匹配
        #expect(AppResidualMatcher.matchesLaunchAgentLabel("com.acme.notes.helper", bundleID: "com.acme.notes"))
        #expect(!AppResidualMatcher.matchesLaunchAgentLabel("com.acme.notesplus", bundleID: "com.acme.notes"))
        // 程序路径位于 app bundle 内
        #expect(AppResidualMatcher.launchAgentProgramIsInsideAppBundle(
            programPath: "/Applications/Notes.app/Contents/MacOS/NotesHelper",
            appPath: "/Applications/Notes.app"
        ))
        #expect(!AppResidualMatcher.launchAgentProgramIsInsideAppBundle(
            programPath: "/usr/local/bin/notes-helper",
            appPath: "/Applications/Notes.app"
        ))
    }
}
