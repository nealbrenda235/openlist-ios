//
//  GlassShell.swift
//  OpenList iOS
//
//  悬浮液态玻璃 Dock。
//
//  ## 遮挡问题改了三版，这是第四版
//
//  v3 `safeAreaInset { Color.clear }` —— 垫透明块，但 ScrollView 不认，照样遮挡。
//  v4 `contentMargins` + Environment —— 方向对，但值下发在 NavigationStack 外部，
//     传不进 ScrollView，等于没设。
//  v5 每个页面各自 `safeAreaInset` —— 对单页有效，但 BrowseScreen 自己有底部工具栏，
//     两个 bottom safeAreaInset 互相覆盖，Dock 空间被工具栏吞掉（用户实测仍遮挡）。
//
//  v6（本版）统一策略：
//  - 用**唯一一个** `safeAreaInset(edge: .bottom)` 交出全部底部空间
//  - 页面若自带工具栏，就把「工具栏 + Dock 占位」合进同一个 inset
//

import SwiftUI

// MARK: - Dock 尺寸（全局唯一定义，避免多处重复声明）

enum DockMetrics {
    /// 胶囊本体高 52 + 上下 padding 8·2
    static let dockHeight: CGFloat = 52 + 16
    /// 滚动内容需要避让的总高度（Dock + 与最后一项的间隙）
    static let totalHeight: CGFloat = dockHeight + 12
    /// 带底部工具栏的页面复用同一数值
    static let reservedHeight: CGFloat = totalHeight
}

// MARK: - Dock 按钮

private struct DockButton: View {

    let item: Tab
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? item.selectedSymbol : item.symbol)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                    // ★ 固定 24×24 容器：四个 SF Symbol 固有宽高比不同，
                    //   不固定会让「任务」的箭头在选中换图标时看起来变小。
                    .frame(width: 24, height: 24)
                Text(item.label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dock 本体（液态玻璃）

struct FloatingDock: View {

    @Binding var selection: Tab
    @Environment(\.olAccent) private var accent

    var body: some View {
        if #available(iOS 26.0, *) {
            // iOS 26：原生液态玻璃。GlassEffectContainer 让玻璃元素在空间上融合，
            // 这是液态玻璃区别于普通毛玻璃的关键特征。
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) { buttons }
                    .frame(height: DockMetrics.dockHeight - 16)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, OlSpace.xl + 8)
            .padding(.bottom, OlSpace.xs)
        } else {
            HStack(spacing: 0) { buttons }
                .frame(height: DockMetrics.dockHeight - 16)
                .background {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                        }
                }
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .padding(.horizontal, OlSpace.xl + 8)
                .padding(.bottom, OlSpace.xs)
        }
    }

    private var buttons: some View {
        ForEach(Tab.allCases) { item in
            DockButton(item: item,
                       isSelected: selection == item,
                       accent: accent) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                    selection = item
                }
            }
        }
    }
}

// MARK: - 底部让位

private struct DockSpacer: View {
    let height: CGFloat
    var body: some View {
        Color.clear.frame(height: height)
    }
}

extension View {
    /// 给根级页面底部留出悬浮 Dock 的高度。
    ///
    /// ★ 重要：同一页面**不能**再加第二个 `safeAreaInset(edge: .bottom)`，
    ///   两个会互相覆盖。若页面自带底部工具栏，请把工具栏和
    ///   `Color.clear.frame(height: DockMetrics.reservedHeight)` 合进同一个 inset。
    func olDockSafeArea() -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0) {
            DockSpacer(height: DockMetrics.totalHeight)
        }
    }

    /// 顶栏毛玻璃。
    func olGlassNavBar() -> some View {
        self.toolbarBackground(.visible, for: .navigationBar)
    }

    func olGlassNavBarLarge() -> some View {
        self
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.large)
    }
}
