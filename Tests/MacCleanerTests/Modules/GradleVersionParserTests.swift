import Testing
@testable import MacCleanerCore

@Suite("GradleVersionParser Tests")
struct GradleVersionParserTests {

    @Test("Parses valid version strings")
    func parsesValidVersions() {
        let v1 = GradleVersion(string: "8.14")
        #expect(v1 != nil)
        #expect(v1?.major == 8)
        #expect(v1?.minor == 14)
        #expect(v1?.patch == 0)

        let v2 = GradleVersion(string: "7.4.2")
        #expect(v2 != nil)
        #expect(v2?.major == 7)
        #expect(v2?.minor == 4)
        #expect(v2?.patch == 2)
    }

    @Test("Returns nil for invalid version strings")
    func rejectsInvalidVersions() {
        #expect(GradleVersion(string: "modules-2") == nil)
        #expect(GradleVersion(string: "transforms-3") == nil)
        #expect(GradleVersion(string: "journal-1") == nil)
        #expect(GradleVersion(string: "abc") == nil)
        #expect(GradleVersion(string: "") == nil)
    }

    @Test("Compares versions correctly")
    func comparesVersions() {
        let v814 = GradleVersion(string: "8.14")!
        let v8111 = GradleVersion(string: "8.11.1")!
        let v742 = GradleVersion(string: "7.4.2")!

        #expect(v814 > v8111)
        #expect(v8111 > v742)
        #expect(v742 < v814)
    }

    @Test("Finds latest version from directory names")
    func findsLatestVersion() {
        let names = ["8.14", "8.11.1", "8.10.2", "7.4.2", "7.4", "6.1.1", "modules-2", "transforms-3"]
        let latest = GradleVersion.latestVersion(from: names)
        #expect(latest != nil)
        #expect(latest?.major == 8)
        #expect(latest?.minor == 14)
    }

    @Test("Identifies version directories")
    func identifiesVersionDirectories() {
        #expect(GradleVersion.isVersionDirectory("8.14") == true)
        #expect(GradleVersion.isVersionDirectory("7.4.2") == true)
        #expect(GradleVersion.isVersionDirectory("modules-2") == false)
        #expect(GradleVersion.isVersionDirectory("transforms-3") == false)
    }

    @Test("Identifies shared directories")
    func identifiesSharedDirectories() {
        #expect(GradleVersion.isSharedDirectory("modules-2") == true)
        #expect(GradleVersion.isSharedDirectory("transforms-3") == true)
        #expect(GradleVersion.isSharedDirectory("jars-9") == true)
        #expect(GradleVersion.isSharedDirectory("journal-1") == true)
        #expect(GradleVersion.isSharedDirectory("8.14") == false)
    }
}
