//
//  MainShell.swift
//  OpenList iOS
//
//  主界面：4 个 Tab + 悬浮液态玻璃 Dock。
//  每个 Tab 各自持有一个 NavModel（独立页面栈），切换 Tab 不会互相顶掉。
//

import SwiftUI

struct MainShell: View {

    @EnvironmentObject private var container: AppContainer
    @State private var tab: Tab = .files

    @StateObject private var filesNav = NavModel()
    @StateObject private var searchNav = NavModel()
    @StateObject private var tasksNav = NavModel()
    @StateObject private var settingsNav = NavModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            // 四个 Tab 各自一个 NavigationStack，Dock 浮在它们之上。
            // 各页面自己用 .olDockSafeArea() 让出底部空间 —— 这是唯一可靠的机制，
            // 之前试过在容器层垫透明块、用 Environment 传高度，都会被 NavStack 吃掉。
            switch tab {
            case .files:
                FilesScreen()
                    .environmentObject(filesNav)
            case .search:
                SearchScreen()
                    .environmentObject(searchNav)
            case .tasks:
                TasksScreen()
                    .environmentObject(tasksNav)
            case .settings:
                SettingsScreen()
                    .environmentObject(settingsNav)
            }

            FloatingDock(selection: $tab)
        }
        .onReceive(container.downloads.$flash) { value in
            guard !value.isEmpty else { return }
            ToastCenter.shared.show(value)
            container.downloads.flash = ""
        }
        .onReceive(container.uploads.$flash) { value in
            guard !value.isEmpty else { return }
            ToastCenter.shared.show(value)
            container.uploads.flash = ""
        }
        .overlay(alignment: .bottom) { ToastHost() }
    }
}

// MARK: - 轻提示

final class ToastCenter: ObservableObject {

    static let shared = ToastCenter()

    @Published var message: String = ""

    private var workItem: DispatchWorkItem?

    func show(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.workItem?.cancel()
            self.message = text
            let item = DispatchWorkItem { [weak self] in
                self?.message = ""
            }
            self.workItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
        }
    }
}

struct ToastHost: View {

    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        ZStack {
            if !center.message.isEmpty {
                Text(center.message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82), in: Capsule())
                    // Dock 高度 + 余量，避免提示被 Dock 盖住
                    .padding(.bottom, DockMetrics.totalHeight + 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: center.message)
    }
}
