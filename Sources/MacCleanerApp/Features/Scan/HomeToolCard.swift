import SwiftUI

enum HomeToolDestination: String, Hashable, Identifiable {
    case appUninstaller
    case duplicateFinder
    case diskVisualization
    case activityMonitor
    case aiSettings

    var id: String { rawValue }
}

struct HomeToolCard: Identifiable {
    let destination: HomeToolDestination
    let icon: String
    let colors: [Color]
    let title: String
    let subtitle: String

    var id: HomeToolDestination { destination }

    static let standard: [HomeToolCard] = [
        HomeToolCard(
            destination: .appUninstaller,
            icon: "trash",
            colors: [.red, .orange],
            title: "应用卸载器",
            subtitle: "彻底卸载应用及残留文件"
        ),
        HomeToolCard(
            destination: .duplicateFinder,
            icon: "doc.on.doc",
            colors: [.pink, .purple],
            title: "重复文件清理",
            subtitle: "查找内容一样的文件"
        ),
        HomeToolCard(
            destination: .diskVisualization,
            icon: "chart.pie",
            colors: [.blue, .cyan],
            title: "磁盘空间分析",
            subtitle: "深度分析存储情况"
        ),
        HomeToolCard(
            destination: .activityMonitor,
            icon: "waveform.badge.magnifyingglass",
            colors: [.purple, .indigo],
            title: "活动监视器",
            subtitle: "查看进程用途，安全终止"
        ),
        HomeToolCard(
            destination: .aiSettings,
            icon: "sparkles",
            colors: [.blue, .purple],
            title: "AI 设置",
            subtitle: "配置模型与 API Key"
        ),
    ]
}
