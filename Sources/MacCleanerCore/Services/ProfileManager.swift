import Foundation

/// 清理方案管理器：内置方案 + 用户自定义方案的持久化
public actor ProfileManager {
    public static let shared = ProfileManager()

    private var userProfiles: [CleaningProfile]
    private let storePath: String

    public init(storePath: String? = nil) {
        self.storePath = storePath ?? Self.defaultStorePath()
        self.userProfiles = Self.load(from: self.storePath)
    }

    // MARK: - 查询

    /// 所有可用方案（内置 + 用户自定义）
    public var allProfiles: [CleaningProfile] {
        CleaningProfile.builtInProfiles + userProfiles
    }

    /// 按名称查找方案
    public func profile(named name: String) -> CleaningProfile? {
        allProfiles.first { $0.name == name }
    }

    /// 按 ID 查找方案
    public func profile(id: UUID) -> CleaningProfile? {
        allProfiles.first { $0.id == id }
    }

    // MARK: - 用户方案管理

    public func addProfile(_ profile: CleaningProfile) {
        userProfiles.append(profile)
        save()
    }

    public func removeProfile(id: UUID) {
        userProfiles.removeAll { $0.id == id }
        save()
    }

    public func updateProfile(_ profile: CleaningProfile) {
        guard let index = userProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        userProfiles[index] = profile
        save()
    }

    /// 用户自定义方案列表
    public var customProfiles: [CleaningProfile] {
        userProfiles
    }

    // MARK: - 持久化

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(userProfiles) else { return }

        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    private static func load(from path: String) -> [CleaningProfile] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([CleaningProfile].self, from: data)) ?? []
    }

    private static func defaultStorePath() -> String {
        let home = DiskScanner.homeDirectory
        return "\(home)/Library/Application Support/MacCleaner/profiles.json"
    }
}
