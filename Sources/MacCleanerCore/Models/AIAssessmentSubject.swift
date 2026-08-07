import Foundation

/// 交给 AI 判断的对象。只包含本地事实，不包含文件内容、
/// 环境变量或完整命令行参数。
public enum AIAssessmentSubject: Codable, Equatable, Sendable {
    case cleanup(id: String, fingerprint: String, evidence: CleanupAIEvidence)
    case process(id: String, fingerprint: String, evidence: ProcessAIEvidence)

    public var subjectID: String {
        switch self {
        case let .cleanup(id, _, _), let .process(id, _, _): id
        }
    }

    public var fingerprint: String {
        switch self {
        case let .cleanup(_, fingerprint, _), let .process(_, fingerprint, _): fingerprint
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, fingerprint, evidence
    }

    private enum Kind: String, Codable {
        case cleanup, process
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let id = try container.decode(String.self, forKey: .id)
        let fingerprint = try container.decode(String.self, forKey: .fingerprint)
        switch kind {
        case .cleanup:
            let evidence = try container.decode(CleanupAIEvidence.self, forKey: .evidence)
            self = .cleanup(id: id, fingerprint: fingerprint, evidence: evidence)
        case .process:
            let evidence = try container.decode(ProcessAIEvidence.self, forKey: .evidence)
            self = .process(id: id, fingerprint: fingerprint, evidence: evidence)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .cleanup(id, fingerprint, evidence):
            try container.encode(Kind.cleanup, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(fingerprint, forKey: .fingerprint)
            try container.encode(evidence, forKey: .evidence)
        case let .process(id, fingerprint, evidence):
            try container.encode(Kind.process, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(fingerprint, forKey: .fingerprint)
            try container.encode(evidence, forKey: .evidence)
        }
    }
}

/// 清理对象的客观事实。只含元数据，不含文件内容。
public struct CleanupAIEvidence: Codable, Equatable, Sendable {
    public let path: String
    public let objectKind: FileObjectKind
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let modificationTime: Date?
    public let module: ModuleIdentifier
    public let tags: [String]

    public init(
        path: String,
        objectKind: FileObjectKind,
        logicalSize: UInt64,
        allocatedSize: UInt64,
        modificationTime: Date?,
        module: ModuleIdentifier,
        tags: [String]
    ) {
        self.path = path
        self.objectKind = objectKind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationTime = modificationTime
        self.module = module
        self.tags = tags
    }
}

/// 进程的客观事实。只含元数据，不含环境变量和完整 argv。
public struct ProcessAIEvidence: Codable, Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let executableName: String
    public let bundleIdentifier: String?
    public let owner: String
    public let cpuPercent: Double
    public let residentMemoryBytes: UInt64
    public let elapsedSeconds: UInt64?
    public let signedByApple: Bool?

    public init(
        pid: Int32,
        executablePath: String,
        executableName: String,
        bundleIdentifier: String?,
        owner: String,
        cpuPercent: Double,
        residentMemoryBytes: UInt64,
        elapsedSeconds: UInt64?,
        signedByApple: Bool?
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier
        self.owner = owner
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.elapsedSeconds = elapsedSeconds
        self.signedByApple = signedByApple
    }
}
