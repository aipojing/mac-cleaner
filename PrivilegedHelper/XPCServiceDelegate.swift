import Foundation
import Security

final class XPCServiceDelegate: NSObject, NSXPCListenerDelegate {

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // 验证连接来源是否为主 App
        guard isValidClient(newConnection) else {
            newConnection.invalidate()
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(
            with: MemoryCleanerXPCProtocol.self
        )
        newConnection.exportedObject = MemoryCleanerServiceImpl()
        newConnection.resume()
        return true
    }

    private func isValidClient(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else { return false }

        // 使用 code requirement 严格校验：必须由 Apple 签名链且 identifier 匹配。
        // 比单纯比对 identifier 字符串更安全，防止同名未签名程序冒充。
        // 如需进一步收紧，可追加 and certificate leaf[subject.CN] = "Developer ID Application: <Team>"
        let requirement = "anchor apple generic and identifier \"com.maccleaner.app\""
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              let req
        else { return false }

        return SecCodeCheckValidity(code, [.basicCheckOnly], req) == errSecSuccess
    }
}
