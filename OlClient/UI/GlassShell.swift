//
//  GlassShell.swift
//  OpenList iOS
//
//  悬浮毛玻璃 Dock + 顶栏模糊。
//
//  ## 遮挡问题是怎么解决的
//
//  v3 用 `safeAreaInset(edge: .bottom) { Color.clear.frame(height: 74) }` 给 Dock 让位。
//  但页面都是 ScrollView，这个 inset 只影响容器自身布局，**滚动内容并不会因此多出
//  可滚动的底部空间** —— 所以最后一屏内容会滑到 Dock 下面被盖住（用户实测每页都有）。
//
//  正确做法：把「Dock 高度 + 安全区」作为 ScrollView 的 contentMargin 传下去，
//  让滚动内容真的能滚出这个高度。这里用一个 Environment 值传递，
//  各页面的 ScrollView 统一读取，避免每处硬编码。
//

import SwiftUI

// MARK: - Dock 占位高度（供各页面 ScrollView 用）

private struct DockInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 底部需要为 Dock 预留的高度。0 表示当前页面没有 Dock。
    var olDockInset: CGFloat {
        get { self[DockInsetKey.self] }
        set { self[DockInsetKey.self] = newValue }
    }
}

extension View {
    /// 给滚动内容底部补足 Dock 占用的空间。
    /// - Parameter extra: 额外留白（一般给 8~16，避免内容紧贴 Dock）。
    @ViewBuilder
    func olDockSafeArea(extra: CGFloat = 12) -> some View {
        modifier(DockSafeAreaModifier(extra: extra))
    }
}

private struct DockSafeAreaModifier: ViewModifier {

    @Environment(\.olDockInset) private var inset
    let extra: CGFloat

    func body(content: Content) -> some View {
        let total = inset + extra
        if #available(iOS 17.0, *) {
            content.contentMargins(.bottom, inset > 0 ? total : 0, for: .scrollContent)
        } else {
            // iOS 16：用一个不可见占位行撑出同样的滚动空间
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if inset > 0 {
                    Color.clear.frame(height: total)
                }
            }
        }
    }
}

// MARK: - Dock 背景

private struct DockBackground: View {

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(stroke)
            .shadow(color: Color.black.opacity(0.16), radius: 20, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
    }

    private var stroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(dockEdge, lineWidth: 0.8)
    }

    private var dockEdge: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.30), Color.white.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
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
                // 四个 Tab 统一用「镂空 → 实心」表达选中，
                // 不再给「任务」换带圈图标（那会让它看起来比其他三项小一圈）
                Image(systemName: isSelected ? item.selectedSymbol : item.symbol)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .frame(height: 21)
                Text(item.label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 悬浮 Dock

struct FloatingDock: View {

    @Binding var selection: Tab
    @Environment(\.olAccent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                DockButton(
                    item: item,
                    isSelected: selection == item,
                    accent: accent,
                    action: { select(item) }
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background { DockBackground() }
        .padding(.horizontal, 32)
    }

    private func select(_ item: Tab) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            selection = item
        }
    }
}

// MARK: - 带悬浮 Dock 的页面壳

struct DockShell<Content: View>: View {

    @Binding var selection: Tab
    @ViewBuilder var content: () -> Content

    /// Dock 本身约 60pt + 与安全区之间的 8pt 间隙
    private let dockHeight: CGFloat = 68

    var body: some View {
        ZStack(alignment: .bottom) {
            content()
                .environment(\.olDockInset, dockHeight)

            FloatingDock(selection: $selection)
                .padding(.bottom, 2)
        }
        // Dock 浮在固定底部安全区之上，页面内容通过 olDockInset 自觉让位
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - 顶栏毛玻璃

extension View {
    /// 让导航栏常驻毛玻璃，滚动时内容从模糊层下面穿过。
    func olGlassNavBar() -> some View {
        self
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    /// 大标题页面的顶栏（用于根级页面）。
    func olGlassNavBarLarge() -> some View {
        self
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .navigationBarTitleDisplayMode(.large)
    }
}
