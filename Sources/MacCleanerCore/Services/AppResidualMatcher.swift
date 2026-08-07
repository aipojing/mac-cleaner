import Foundation

/// 应用残留匹配器。
///
/// 旧实现用 `contains(bundleID)` 子串匹配，会把
/// "com.acme.notesplus" 或 "org.example.com.acme.notes" 误判为目标 App 的残留。
/// 本匹配器只做身份边界匹配，不做任何风险或推荐判断。
public enum AppResidualMatcher {
    /// bundle ID 之后允许出现的分隔符：`.-_` 和空格。
    private static let separators = CharacterSet(charactersIn: ".-_ ")

    /// 文件名是否属于指定 bundle ID（stem 以 bundle ID 开头，
    /// 且边界字符必须是分隔符）。
    ///
    /// 例：com.acme.notes.helper.plist 匹配 com.acme.notes；
    /// com.acme.notesplus.plist 不匹配。
    public static func matchesFilename(_ filename: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let stem = (filename as NSString).deletingPathExtension
        return matchesStem(stem, token: bundleID)
    }

    /// 普通 App 名称残留只接受精确名称匹配（不区分大小写），
    /// 不使用 contains。
    public static func matchesAppNameFilename(_ filename: String, appName: String) -> Bool {
        guard !appName.isEmpty else { return false }
        return (filename as NSString).deletingPathExtension
            .localizedCaseInsensitiveCompare(appName) == .orderedSame
    }

    /// Group Container 命名约定是 "group.<bundleID>" 或
    /// "group.<bundleID>.<suffix>"。不接受任意位置子串匹配。
    public static func matchesGroupContainer(_ containerName: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        guard containerName.hasPrefix("group.") else { return false }
        let rest = String(containerName.dropFirst("group.".count))
        return matchesStem(rest, token: bundleID)
    }

    /// LaunchAgent/LaunchDaemon 的 Label 边界匹配。
    public static func matchesLaunchAgentLabel(_ label: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return matchesStem(label, token: bundleID)
    }

    /// LaunchAgent 的程序路径是否位于 app bundle 内（组件边界）。
    public static func launchAgentProgramIsInsideAppBundle(programPath: String, appPath: String) -> Bool {
        guard !programPath.isEmpty, !appPath.isEmpty else { return false }
        let prefix = appPath.hasSuffix("/") ? appPath : appPath + "/"
        return programPath.hasPrefix(prefix)
    }

    /// stem 以 token 开头，且 token 之后的第一个字符（如有）是分隔符。
    private static func matchesStem(_ stem: String, token: String) -> Bool {
        guard stem.hasPrefix(token) else { return false }
        guard stem.count > token.count else { return true }
        let boundary = stem.index(stem.startIndex, offsetBy: token.count)
        return stem[boundary].unicodeScalars.allSatisfy(separators.contains)
    }
}
