import Foundation
import CryptoKit

/// full hash 计算边界：hash 缓存只依赖该协议，测试可注入计数桩。
public protocol FileHashComputing: Sendable {
    func computeFullHash(at path: String) async throws -> String
}

public enum FileHashError: Error, Equatable, Sendable {
    case unreadable(path: String)
}

public struct FileHasher: Sendable {
    public init() {}

    /// 只读前 N 字节做 SHA-256（快速预筛）
    public func partialHash(at path: String, bytes: Int = 4096) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: bytes)
        guard !data.isEmpty else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 流式全文件 SHA-256 哈希（64KB 分块）
    public func fullHash(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 65536)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 首/中/尾三段抽样的读取偏移。每段最多 chunkSize 字节；
    /// 文件不足一段时只读开头一次。区域重叠时去重。
    public static func sampleOffsets(logicalSize: Int64, chunkSize: Int64) -> [Int64] {
        guard logicalSize > 0, chunkSize > 0 else { return [] }
        if logicalSize <= chunkSize { return [0] }
        let middle = max(0, (logicalSize - chunkSize) / 2)
        let tail = max(0, logicalSize - chunkSize)
        var offsets: [Int64] = [0]
        if middle != 0 { offsets.append(middle) }
        if tail != middle && tail != 0 { offsets.append(tail) }
        return offsets
    }

    /// 首/中/尾三段抽样 SHA-256（每段最多 chunkSize 字节）。
    /// 只有中部不同的文件会被中段抽样区分，无需读取全文件。
    public func sampledHash(path: String, logicalSize: Int64, chunkSize: Int64 = 65_536) -> String? {
        let offsets = Self.sampleOffsets(logicalSize: logicalSize, chunkSize: chunkSize)
        guard !offsets.isEmpty,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        var hasher = SHA256()
        for offset in offsets {
            handle.seek(toFileOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(chunkSize))
            guard !data.isEmpty else { return nil }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension FileHasher: FileHashComputing {
    public func computeFullHash(at path: String) async throws -> String {
        guard let hash = fullHash(at: path) else {
            throw FileHashError.unreadable(path: path)
        }
        return hash
    }
}
