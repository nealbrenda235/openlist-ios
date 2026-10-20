//
//  Nav.swift
//  OpenList iOS
//
//  导航：4 个 Tab（系统 TabView）+ 每个 Tab 自己的 NavigationStack。
//  这里只保留「页面栈」的最小语义，与 Android 1.1.33 的 NavState 对齐：
//  任何深度的页面都能 push 新页面，返回手势交给系统。
//

import SwiftUI

enum Tab: String, CaseIterable, Identifiable, Hashable {
    case files, search, tasks, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .files: return "文件"
        case .search: return "搜索"
        case .tasks: return "任务"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .search: return "magnifyingglass"
        case .tasks: return "arrow.up.arrow.down"
        case .settings: return "gearshape"
        }
    }
}

enum Route: Hashable {
    case browse(serverId: String, path: String)
    case play(serverId: String, path: String)
    case preview(serverId: String, path: String)
    case admin(serverId: String)
    case editServer(serverId: String?)
    case appearance
    case about
}

/// 单个 Tab 的页面栈。用引用类型，深层页面也能压栈。
@MainActor
final class NavModel: ObservableObject {
    @Published var path = NavigationPath()

    func push(_ route: Route) { path.append(route) }
    func pop() { if !path.isEmpty { path.removeLast() } }
    func popToRoot() { path = NavigationPath() }
}
