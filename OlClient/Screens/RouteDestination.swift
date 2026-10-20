//
//  RouteDestination.swift
//  OpenList iOS
//
//  路由分发 + 服务器状态。
//
//  之前这两个类型塞在 FilesScreen.swift 里，重构文件页时容易连带删掉，
//  单独一个文件更稳，也让四个 Tab 都能直接复用同一个分发器。
//

import SwiftUI

struct RouteDestination: View {

    @EnvironmentObject private var servers: ServerStore
    let route: Route

    var body: some View {
        switch route {
        case let .browse(serverId, path):
            BrowseScreen(serverId: serverId, initialPath: path)
        case let .play(serverId, path):
            PlayerScreen(serverId: serverId, path: path)
        case let .preview(serverId, path):
            PreviewScreen(serverId: serverId, path: path)
        case let .admin(serverId):
            AdminScreen(serverId: serverId)
        case let .editServer(serverId):
            EditServerScreen(server: serverId.flatMap { servers.get($0) })
        case .appearance:
            AppearanceScreen()
        case .about:
            AboutScreen()
        }
    }
}

enum ServerStatus {
    case checking, online, needLogin, offline

    var label: String {
        switch self {
        case .checking: return "检测中"
        case .online: return "在线"
        case .needLogin: return "需重新登录"
        case .offline: return "离线"
        }
    }

    var color: Color {
        switch self {
        case .checking: return .secondary
        case .online: return .green
        case .needLogin: return .orange
        case .offline: return .red
        }
    }
}
