import Foundation

/// 特权助手守护进程入口
/// 通过 SMAppService 安装到 /Library/PrivilegedHelperTools/，以 root 身份运行
/// 仅响应 XPC 请求执行 /usr/sbin/purge

let delegate = XPCServiceDelegate()
let listener = NSXPCListener(machServiceName: "com.maccleaner.helper")
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
