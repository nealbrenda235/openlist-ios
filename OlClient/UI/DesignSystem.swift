//
//  DesignSystem.swift
//  OpenList iOS
//
//  iOS 26 Liquid Glass 设计系统。
//
//  ## 为什么之前「没有液态玻璃」
//
//  之前的构建跑在 macos-14 runner（Xcode 15/16，iOS 17/18 SDK）。
//  `.glassEffect()`、`GlassEffectContainer`、`glassEffectID` 这些 API
//  在 iOS 26 才出现，旧 SDK 里根本不存在，所以只能退回 `.ultraThinMaterial`
//  —— 那是 iOS 15 的普通毛玻璃，看起来就是一块半透明灰，没有液态玻璃的
//  折射、高光、边缘聚光和连续形状融合（morphing）。
//
//  现在 CI 换成 macos-26（Xcode 26，iOS 26 SDK），这些 API 才真正可用。
//  代码里保留 `if #available(iOS 26.0, *)` 回退，保证在老系统上仍能跑。
//

import SwiftUI

// MARK: - 圆角与间距

enum OlRadius {
    static let card: CGFloat = 26
    static let inner: CGFloat = 18
    static let chip: CGFloat = 999
}

enum OlSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

// MARK: - 可用性

enum OlGlass {
    /// 当前系统是否支持原生液态玻璃
    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

// MARK: - 玻璃卡片

/// 一层液态玻璃。iOS 26 上用原生 glassEffect，老系统退回材质模糊。
struct GlassCard<Content: View>: View {

    var padding: CGFloat = OlSpace.md
    var cornerRadius: CGFloat = OlRadius.card
    /// tint 会给玻璃染上一层强调色（用于高亮卡片）
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            content()
                .padding(padding)
                .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content()
                .padding(padding)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        if let tint {
            return .regular.tint(tint.opacity(0.22)).interactive()
        }
        return .regular
    }
}

// MARK: - 强调色卡片（统计区）

struct AccentCard<Content: View>: View {

    let accent: Color
    var padding: CGFloat = OlSpace.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: OlRadius.card, style: .continuous)
                        .fill(accent.gradient)
                    RoundedRectangle(cornerRadius: OlRadius.card, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.02),
                                         Color.black.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: OlRadius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.9)
            }
            .shadow(color: accent.opacity(0.32), radius: 18, x: 0, y: 8)
    }
}

// MARK: - 胶囊分段

struct CapsuleSegmented<Item: Hashable, Label: View>: View {

    let options: [Item]
    @Binding var selection: Item
    @ViewBuilder let label: (Item) -> Label

    @Environment(\.olAccent) private var accent
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { item in
                let isOn = item == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = item
                    }
                } label: {
                    label(item)
                        .font(.subheadline.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? accent : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isOn {
                                Capsule(style: .continuous)
                                    .fill(.background)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                                    .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }
}

// MARK: - 统计磁贴

struct StatTile: View {

    let value: String
    let label: String
    var tint: Color? = nil
    @Environment(\.olAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? accent)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 区块标题

struct SectionHeader: View {

    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, OlSpace.xxs)
    }
}

// MARK: - 按压反馈

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - 进度环

struct ProgressRing: View {

    let progress: Double
    let tint: Color
    var symbol: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                Text("\(Int(progress * 100))")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
        }
    }
}
