# 交接提示词：实时大文件扫描体验

把下面内容完整交给接手的 AI：

```text
你正在维护 macOS SwiftUI 项目 DevClean，工作目录：
/Users/ahs/Documents/vibe-coding/mac-cleaner

请完整阅读并严格执行以下文档：
1. AGENTS.md
2. docs/superpowers/specs/2026-08-09-streaming-scan-experience-design.md
3. docs/superpowers/plans/2026-08-09-streaming-large-file-scan.md

任务目标：实现“大文件清理”的实时扫描体验。扫描到第一个超过阈值的文件时就显示候选；扫描中持续更新当前 Top 50；最终仍使用既有 ScanResult、结果页和删除安全护栏。把全进程 FTS 并发限制为 2，减少磁盘元数据 I/O 争抢。

重要边界：
- 这是第一期，不实现 FSEvents、跨启动持久化索引或全盘缓存。
- 不改变清理阈值、删除策略、权限语义或现有模块的 CLI 输出。
- 不为了提速静默增加目录排除项；大文件扫描使用 FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV。
- 所有新行为必须先按计划写 Swift Testing 测试、确认失败，再写最小实现，随后重跑测试。
- 不要在原项目目录创建 .git：用户明确要求本地项目保持无 Git 仓库。
- 当前 GitHub 远端是 https://github.com/aipojing/mac-cleaner 。完成并验证后，使用临时 clone 复制明确改动、提交 `App: stream large-file scan results` 并推送 main；确认远端提交后删除临时 clone，原目录仍不能出现 .git。

实施要求：
1. 严格按计划的 Task 1 到 Task 5 顺序执行；每个 Task 都先 RED、再 GREEN、再运行指定验证。
2. 每次改动前检查当前文件，避免覆盖用户在此后的新修改。
3. 核心层事件模型是 LargeFileScanUpdate，通过 ScanContext.onLargeFileUpdate 传递；不要修改 CleanerModule 协议。
4. UI 更新必须经 MainActor，核心层限频为首项立即、后续最多 5 次/秒、结束必发最终快照；扫描中不能出现清理按钮。
5. 大文件候选的大小与去重必须按 device/inode 的实际占用计算；最终排序和既有删除校验不得回退。
6. 最后运行 swift test、MacCleanerApp 的 xcodebuild test 与 build，并手动验证：首项实时出现、取消清空、结束进入既有结果页。

交付时请报告：修改了哪些文件、测试命令及结果、手工 UI 验证结果、GitHub 提交 SHA 和仓库链接；如果遇到现有 Swift 编译警告，单独列出但不要顺带重构无关代码。
```
