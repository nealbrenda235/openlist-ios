//
//  GlassShell.swift
//  OpenList iOS
//
//  悬浮毛玻璃 Dock + 顶栏模糊。
//
//  ## 为什么拆得这么碎
//
//  第一版把所有渐变、描边、阴影写在一个 `.background { }` 里，
//  Swift 编译器直接报 "unable to type-check in reasonable time"。
//  复杂 ViewBuilder 表达式一定要拆成独立的 View / 计算属性，
//  否则类型推断会指数级爆炸。
//

import SwiftUI

// MARK: - Dock 里的单个按钮

private struct DockButton: View {

    let item: Tab
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? item.selectedSymbol : item.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(item.label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        isSelected ? accent : Color.secondary
    }
}

// MARK: - Dock 胶囊背景

private struct DockBackground: View {

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(stroke)
            .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 6)
            .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
    }

    private var stroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(dockEdge, lineWidth: 0.8)
    }

    private var dockEdge: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.34), Color.white.opacity(0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 悬浮 Dock

struct FloatingDock: View {

    @Binding var selection: Tab
    @Environment(\.olAccent) var accent

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
        .padding(.horizontal, 46)
        .padding(.bottom, 6)
    }

    private func select(_ item: Tab) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            selection = item
        }
    }
}

// MARK: - 带悬浮 Dock 的页面壳

struct DockShell<Content: View>: View {

    @Binding var selection: Tab
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            content()
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 74)
                }
            FloatingDock(selection: $selection)
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
