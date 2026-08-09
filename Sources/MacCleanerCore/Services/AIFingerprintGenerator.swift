import CryptoKit
import Foundation

/// 清理对象指纹输入。只包含定义对象身份的字段；
/// 瞬时指标不进入指纹，仍可作为请求 evidence。
public struct CleanupFingerprintInput: Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let objectKind: FileObjectKind
    public let allocatedSize: UInt64
    public let modificationTime: Date?
    public let module: ModuleIdentifier
    public let tags: [String]

    public init(
        path: String,
        device: UInt64,
        inode: UInt64,
        objectKind: FileObjectKind,
        allocatedSize: UInt64,
        modificationTime: Date?,
        module: ModuleIdentifier,
        tags: [String]
    ) {
        self.path = path
        self.device = device
        self.inode = inode
        self.objectKind = objectKind
        self.allocatedSize = allocatedSize
        self.modificationTime = modificationTime
        self.module = module
        self.tags = tags
    }
}

/// 进程对象指纹输入。瞬时 CPU 和内存不进入指纹。
public struct ProcessFingerprintInput: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let bundleIdentifier: String?
    public let startTimeTicks: UInt64
    public let signedByApple: Bool?

    public init(
        pid: Int32,
        executablePath: String,
        bundleIdentifier: String?,
        startTimeTicks: UInt64,
        signedByApple: Bool?
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.startTimeTicks = startTimeTicks
        self.signedByApple = signedByApple
    }
}

/// 生成语义稳定且实例敏感的 SHA-256 指纹。
/// 字段顺序无关，tags 排序去重，时间统一为毫秒，保证跨扫描稳定。
public struct AIFingerprintGenerator: Sendable {
    public static let schemaVersion = 1
    /// 进程分析从泛化的“保留建议”改为“结束影响”后单独升级，
    /// 避免复用旧语义下的缓存结论，同时不使清理项缓存失效。
    public static let processSchemaVersion = 2

    public init() {}

    public func cleanupFingerprint(_ input: CleanupFingerprintInput) throws -> String {
        try digest(CleanupPayload(input: input))
    }

    public func processFingerprint(_ input: ProcessFingerprintInput) throws -> String {
        try digest(ProcessPayload(input: input))
    }

    /// 规范化 JSON（排序键、毫秒时间）后取 SHA-256 十六进制摘要。
    public func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CleanupPayload: Encodable {
    let schemaVersion: Int
    let path: String
    let device: UInt64
    let inode: UInt64
    let objectKind: FileObjectKind
    let allocatedSize: UInt64
    let modificationTimeMilliseconds: Int64?
    let module: ModuleIdentifier
    let tags: [String]

    init(input: CleanupFingerprintInput) {
        schemaVersion = AIFingerprintGenerator.schemaVersion
        path = Self.normalizedPath(input.path)
        device = input.device
        inode = input.inode
        objectKind = input.objectKind
        allocatedSize = input.allocatedSize
        modificationTimeMilliseconds = input.modificationTime
            .map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
        module = input.module
        tags = Array(Set(input.tags)).sorted()
    }

    /// 去掉末尾多余斜杠（根路径除外），保证同一目录写法不同指纹一致。
    static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

private struct ProcessPayload: Encodable {
    let schemaVersion: Int
    let pid: Int32
    let executablePath: String
    let bundleIdentifier: String?
    let startTimeTicks: UInt64
    let signedByApple: Bool?

    init(input: ProcessFingerprintInput) {
        schemaVersion = AIFingerprintGenerator.processSchemaVersion
        pid = input.pid
        executablePath = CleanupPayload.normalizedPath(input.executablePath)
        bundleIdentifier = input.bundleIdentifier
        startTimeTicks = input.startTimeTicks
        signedByApple = input.signedByApple
    }
}
