//
//  AdaptiveShell.swift
//  OpenList iOS
//
//  iPad / 横屏宽布局：NavigationSplitView 侧栏 + 内容区。
//  手机继续用 TabView（iOS 的 TabView 在 iPad 上会变成底部居中胶囊，
//  不符合「分栏」的诉求，所以按尺寸类切换两种壳）。
//
//  这里刻意不复制业务代码：两种壳共用同一批 Screen 视图。
//

import SwiftUI

struct AdaptiveShell: View {

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            PadShell()
        } else {
            MainShell()
        }
    }
}

private struct PadShell: View {
    @Environment(\.olAccent) private var accent

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var tab: Tab = .files
    @State private var filesNav = NavModel()
    @State private var searchNav = NavModel()
    @State private var tasksNav = NavModel()
    @State private var settingsNav = NavModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                Section {
                    ForEach(Tab.allCases) { item in
                        Button {
                            tab = item
                            nav(for: item).popToRoot()
                        } label: {
                            Label(item.label, systemImage: tab == item ? selectedSymbol(item) : item.symbol)
                                .foregroundStyle(tab == item ? accent : Color.primary)
                        }
                        .listRowBackground(
                            tab == item
                                ? accent.opacity(0.12)
                                : Color.clear
                        )
                    }
                } header: {
                    Text("OpenList")
                }

                Section("服务器") {
                    ForEach(servers.servers) { server in
                        Button {
                            tab = .files
                            filesNav.push(.browse(serverId: server.id, path: server.normalizedRoot))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName).foregroundStyle(.primary)
                                Text(server.hostText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("OpenList")
        } detail: {
            NavigationStack(path: binding(for: tab)) {
                switch tab {
                case .files: FilesScreen()
                case .search: SearchScreen()
                case .tasks: TasksScreen()
                case .settings: SettingsScreen()
                }
            }
        }
        .environmentObject(filesNav)
        .environmentObject(searchNav)
        .environmentObject(tasksNav)
        .environmentObject(settingsNav)
        .overlay(alignment: .bottom) { ToastHost() }
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
    }

    private func selectedSymbol(_ item: Tab) -> String {
        switch item {
        case .files: return "folder.fill"
        case .search: return "magnifyingglass"
        case .tasks: return "arrow.up.arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    private func nav(for item: Tab) -> NavModel {
        switch item {
        case .files: return filesNav
        case .search: return searchNav
        case .tasks: return tasksNav
        case .settings: return settingsNav
        }
    }

    /// NavigationStack 需要 Binding<NavigationPath>，而 NavModel 把 path 私有发布。
    private func binding(for item: Tab) -> Binding<NavigationPath> {
        let model = nav(for: item)
        return Binding(
            get: { model.path },
            set: { model.path = $0 }
        )
    }
}
