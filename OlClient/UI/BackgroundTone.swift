//
//  BackgroundTone.swift
//  OpenList iOS
//
//  背景色方案，对齐 Android 版 1.1.33 的 BackgroundTone / BackgroundStyle。
//
//  Android 侧的定义：
//    BackgroundTone = { Slate, Sand, Mist, Blush, Graphite, Custom }
//    BackgroundStyle = { Gradient, Solid }
//
//  iOS 这里用同名的语义，但颜色值是按 iOS 的浅/深色外观各给一套，
//  因为同一个 hex 在深色模式下直接套会显得刺眼。
//

import SwiftUI

// MARK: - 色调

enum BackgroundTone: String, CaseIterable, Identifiable {
    case system, slate, sand, mist, blush, graphite, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "系统"
        case .slate: return "石板"
        case .sand: return "沙岩"
        case .mist: return "雾青"
        case .blush: return "绯粉"
        case .graphite: return "石墨"
        case .custom: return "自定义"
        }
    }

    /// 预览用的主色（同时也用于「纯色」模式）。
    var baseColor: Color {
        switch self {
        case .system: return Color(.systemGroupedBackground)
        case .slate: return Color(red: 0.42, green: 0.47, blue: 0.55)
        case .sand: return Color(red: 0.72, green: 0.65, blue: 0.55)
        case .mist: return Color(red: 0.45, green: 0.62, blue: 0.64)
        case .blush: return Color(red: 0.72, green: 0.52, blue: 0.56)
        case .graphite: return Color(red: 0.30, green: 0.31, blue: 0.34)
        case .custom: return Color(red: 0.31, green: 0.48, blue: 0.39)
        }
    }

    /// 浅色模式下的页面背景
    func lightBackground(custom: Color) -> LinearGradient {
        let c = self == .custom ? custom : baseColor
        return LinearGradient(
            colors: [c.opacity(0.10), Color(.systemGroupedBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 深色模式下的页面背景
    func darkBackground(custom: Color) -> LinearGradient {
        let c = self == .custom ? custom : baseColor
        return LinearGradient(
            colors: [c.opacity(0.22), Color(.systemGroupedBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 背景样式

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case gradient, solid

    var id: String { rawValue }
    var label: String { self == .gradient ? "渐变" : "纯色" }
}

// MARK: - 背景视图

struct OlBackground: View {

    let tone: BackgroundTone
    let style: BackgroundStyle
    let customColor: Color

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch style {
            case .gradient:
                if scheme == .dark {
                    tone.darkBackground(custom: customColor)
                } else {
                    tone.lightBackground(custom: customColor)
                }
            case .solid:
                solidColor
            }
        }
        .ignoresSafeArea()
    }

    private var solidColor: Color {
        if tone == .system { return Color(.systemGroupedBackground) }
        let c = tone == .custom ? customColor : tone.baseColor
        // 纯色模式也保留一点向页面底色过渡，避免大面积饱和色太刺眼
        return c.opacity(scheme == .dark ? 0.30 : 0.16)
            .blended(over: Color(.systemGroupedBackground))
    }
}

private extension Color {
    /// 简易「不透明叠加」：把半透明色叠到不透明底色上，得到等效实色。
    func blended(over base: Color) -> Color {
        // SwiftUI 没有直接读取 Color 分量的公开 API，
        // 用 UIColor 走一趟，保证 iOS 16 也能拿到值。
        let top = UIColor(self)
        let bottom = UIColor(base)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let a = ta + ba * (1 - ta)
        guard a > 0 else { return base }
        let r = (tr * ta + br * ba * (1 - ta)) / a
        let g = (tg * ta + bg * ba * (1 - ta)) / a
        let b = (tb * ta + bb * ba * (1 - ta)) / a
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }
}
