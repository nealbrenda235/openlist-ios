//
//  DesignSystem.swift
//  OpenList iOS
//
//  iOS 26/27 风格的设计常量与组件。
//
//  ## 这一版和上一版的区别
//
//  iOS 26 起 Apple 全面转向「Liquid Glass」：
//  - 大圆角（卡片 20~26pt，按钮胶囊）
//  - 材质分层：内容 − 浮层 − 高亮，每层都有自己的模糊与描边
//  - 强调色只用于「可交互元素」，大面积留白
//  - 数字用等宽（monospacedDigit），标题用 .rounded 更亲近
//  - 分组不再用 insetGrouped 的灰底，改用「浮起的玻璃卡片」
//
//  这里把这些沉淀成常量 + 少量复用组件，避免每处各写一套。
//

import SwiftUI

// MARK: - 圆角与间距

enum OlRadius {
    static let card: CGFloat = 22
    static let inner: CGFloat = 14
    static let pill: CGFloat = 18
    static let sheet: CGFloat = 28
}

enum OlSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
}

// MARK: - 玻璃卡片

/// 浮起的玻璃卡片：内容区不再用系统灰底分组，改成这种带描边的半透明块。
struct GlassCard<Content: View>: View {

    var padding: CGFloat = OlSpace.md
    var corner: CGFloat = OlRadius.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
                    }
            }
    }
}

/// 强调色渐变卡片（用于统计、播放中的任务这类需要突出的块）。
struct AccentCard<Content: View>: View {

    @Environment(\.olAccent) private var accent
    var corner: CGFloat = OlRadius.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(OlSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(gradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                    }
                    .shadow(color: accent.opacity(0.24), radius: 14, x: 0, y: 6)
            }
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.92), accent.opacity(0.66)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 分段胶囊

/// 分段控件（替代 Picker(.segmented)）：胶囊形浮起，选中项有实心胶囊滑动。
struct CapsuleSegmented<T: Hashable, Label: View>: View {

    let options: [T]
    @Binding var selection: T
    @ViewBuilder var label: (T) -> Label

    @Environment(\.olAccent) private var accent
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = option
                    }
                } label: {
                    label(option)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selection == option ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selection == option {
                                Capsule(style: .continuous)
                                    .fill(accent)
                                    .matchedGeometryEffect(id: "seg", in: ns)
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

// MARK: - 统计数字

struct StatTile: View {

    let value: String
    let label: String
    var symbol: String? = nil

    @Environment(\.olAccent) private var accent

    var body: some View {
        VStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(.bottom, 1)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 区块标题

struct SectionHeader: View {

    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, OlSpace.xxs)
    }
}

// MARK: - 可压缩按钮

/// 按下时轻微缩放，给触觉之外的一点"按下去"的反馈。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
