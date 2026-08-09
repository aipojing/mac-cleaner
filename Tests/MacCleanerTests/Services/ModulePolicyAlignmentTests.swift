import Foundation
import Testing
@testable import MacCleanerCore

/// 静态断言：各扫描模块产出候选的根路径必须落在该模块删除策略的
/// allowedRoots 之内（按路径组件边界比较）。防止"扫描能产出、删除时
/// 固定以 outsideAllowedRoots 失败"的策略表错位（docker 曾是回归实例）。
///
/// 候选根列表镜像自各模块的扫描代码（只读引用，未改动模块）；
/// 模块扫描范围变更时需同步本表。动态根（AIToolCaches.homeRoots、
/// AndroidSDK 环境变量、simctl 输出）无法静态枚举，不在覆盖范围内。
@Suite("模块扫描根与删除策略对齐")
struct ModulePolicyAlignmentTests {
    /// 虚构 home：不存在的路径，realpath 解析失败后两边都落在
    /// standardized 形式，保证比较确定且与真实文件系统无关。
    private let home = "/tmp/devclean-policy-alignment-home"

    private func assertCovered(
        _ module: ModuleIdentifier,
        _ candidateRoots: [String]
    ) {
        let policy = DeletionPolicyCatalog(home: home).policy(for: module)
        let roots = policy.allowedRoots.map { ($0 as NSString).standardizingPath }
        for candidate in candidateRoots {
            let path = (candidate as NSString).standardizingPath
            let covered = roots.contains { root in
                path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            #expect(covered, "\(module) 候选根 \(candidate) 不在 allowedRoots 内")
        }
    }

    @Test("docker：模块产出的全部候选根都在 allowedRoots 内（含两个 Caches 目录）")
    func dockerCandidatesCovered() {
        assertCovered(.docker, [
            // DockerModule：虚拟磁盘与日志位于 Data 子树
            "\(home)/Library/Containers/com.docker.docker/Data",
            "\(home)/Library/Containers/com.docker.docker/Data/log",
            // DockerModule：buildx 构建缓存
            "\(home)/.docker/buildx",
            // DockerModule：应用缓存候选（本次修复的回归）
            "\(home)/Library/Caches/com.docker.docker",
            "\(home)/Library/Caches/Docker",
        ])
    }

    @Test("applicationCaches：扫描根在 allowedRoots 内")
    func applicationCachesCovered() {
        assertCovered(.applicationCaches, [
            "\(home)/Library/Caches",
        ])
    }

    @Test("systemLogs：模块产出的全部候选根都在 allowedRoots 内")
    func systemLogsCandidatesCovered() {
        assertCovered(.systemLogs, [
            "\(home)/Library/Logs",
            "\(home)/Library/Logs/DiagnosticReports",
            "\(home)/Library/Logs/DiagnosticReports/Retired",
            "\(home)/Library/Logs/Spindump",
            "\(home)/Library/Logs/Spin Reports",
        ])
    }

    @Test("xcode：模块产出的全部候选根都在 allowedRoots 内")
    func xcodeCandidatesCovered() {
        assertCovered(.xcode, [
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/CoreSimulator/Caches",
        ])
    }

    @Test("largeFiles / duplicateFiles：允许根即用户主目录")
    func homeRootedModulesCovered() {
        assertCovered(.largeFiles, [home])
        assertCovered(.duplicateFiles, [home])
    }
}
