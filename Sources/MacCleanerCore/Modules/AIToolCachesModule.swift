import Foundation

public struct AIToolCachesModule: CleanerModule {
    public let identifier = ModuleIdentifier.aiToolCaches
    public let displayName = "AI 工具缓存"
    public let description = "AI 编程助手和智能工具的本地缓存"

    private let scanner = DiskScanner()
    private let home = DiskScanner.homeDirectory

    private struct AITool {
        let name: String
        let tag: String
        /// 纯缓存路径
        let cachePaths: [String]
        /// 含用户数据的路径：展示时标注“含数据”，用 trash 删除
        let dataPaths: [String]

        init(name: String, tag: String, cachePaths: [String], dataPaths: [String] = []) {
            self.name = name
            self.tag = tag
            self.cachePaths = cachePaths
            self.dataPaths = dataPaths
        }
    }

    private var tools: [AITool] {
        Self.makeTools(home: home)
    }

    /// 工具清单按 home 参数生成，保证扫描与删除策略使用同一份根目录来源。
    private static func makeTools(home: String) -> [AITool] {
        [
            // --- AI IDE / 编辑器 ---
            AITool(name: "Cursor", tag: "cursor", cachePaths: [
                "\(home)/.cursor/Cache",
                "\(home)/.cursor/CachedData",
                "\(home)/.cursor/CachedExtensions",
                "\(home)/.cursor/CachedExtensionVSIXs",
                "\(home)/Library/Caches/com.todesktop.230313mzl4w4u92",
            ]),
            AITool(name: "Trae", tag: "trae", cachePaths: [
                "\(home)/Library/Caches/Trae",
            ], dataPaths: [
                "\(home)/.trae",
            ]),
            AITool(name: "Windsurf", tag: "windsurf", cachePaths: [
                "\(home)/Library/Caches/Windsurf",
            ], dataPaths: [
                "\(home)/.codeium",
            ]),
            AITool(name: "Void", tag: "void", cachePaths: [
                "\(home)/Library/Caches/Void",
            ]),
            AITool(name: "Zed AI", tag: "zed", cachePaths: [
                "\(home)/.config/zed/languages",
                "\(home)/Library/Caches/dev.zed.Zed",
            ]),

            // --- IDE 插件 / 编程助手 ---
            AITool(name: "GitHub Copilot", tag: "copilot", cachePaths: [
                "\(home)/.copilot",
            ]),
            AITool(name: "通义灵码", tag: "lingma", cachePaths: [
                "\(home)/.lingma",
            ]),
            AITool(name: "豆包 MarsCode", tag: "doubao", cachePaths: [
                "\(home)/Library/Caches/Doubao",
            ]),
            AITool(name: "Tabnine", tag: "tabnine", cachePaths: [], dataPaths: [
                "\(home)/.tabnine",
            ]),
            AITool(name: "Codeium", tag: "codeium", cachePaths: [], dataPaths: [
                "\(home)/.codeium",
            ]),
            AITool(name: "Amazon Q", tag: "amazonq", cachePaths: [
                "\(home)/Library/Caches/com.amazon.codewhisperer",
            ]),
            AITool(name: "Sourcegraph Cody", tag: "cody", cachePaths: [], dataPaths: [
                "\(home)/.sourcegraph",
            ]),
            AITool(name: "Continue", tag: "continue", cachePaths: [], dataPaths: [
                "\(home)/.continue",
            ]),
            AITool(name: "Supermaven", tag: "supermaven", cachePaths: [], dataPaths: [
                "\(home)/.supermaven",
            ]),
            AITool(name: "Qoder", tag: "qoder", cachePaths: [], dataPaths: [
                "\(home)/.qoder",
            ]),
            AITool(name: "Augment", tag: "augment", cachePaths: [], dataPaths: [
                "\(home)/.augment",
            ]),

            // --- 终端 AI 工具 ---
            AITool(name: "Claude Code", tag: "claude", cachePaths: [
                "\(home)/.claude/.cache",
            ], dataPaths: [
                // ~/.claude 整目录含 settings/memory/projects，不应暴露
            ]),
            AITool(name: "OpenAI Codex CLI", tag: "codex", cachePaths: [
                "\(home)/.codex/cache",
            ]),
            AITool(name: "Gemini CLI", tag: "gemini", cachePaths: [
                "\(home)/.gemini/cache",
            ]),
            AITool(name: "Aider", tag: "aider", cachePaths: [
                "\(home)/.aider/caches",
            ]),

            // --- AI 桌面应用 ---
            AITool(name: "ChatGPT", tag: "chatgpt", cachePaths: [
                "\(home)/Library/Caches/com.openai.chat",
            ]),
            AITool(name: "Claude Desktop", tag: "claude-desktop", cachePaths: [
                "\(home)/Library/Caches/com.anthropic.claudefordesktop",
            ]),
            AITool(name: "Ollama", tag: "ollama", cachePaths: [], dataPaths: [
                "\(home)/.ollama",
            ]),
            AITool(name: "LM Studio", tag: "lmstudio", cachePaths: [
                "\(home)/.cache/lm-studio",
                "\(home)/Library/Caches/ai.elementlabs.LMStudio",
            ]),
        ]
    }

    /// 删除策略使用的允许根目录：manifest 中的每一条 cachePaths 与 dataPaths。
    /// manifest 是扫描与执行的唯一根目录来源，不能由 AI 或响应内容扩展。
    static func homeRoots(home: String) -> [String] {
        var roots: [String] = []
        for tool in makeTools(home: home) {
            roots.append(contentsOf: tool.cachePaths)
            roots.append(contentsOf: tool.dataPaths)
        }
        return roots
    }

    private let identityProvider: any FileIdentityProviding

    public init(identityProvider: any FileIdentityProviding = POSIXFileIdentityProvider()) {
        self.identityProvider = identityProvider
    }

    public func isAvailable() -> Bool {
        tools.contains { tool in
            let all = tool.cachePaths + tool.dataPaths
            return all.contains { scanner.directoryExists(at: $0) }
        }
    }

    public func scan(context: ScanContext) async throws -> ScanResult {
        let start = Date()

        // 顺序型模块：整个元数据读取过程占用一个文件任务许可，
        // 保证全局文件任务并发受 context 上限约束。
        return try await context.fileTaskLimiter.withPermit {
            var items: [CleanableItem] = []

            for tool in tools {
                // 纯缓存路径：safe, recommended
                for path in tool.cachePaths {
                    if let item = makeItem(tool: tool, path: path, isDataPath: false) {
                        items.append(item)
                    }
                }
                // 含用户数据路径：moderate, not recommended
                for path in tool.dataPaths {
                    if let item = makeItem(tool: tool, path: path, isDataPath: true) {
                        items.append(item)
                    }
                }
            }

            return ScanResult(
                module: .aiToolCaches,
                items: await context.recordIdentities(of: items),
                scanDuration: Date().timeIntervalSince(start)
            )
        }
    }

    private func makeItem(tool: AITool, path: String, isDataPath: Bool) -> CleanableItem? {
        guard scanner.directoryExists(at: path) else { return nil }
        let size = scanner.directorySize(at: path)
        guard size > 0 else { return nil }

        let dirName = (path as NSString).lastPathComponent
        let suffix = isDataPath ? " (含数据)" : ""
        return CleanableItem(
            path: path,
            displayName: "\(tool.name) (\(dirName))\(suffix)",
            size: size,
            category: .aiToolCaches,
            subcategory: tool.tag,
            evidenceTags: ["cache", "ai-tool", tool.tag]
        )
    }

    public func clean(items: [CleanableItem], dryRun: Bool) async throws -> CleanupReport {
        // 使用废纸篓，用户可恢复误删
        Deleter().delete(items: items, module: .aiToolCaches, dryRun: dryRun, useTrash: true)
    }
}
