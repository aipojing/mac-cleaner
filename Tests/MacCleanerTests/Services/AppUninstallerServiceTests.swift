import Testing
import Foundation
@testable import MacCleanerCore

@Suite("AppUninstallerService Tests")
struct AppUninstallerServiceTests {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("uninstall-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("发现厂商目录下匹配产品的支持文件和缓存，不带入同厂商其他产品")
    func findsNestedVendorProductResiduals() async throws {
        let uniqueSuffix = UUID().uuidString
        let vendor = "UninstallerTestVendor\(uniqueSuffix)"
        let product = "Browser"
        let home = DiskScanner.homeDirectory
        let applicationSupportVendor = "\(home)/Library/Application Support/\(vendor)"
        let cacheVendor = "\(home)/Library/Caches/\(vendor)"
        let applicationSupportProduct = "\(applicationSupportVendor)/\(product)"
        let cacheProduct = "\(cacheVendor)/\(product)"
        let unrelatedProduct = "\(applicationSupportVendor)/OtherApp"
        defer {
            try? FileManager.default.removeItem(atPath: applicationSupportVendor)
            try? FileManager.default.removeItem(atPath: cacheVendor)
        }

        for path in [applicationSupportProduct, cacheProduct, unrelatedProduct] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let file = (path as NSString).appendingPathComponent("fixture")
            try Data(repeating: 0x1, count: 1_024).write(to: URL(fileURLWithPath: file))
        }

        let app = InstalledApp(
            name: "\(vendor) \(product)",
            bundleID: "com.\(vendor).\(product)",
            version: "1.0",
            path: "/Applications/\(product).app",
            bundleSize: 0
        )

        let residuals = await AppUninstallerService().findResiduals(for: app)
        let paths = Set(residuals.groups.flatMap(\.items).map(\.path))

        #expect(paths.contains(applicationSupportProduct))
        #expect(paths.contains(cacheProduct))
        #expect(!paths.contains(unrelatedProduct))
    }

    @Test("残留在扫描后被替换时不进入废纸篓")
    func residualIdentityChangeRefusesDeletion() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // 创建一个真实的残留文件。
        let residualPath = (dir as NSString).appendingPathComponent("com.acme.notes.plist")
        FileManager.default.createFile(atPath: residualPath, contents: Data(count: 32))

        // 构造一个过时的身份（inode 明显不同），模拟扫描后文件已被替换。
        let staleIdentity = FileIdentity(device: 999_999, inode: 42, kind: .regularFile)
        let residual = ResidualItem(
            path: residualPath, name: "com.acme.notes.plist",
            size: 32, fileIdentity: staleIdentity
        )

        // app 身份为 nil，卸载 app 会被拒绝；重点是残留同样被拒绝。
        let app = InstalledApp(
            name: "Notes", bundleID: "com.acme.notes", version: "1.0",
            path: "/Applications/Notes.app", bundleSize: 1000, fileIdentity: nil
        )

        let service = AppUninstallerService()
        let report = await service.uninstall(app: app, residualItems: [residual])

        #expect(report.residualsRemoved == 0, "身份已变化的残留不应被删除")
        #expect(report.failures >= 1)
        #expect(FileManager.default.fileExists(atPath: residualPath), "残留文件必须仍然存在")
    }

    @Test("身份缺失的残留不进入废纸篓")
    func residualWithoutIdentityRefused() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let residualPath = (dir as NSString).appendingPathComponent("com.acme.notes.plist")
        FileManager.default.createFile(atPath: residualPath, contents: Data(count: 32))

        let residual = ResidualItem(
            path: residualPath, name: "com.acme.notes.plist",
            size: 32, fileIdentity: nil
        )

        let app = InstalledApp(
            name: "Notes", bundleID: "com.acme.notes", version: "1.0",
            path: "/Applications/Notes.app", bundleSize: 1000, fileIdentity: nil
        )

        let service = AppUninstallerService()
        let report = await service.uninstall(app: app, residualItems: [residual])

        #expect(report.residualsRemoved == 0)
        #expect(FileManager.default.fileExists(atPath: residualPath))
    }
}

@Suite("App display name resolution")
struct AppDisplayNameTests {
    private func makeFixtureApp(
        infoPlist: [String: Any],
        localizedStrings: [String: String]? = nil
    ) throws -> (path: String, plist: [String: Any], bundle: Bundle?) {
        let root = NSTemporaryDirectory()
            .appending("appname-test-\(UUID().uuidString)/DemoApp.app/Contents")
        let resources = (root as NSString).appendingPathComponent("Resources")
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0
        )
        try plistData.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("Info.plist")))

        if let localizedStrings {
            let lproj = (resources as NSString).appendingPathComponent("zh-Hans.lproj")
            try FileManager.default.createDirectory(atPath: lproj, withIntermediateDirectories: true)
            let stringsData = try PropertyListSerialization.data(
                fromPropertyList: localizedStrings, format: .xml, options: 0
            )
            try stringsData.write(to: URL(fileURLWithPath: (lproj as NSString).appendingPathComponent("InfoPlist.strings")))
        }

        let appPath = (root as NSString).deletingLastPathComponent
        return (appPath, infoPlist, Bundle(path: appPath))
    }

    @Test("本地化 InfoPlist.strings 的显示名优先于 CFBundleName")
    func prefersLocalizedDisplayName() throws {
        let fixture = try makeFixtureApp(
            infoPlist: [
                "CFBundleIdentifier": "com.example.demo",
                "CFBundleName": "wechatwebdevtools",
            ],
            localizedStrings: ["CFBundleDisplayName": "微信开发者工具"]
        )
        defer { try? FileManager.default.removeItem(atPath: (fixture.path as NSString).deletingLastPathComponent) }

        let name = AppUninstallerService.resolvedName(
            plist: fixture.plist, bundle: fixture.bundle, path: fixture.path
        )
        #expect(name == "微信开发者工具")
    }

    @Test("无本地化时 CFBundleDisplayName 优先于 CFBundleName")
    func prefersDisplayNameOverBundleName() throws {
        let fixture = try makeFixtureApp(
            infoPlist: [
                "CFBundleIdentifier": "com.example.demo",
                "CFBundleName": "demo",
                "CFBundleDisplayName": "Demo App",
            ]
        )
        defer { try? FileManager.default.removeItem(atPath: (fixture.path as NSString).deletingLastPathComponent) }

        let name = AppUninstallerService.resolvedName(
            plist: fixture.plist, bundle: fixture.bundle, path: fixture.path
        )
        #expect(name == "Demo App")
    }

    @Test("全部缺失时回退到文件名")
    func fallsBackToFileName() {
        let name = AppUninstallerService.resolvedName(
            plist: ["CFBundleIdentifier": "com.example.demo"],
            bundle: nil,
            path: "/Applications/DemoApp.app"
        )
        #expect(name == "DemoApp")
    }
}
