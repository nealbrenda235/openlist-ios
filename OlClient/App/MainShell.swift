//
//  MainShell.swift
//  OpenList iOS
//
//  主界面：4 个 Tab（文件 / 搜索 / 任务 / 设置）。
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
        TabView(selection: $tab) {
            FilesScreen()
                .environmentObject(filesNav)
                .tabItem { Label(Tab.files.label, systemImage: Tab.files.symbol) }
                .tag(Tab.files)

            SearchScreen()
                .environmentObject(searchNav)
                .tabItem { Label(Tab.search.label, systemImage: Tab.search.symbol) }
                .tag(Tab.search)

            TasksScreen()
                .environmentObject(tasksNav)
                .tabItem { Label(Tab.tasks.label, systemImage: Tab.tasks.symbol) }
                .tag(Tab.tasks)

            SettingsScreen()
                .environmentObject(settingsNav)
                .tabItem { Label(Tab.settings.label, systemImage: Tab.settings.symbol) }
                .tag(Tab.settings)
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
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: center.message)
    }
}
