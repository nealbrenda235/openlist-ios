//
//  FilesScreen.swift
//  OpenList iOS
//
//  文件 Tab：服务器列表 + 收藏 + 继续观看。
//  结构对齐 Android 1.1.33 的 FilesScreen，但改用系统 List 分组与
//  NavigationStack 路由，长按菜单、滑动操作都由系统提供。
//

import SwiftUI

struct FilesScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var prefs: FilePrefs
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var nav: NavModel

    @State private var editingServer: ServerConfig?
    @State private var showAddServer = false
    @State private var statuses: [String: ServerStatus] = [:]
    @State private var deleteTarget: ServerConfig?

    var body: some View {
        NavigationStack(path: $nav.path) {
            List {
                if servers.servers.isEmpty {
                    Section {
                        EmptyStateRow(title: "还没有添加服务器",
                                      detail: "添加一台 OpenList 服务器后，就能在这里浏览它聚合的所有存储。",
                                      symbol: "externaldrive.badge.questionmark")
                        Button {
                            showAddServer = true
                        } label: {
                            Text("添加服务器").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    summarySection
                    continueSection
                    favoritesSection
                    serverSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("OpenList")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAddServer = true } label: {
                            Label("添加服务器", systemImage: "plus")
                        }
                        Button { Task { await refreshStatuses() } } label: {
                            Label("刷新状态", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteDestination(route: route)
            }
            .sheet(isPresented: $showAddServer) {
                EditServerScreen(server: nil)
            }
            .sheet(item: $editingServer) { server in
                EditServerScreen(server: server)
            }
            .refreshable { await refreshStatuses() }
            .task { await refreshStatuses() }
        }
    }

    // MARK: - 概要

    private var summarySection: some View {
        Section {
            HStack(spacing: 0) {
                statCell(title: "在线", value: "\(onlineCount)/\(servers.servers.count)")
                Divider().frame(height: 30)
                statCell(title: "管理", value: "\(servers.servers.filter(\.isAdmin).count)")
                Divider().frame(height: 30)
                statCell(title: "进行中", value: "\(downloads.activeCount + uploads.activeCount)")
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func statCell(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var onlineCount: Int {
        statuses.values.filter { $0 == .online }.count
    }

    // MARK: - 继续观看

    @ViewBuilder
    private var continueSection: some View {
        let recent = recentPlaybacks()
        if !recent.isEmpty {
            Section("继续观看") {
                ForEach(recent, id: \.path) { item in
                    Button {
                        nav.push(.play(serverId: item.serverId, path: item.path))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((item.path as NSString).lastPathComponent)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(servers.get(item.serverId)?.displayName ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 收藏

    @ViewBuilder
    private var favoritesSection: some View {
        let rows = favoriteRows()
        if !rows.isEmpty {
            Section("收藏 · \(rows.count)") {
                ForEach(rows, id: \.key) { row in
                    Button {
                        let path = row.path
                        nav.push(.browse(serverId: row.serverId, path: path))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.path == "/" ? "根目录" : (row.path as NSString).lastPathComponent)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(row.serverName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            let key = row.key
                            prefs.removeFavorite(key: key)
                        } label: {
                            Label("取消收藏", systemImage: "star.slash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        Section {
            ForEach(servers.servers) { server in
                Button {
                    nav.push(.browse(serverId: server.id, path: server.normalizedRoot))
                } label: {
                    HStack {
                        ServerRow(server: server, status: statuses[server.id] ?? .checking)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = server
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        editingServer = server
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    Button {
                        editingServer = server
                    } label: {
                        Label("编辑服务器", systemImage: "pencil")
                    }
                    Button {
                        Task { await relogin(server) }
                    } label: {
                        Label("重新登录", systemImage: "arrow.clockwise")
                    }
                    if server.isAdmin {
                        Button {
                            nav.push(.admin(serverId: server.id))
                        } label: {
                            Label("后台管理", systemImage: "gearshape.2")
                        }
                    }
                    Button(role: .destructive) {
                        deleteTarget = server
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("服务器 · \(servers.servers.count)")
        }
        .alert("删除服务器？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { server in
            Button("删除", role: .destructive) {
                servers.remove(server.id)
                statuses.removeValue(forKey: server.id)
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { server in
            Text("「\(server.displayName)」的地址与凭据会一并删除，已下载的文件不受影响。")
        }
    }

    // MARK: - 数据

    private func favoriteRows() -> [(key: String, serverId: String, serverName: String, path: String)] {
        prefs.favorites.compactMap { key in
            guard let (sid, path) = FilePrefs.split(key),
                  let server = servers.get(sid) else { return nil }
            return (key, sid, server.displayName, path)
        }
    }

    private func recentPlaybacks() -> [(serverId: String, path: String)] {
        UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("play.") }
            .compactMap { entry -> (String, String, Double)? in
                let parts = entry.key.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                let value = (entry.value as? NSNumber)?.doubleValue ?? 0
                guard value > 3 else { return nil }
                return (String(parts[1]), String(parts[2]), value)
            }
            .filter { servers.get($0.0) != nil }
            .sorted { $0.2 > $1.2 }
            .prefix(3)
            .map { ($0.0, $0.1) }
    }

    // MARK: - 状态探测

    private func refreshStatuses() async {
        for server in servers.servers {
            statuses[server.id] = .checking
        }
        await withTaskGroup(of: (String, ServerStatus).self) { group in
            for server in servers.servers {
                group.addTask { (server.id, await probe(server)) }
            }
            for await (id, status) in group {
                statuses[id] = status
            }
        }
    }

    private func probe(_ server: ServerConfig) async -> ServerStatus {
        do {
            let fresh = try await servers.ensureToken(server.id, api: container.api)
            _ = try await container.api.me(baseUrl: fresh.url, token: fresh.token)
            return .online
        } catch let error as ApiError {
            return error.authRelated ? .needLogin : .offline
        } catch {
            return .offline
        }
    }

    private func relogin(_ server: ServerConfig) async {
        statuses[server.id] = .checking
        do {
            let session = try await container.api.login(baseUrl: server.url,
                                                        username: server.username,
                                                        password: server.password)
            let account = try await container.api.me(baseUrl: server.url, token: session.token)
            servers.updateToken(server.id, token: session.token, role: account.role)
            statuses[server.id] = .online
            ToastCenter.shared.show("已重新登录「\(server.displayName)」")
        } catch {
            statuses[server.id] = .needLogin
            ToastCenter.shared.show((error as? ApiError)?.message ?? "重新登录失败")
        }
    }
}

// MARK: - 路由分发（各 Tab 共用）

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

// MARK: - 服务器状态

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

struct ServerRow: View {

    let server: ServerConfig
    let status: ServerStatus

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(server.hostText).lineLimit(1)
                    Text("·")
                    Text(status.label).foregroundStyle(status.color)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if server.isAdmin {
                Text("管理员")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }
}
