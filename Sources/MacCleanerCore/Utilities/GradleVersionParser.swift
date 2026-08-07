import Foundation

public struct GradleVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let raw: String

    public init?(string: String) {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count > 2 ? parts[2] : 0
        self.raw = string
    }

    public static func < (lhs: GradleVersion, rhs: GradleVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public static func isVersionDirectory(_ name: String) -> Bool {
        GradleVersion(string: name) != nil
    }

    public static func latestVersion(from names: [String]) -> GradleVersion? {
        names
            .compactMap { GradleVersion(string: $0) }
            .max()
    }

    public static let sharedDirectoryPrefixes: Set<String> = [
        "modules-",
        "transforms-",
        "jars-",
        "journal-",
    ]

    public static func isSharedDirectory(_ name: String) -> Bool {
        sharedDirectoryPrefixes.contains { name.hasPrefix($0) }
    }
}
