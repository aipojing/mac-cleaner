import Foundation

/// 单次扫描的元数据快照索引：相同标准化路径在一次扫描中最多读取一次。
///
/// 并发请求共享同一个读取任务；成功结果与确定性错误（`MetadataError`）
/// 都在本索引生命周期内缓存。取消等不确定错误不缓存，
/// 避免一个调用者取消污染后续请求。
public actor FileMetadataIndex {
    private let provider: any FileMetadataProviding
    private var values: [String: Result<FileMetadata, MetadataError>] = [:]
    private var inFlight: [String: Task<FileMetadata, Error>] = [:]

    public init(provider: any FileMetadataProviding = POSIXFileMetadataProvider()) {
        self.provider = provider
    }

    public func metadata(at path: String) async throws -> FileMetadata {
        let key = POSIXFileMetadataProvider.normalized(path)
        if let cached = values[key] {
            return try cached.get()
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task { try await self.provider.metadata(at: key) }
        inFlight[key] = task

        do {
            let value = try await task.value
            values[key] = .success(value)
            inFlight[key] = nil
            return value
        } catch let error as MetadataError {
            values[key] = .failure(error)
            inFlight[key] = nil
            throw error
        } catch {
            // 取消等不确定错误不缓存，允许后续请求重试。
            inFlight[key] = nil
            throw error
        }
    }

    /// 已缓存的成功值；未缓存或缓存为错误时返回 nil，不触发读取。
    public func cachedMetadata(at path: String) -> FileMetadata? {
        let key = POSIXFileMetadataProvider.normalized(path)
        guard let cached = values[key] else { return nil }
        return try? cached.get()
    }
}
