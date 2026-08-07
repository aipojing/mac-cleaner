import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.maccleaner.app", category: "Permission")

struct PermissionGuideView: View {
    let onGranted: () -> Void

    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("需要完全磁盘访问权限")
                .font(.title2)
                .fontWeight(.semibold)

            Text("DevClean 需要「完全磁盘访问」权限来扫描和清理系统缓存文件。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                step(number: 1, text: "打开「系统设置 → 隐私与安全性 → 完全磁盘访问」")
                step(number: 2, text: "点击 + 号添加 DevClean")
                step(number: 3, text: "返回此处点击「检查权限」")
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 16) {
                Button("打开系统设置") {
                    openSystemPreferences()
                }

                Button("检查权限") {
                    checkPermission()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)
            }
        }
        .padding(40)
        .frame(width: 520, height: 440)
    }

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: Circle())

            Text(text)
                .font(.body)
        }
    }

    private func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    private func checkPermission() {
        logger.notice("checkPermission() called")
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let result = PermissionChecker.hasFullDiskAccess()
            logger.notice("hasFullDiskAccess() = \(result)")
            if result {
                onGranted()
            }
            isChecking = false
        }
    }
}

enum PermissionChecker {
    /// 获取真实用户主目录（绕过 Sandbox 容器路径）
    static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    static func hasFullDiskAccess() -> Bool {
        let sandboxHome = NSHomeDirectory()
        let realHome = realHomeDirectory
        logger.notice("sandboxHome = \(sandboxHome)")
        logger.notice("realHome = \(realHome)")

        // 在 Sandbox 中用真实用户目录检测 FDA
        let protectedPaths = [
            realHome + "/Library/Containers/com.apple.Safari",
            realHome + "/Library/Safari",
            realHome + "/Library/Cookies",
            realHome + "/Library/Mail",
        ]
        let fm = FileManager.default
        for path in protectedPaths {
            let exists = fm.fileExists(atPath: path)
            logger.notice("path=\(path) exists=\(exists)")

            if exists {
                do {
                    let contents = try fm.contentsOfDirectory(atPath: path)
                    logger.notice("  -> contents count=\(contents.count)")
                    if !contents.isEmpty {
                        return true
                    }
                } catch {
                    logger.notice("  -> error: \(error.localizedDescription)")
                }
            }
        }
        return false
    }
}
