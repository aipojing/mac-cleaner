import Foundation
@testable import MacCleanerCore

/// 进程解析测试桩：返回固定身份表，查不到即解析失败。
struct StubProcessResolver: ProcessExecutableResolving {
    var identities: [Int32: ProcessIdentity]

    init(identities: [Int32: ProcessIdentity] = [:]) {
        self.identities = identities
    }

    init(identity: ProcessIdentity) {
        self.identities = [identity.pid: identity]
    }

    func identity(for pid: Int32) async throws -> ProcessIdentity {
        guard let identity = identities[pid] else {
            throw ProcessExecutableResolverError.unavailable
        }
        return identity
    }
}
