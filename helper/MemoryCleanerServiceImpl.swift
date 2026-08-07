import Foundation

/// XPC 协议实现，以 root 身份执行 purge
final class MemoryCleanerServiceImpl: NSObject, MemoryCleanerXPCProtocol {

    private static let currentVersion = "1.0.0"

    func purgeMemory(withReply reply: @escaping (NSError?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/purge")
        process.arguments = []

        process.terminationHandler = { proc in
            if proc.terminationStatus == 0 {
                reply(nil)
            } else {
                let error = NSError(
                    domain: "com.maccleaner.helper",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "purge 命令退出码 \(proc.terminationStatus)"]
                )
                reply(error)
            }
        }

        do {
            try process.run()
        } catch {
            reply(error as NSError)
        }
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(Self.currentVersion)
    }
}
