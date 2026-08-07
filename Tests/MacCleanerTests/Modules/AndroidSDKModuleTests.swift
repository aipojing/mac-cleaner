import Foundation
import Testing
@testable import MacCleanerCore

@Suite("AndroidSDKModule Tests")
struct AndroidSDKModuleTests {

    // MARK: - SDKVersion Parsing

    @Test("Parses valid SDK version strings")
    func parsesValidVersions() {
        let v1 = SDKVersion("35.0.0")
        #expect(v1 != nil)
        #expect(v1?.components == [35, 0, 0])

        let v2 = SDKVersion("3.22.1")
        #expect(v2 != nil)
        #expect(v2?.components == [3, 22, 1])

        let v3 = SDKVersion("21.0.6113669")
        #expect(v3 != nil)
        #expect(v3?.components == [21, 0, 6113669])
    }

    @Test("Returns nil for invalid version strings")
    func rejectsInvalidVersions() {
        #expect(SDKVersion("") == nil)
        #expect(SDKVersion("abc") == nil)
        #expect(SDKVersion("not-a-version") == nil)
    }

    @Test("Compares SDK versions correctly")
    func comparesVersions() {
        let v35 = SDKVersion("35.0.0")!
        let v34 = SDKVersion("34.0.0")!
        let v30 = SDKVersion("30.0.3")!
        let v302 = SDKVersion("30.0.2")!

        #expect(v35 > v34)
        #expect(v34 > v30)
        #expect(v30 > v302)
        #expect(v302 < v35)
    }

    @Test("Handles different component counts in version comparison")
    func comparesDifferentLengthVersions() {
        let v3221 = SDKVersion("3.22.1")!
        let v36 = SDKVersion("3.6.4111459")!

        // 3.22.1 > 3.6.x because 22 > 6
        #expect(v3221 > v36)
    }

    @Test("Equal versions compare correctly")
    func equalVersions() {
        let v1 = SDKVersion("35.0.0")!
        let v2 = SDKVersion("35.0.0")!
        #expect(v1 == v2)
        #expect(!(v1 < v2))
        #expect(!(v1 > v2))
    }

    // MARK: - API Level Parsing

    @Test("Parses API level from android-XX format")
    func parsesAPILevel() {
        #expect(AndroidSDKModule.parseAPILevel(from: "android-35") == 35)
        #expect(AndroidSDKModule.parseAPILevel(from: "android-21") == 21)
        #expect(AndroidSDKModule.parseAPILevel(from: "android-36") == 36)
    }

    @Test("Returns nil for invalid API level strings")
    func rejectsInvalidAPILevel() {
        #expect(AndroidSDKModule.parseAPILevel(from: "ios-18") == nil)
        #expect(AndroidSDKModule.parseAPILevel(from: "android-abc") == nil)
        #expect(AndroidSDKModule.parseAPILevel(from: "") == nil)
        #expect(AndroidSDKModule.parseAPILevel(from: "not-a-number") == nil)
    }

    // MARK: - Module Identity

    @Test("Module has correct identifier and display name")
    func moduleIdentity() {
        let module = AndroidSDKModule()
        #expect(module.identifier == .androidSDK)
        #expect(module.displayName == "Android SDK")
    }

    // MARK: - Integration: Scan on Real System

    @Test("Scan returns items when Android SDK is present")
    func scanFindsRealSDK() async throws {
        let module = AndroidSDKModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        #expect(result.module == .androidSDK)
        // Should find at least some items on a machine with Android SDK
        #expect(!result.items.isEmpty)
    }

    @Test("Scan items have valid fields")
    func scanItemsAreValid() async throws {
        let module = AndroidSDKModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())
        for item in result.items {
            #expect(item.category == .androidSDK)
            #expect(!item.path.isEmpty)
            #expect(!item.displayName.isEmpty)
            #expect(item.size > 0)
            #expect(item.subcategory != nil)
        }
    }

    @Test("SDK items carry Android evidence tags without version judgment")
    func sdkEvidenceTags() async throws {
        let module = AndroidSDKModule()
        guard module.isAvailable() else { return }

        let result = try await module.scan(context: ScanContext())

        for item in result.items {
            #expect(item.evidenceTags.contains("developer-tool"),
                    "Missing developer-tool tag: \(item.displayName)")
            #expect(item.evidenceTags.contains("android"),
                    "Missing android tag: \(item.displayName)")
        }
    }

    @Test("SDK root discovery finds the Android SDK directory")
    func sdkRootDiscovery() {
        let module = AndroidSDKModule()
        let root = module.findSDKRoot()

        // If ANDROID_HOME is set or common paths exist, should find it
        if ProcessInfo.processInfo.environment["ANDROID_HOME"] != nil {
            #expect(root != nil)
        }
    }

    @Test("Clean method returns report with correct module identifier")
    func cleanReturnsCorrectModule() async throws {
        let module = AndroidSDKModule()
        let report = try await module.clean(items: [], dryRun: true)
        #expect(report.module == .androidSDK)
        #expect(report.dryRun == true)
    }

    @Test("NDK items are found when ndk directory exists")
    func ndkItemsFound() async throws {
        let module = AndroidSDKModule()
        guard module.isAvailable(), module.findSDKRoot() != nil else { return }

        let result = try await module.scan(context: ScanContext())
        let ndkItems = result.items.filter { $0.subcategory == "ndk" }

        if !ndkItems.isEmpty {
            // NDK items should have large sizes (typically > 100MB each)
            for item in ndkItems {
                #expect(item.displayName.hasPrefix("NDK"))
            }
        }
    }
}
