//
//  Theme.swift
//  OpenList iOS
//
//  主题系统。
//
//  ## 为什么需要这个文件
//
//  `.tint()` 只影响「控件自带的强调色」（按钮、开关、Slider 等），
//  但代码里大量使用 `Color.accentColor` 直接取色 —— 那个是**系统级**的青色，
//  用户换成紫/粉/橙时完全不会跟着变。
//
//  所以这里做两件事：
//  1. `OlAccentKey`：把用户选的颜色放进 Environment，所有自绘元素读它。
//  2. `.olTint()` 修饰符统一注入，避免各处写 `Color.accentColor`。
//

import SwiftUI

// MARK: - 强调色环境值

private struct OlAccentKey: EnvironmentKey {
    static let defaultValue: Color = Color(red: 0.31, green: 0.48, blue: 0.39)
}

extension EnvironmentValues {
    var olAccent: Color {
        get { self[OlAccentKey.self] }
        set { self[OlAccentKey.self] = newValue }
    }
}

extension View {
    /// 一次性注入强调色 + 系统 tint。
    func olTint(_ color: Color) -> some View {
        self
            .environment(\.olAccent, color)
            .tint(color)
    }
}

// MARK: - 读取强调色

struct AccentReader {
    var color: Color
}

/// 便利包装：`@Environment(\.olAccent) private var accent`
/// 直接在各视图里用 `accent` 即可，不需要额外包装类型。

// MARK: - 常用玻璃/卡片背景

struct OlCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

// MARK: - 强调色小圆点（列表里标识选中）

struct AccentDot: View {
    @Environment(\.olAccent) private var accent
    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: 8, height: 8)
    }
}
