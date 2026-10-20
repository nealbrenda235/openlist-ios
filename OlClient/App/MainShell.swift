//
//  MainShell.swift
//  OpenList iOS
//
//  主界面：4 个 Tab + 悬浮毛玻璃 Dock。
//  用自绘 Dock 替代系统 TabView（系统 TabView 是不透明底栏，没有浮起效果）。
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
        DockShell(selection: $tab) {
            ZStack {
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
            }
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
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: center.message)
    }
}
