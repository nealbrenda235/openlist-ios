//
//  GlassShell.swift
//  OpenList iOS
//
//  悬浮毛玻璃 Dock + 顶栏模糊。
//
//  ## 为什么不用系统 TabView
//
//  系统 TabView 是**不透明的底部条**，没有毛玻璃浮起效果，也不能做 iOS 26
//  那种「胶囊 + 液态玻璃」观感。用户明确要「苹果风格 + 顶栏模糊」，
//  所以这里用 ZStack + .ultraThinMaterial 自绘一个浮动 Dock，
//  内容区延伸到屏幕底部，滚动时胶囊下面透出列表内容（真正的模糊）。
//
//  ## 顶栏模糊
//
//  系统导航栏默认在滚到底时变透明。用 `.toolbarBackground(.visible, for: .navigationBar)`
//  + `.toolbarBackground(.ultraThinMaterial, for: .navigationBar)` 强制常驻毛玻璃，
//  页面上滑时标题栏始终有一层模糊，不会出现「白底直接贴内容」。
//

import SwiftUI

// MARK: - 悬浮 Dock

struct FloatingDock: View {

    @Binding var selection: Tab
    @Environment(\.olAccent) private var accent
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        selection = item
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selection == item ? item.selectedSymbol : item.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                        Text(item.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selection == item ? accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background {
                        if selection == item {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(accent.opacity(0.15))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            // 两层材质叠出「液态玻璃」：底层厚一点的模糊保证可读性，
            // 上层描边勾出胶囊边缘。
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.34), Color.white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                }
                .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 6)
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
        }
        .padding(.horizontal, 46)
        .padding(.bottom, 6)
    }
}

// MARK: - 带悬浮 Dock 的页面壳

/// 把任意内容包装成「内容延伸到底 + 悬浮 Dock 浮在上面」的结构。
struct DockShell<Content: View>: View {

    @Binding var selection: Tab
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            content()
                // 给 Dock 留出可滚动的高度，避免最后一个文件被胶囊遮住
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 74)
                }
            FloatingDock(selection: $selection)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
