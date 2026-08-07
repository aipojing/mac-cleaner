import SwiftUI

/// 品牌视觉令牌：鲜明个性风的唯一事实来源。
/// 主渐变取自品牌 logo（#0D63FF → #44D1A7），强调色跟随 ThemeManager。
enum Brand {
    /// 当前强调色（系统主题回落到品牌蓝）
    static var accent: Color {
        ThemeManager.shared.accentColor ?? Color(red: 0x0D / 255, green: 0x63 / 255, blue: 0xFF / 255)
    }

    /// 品牌渐变（logo 蓝 → 青绿）
    static let brandGradient = LinearGradient(
        colors: [
            Color(red: 0x0D / 255, green: 0x63 / 255, blue: 0xFF / 255),
            Color(red: 0x44 / 255, green: 0xD1 / 255, blue: 0xA7 / 255),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 当前主题的渐变；系统主题用品牌渐变
    static var accentGradient: LinearGradient {
        guard let pair = ThemeManager.shared.selectedTheme.gradientPair else {
            return brandGradient
        }
        return LinearGradient(
            colors: pair,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension ThemeManager.AccentTheme {
    /// 每个强调色的渐变搭档；nil 表示系统主题（走品牌渐变）
    var gradientPair: [Color]? {
        switch self {
        case .system: return nil
        case .blue:   return [.blue, .cyan]
        case .green:  return [.green, .mint]
        case .purple: return [.purple, .indigo]
        case .pink:   return [.pink, .orange]
        case .orange: return [.orange, .yellow]
        case .teal:   return [.teal, .mint]
        }
    }
}

/// 渐变图标徽章：品牌签名组件，白色 SF Symbol 置于渐变圆角方块上。
struct GradientIconBadge: View {
    let icon: String
    var size: CGFloat = 56
    var iconSize: CGFloat? = nil
    var colors: [Color]? = nil

    var body: some View {
        let fill: LinearGradient = colors.map {
            LinearGradient(colors: $0, startPoint: .topLeading, endPoint: .bottomTrailing)
        } ?? Brand.accentGradient

        Image(systemName: icon)
            .font(.system(size: iconSize ?? size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: size * 0.08, y: size * 0.04)
    }
}

extension View {
    /// 品牌卡片：material 材质 + 16 连续圆角 + 发丝描边
    func brandCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

/// 悬浮微抬升的卡片按钮样式（feedback：确认可点）
struct BrandCardButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : (hovering ? 1.02 : 1))
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 8, y: 4)
            .animation(.spring(duration: 0.25), value: hovering)
            .animation(.spring(duration: 0.15), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
