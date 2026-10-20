//
//  FilesScreen.swift
//  OpenList iOS
//
//  文件页（重构图，iOS 26 风格）。
//
//  和上一版的差别：
//  - 不再用 List(.insetGrouped) 的灰底分组，改成 ScrollView + 玻璃卡片
//  - 统计区做成一张强调色渐变卡，数字等宽 + numericText 过渡
//  - 服务器行整行可点，右侧状态与角色徽章用小胶囊
//  - 保留系统导航栏（大标题），但背景是毛玻璃
//

import SwiftUI

struct FilesScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var prefs: FilePrefs
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var nav: NavModel
    @Environment(\.olAccent) private var accent

    @State private var editingServer: ServerConfig?
    @State private var showAddServer = false
    @State private var statuses: [String: ServerStatus] = [:]
    @State private var deleteTarget: ServerConfig?
    @State private var loaded = false

    var body: some View {
        NavigationStack(path: $nav.path) {
            ScrollView {
                VStack(spacing: OlSpace.md) {
                    if servers.servers.isEmpty {
                        emptyState
                    } else {
                        summaryCard
                        if !recentPlaybacks.isEmpty { continueCard }
                        if !favoriteRows.isEmpty { favoriteCard }
                        serverCards
                    }
                    Color.clear.frame(height: OlSpace.xs)
                }
                .padding(.horizontal, OlSpace.md)
                .padding(.top, OlSpace.xs)
            }
            .olDockSafeArea()
            .background(Color.clear)
            .navigationTitle("OpenList")
            .olGlassNavBarLarge()
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
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            .sheet(isPresented: $showAddServer) { EditServerScreen(server: nil) }
            .sheet(item: $editingServer) { EditServerScreen(server: $0) }
            .refreshable { await refreshStatuses() }
            .task {
                if !loaded { loaded = true }
                await refreshStatuses()
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
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: OlSpace.sm) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(accent)
                .padding(.bottom, OlSpace.xxs)
            Text("还没有服务器")
                .font(.title3.weight(.semibold))
            Text("添加一台 OpenList 服务器，\n就能在这里浏览它聚合的所有存储。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddServer = true
            } label: {
                Label("添加服务器", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, OlSpace.lg)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, OlSpace.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 统计卡

    private var summaryCard: some View {
        AccentCard {
            HStack(spacing: 0) {
                tile("\(onlineCount)/\(servers.servers.count)", "在线", "wifi")
                divider
                tile("\(servers.servers.filter(\.isAdmin).count)", "管理", "shield.lefthalf.filled")
                divider
                tile("\(downloads.activeCount + uploads.activeCount)", "进行中", "arrow.up.arrow.down")
            }
        }
        .foregroundStyle(.white)
    }

    private func tile(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .opacity(0.85)
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .opacity(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 0.7, height: 34)
    }

    // MARK: - 继续观看

    private var continueCard: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "继续观看")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(recentPlaybacks.enumerated()), id: \.element.path) { index, item in
                        Button {
                            nav.push(.play(serverId: item.serverId, path: item.path))
                        } label: {
                            HStack(spacing: OlSpace.sm) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(accent.opacity(0.14))
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(accent)
                                }
                                .frame(width: 30, height: 30)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text((item.path as NSString).lastPathComponent)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.primary)
                                    Text(servers.get(item.serverId)?.displayName ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, OlSpace.md)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)

                        if index != recentPlaybacks.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 收藏

    private var favoriteCard: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "收藏", trailing: "\(favoriteRows.count)")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(favoriteRows.enumerated()), id: \.element.key) { index, row in
                        Button {
                            nav.push(.browse(serverId: row.serverId, path: row.path))
                        } label: {
                            HStack(spacing: OlSpace.sm) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.yellow)
                                    .frame(width: 30, height: 30)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.path == "/" ? "根目录" : (row.path as NSString).lastPathComponent)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(row.serverName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, OlSpace.md)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            Button(role: .destructive) {
                                prefs.removeFavorite(key: row.key)
                            } label: {
                                Label("取消收藏", systemImage: "star.slash")
                            }
                        }

                        if index != favoriteRows.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 服务器

    private var serverCards: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "服务器", trailing: "\(servers.servers.count)")

            ForEach(servers.servers) { server in
                Button {
                    nav.push(.browse(serverId: server.id, path: server.normalizedRoot))
                } label: {
                    ServerCard(server: server, status: statuses[server.id] ?? .checking)
                }
                .buttonStyle(.pressable)
                .contextMenu {
                    Button { editingServer = server } label: {
                        Label("编辑服务器", systemImage: "pencil")
                    }
                    Button { Task { await relogin(server) } } label: {
                        Label("重新登录", systemImage: "arrow.clockwise")
                    }
                    if server.isAdmin {
                        Button { nav.push(.admin(serverId: server.id)) } label: {
                            Label("后台管理", systemImage: "gearshape.2")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteTarget = server
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - 数据

    private var favoriteRows: [(key: String, serverId: String, serverName: String, path: String)] {
        prefs.favorites.compactMap { key in
            guard let (sid, path) = FilePrefs.split(key),
                  let server = servers.get(sid) else { return nil }
            return (key, sid, server.displayName, path)
        }
    }

    private var recentPlaybacks: [(serverId: String, path: String)] {
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

    private var onlineCount: Int {
        statuses.values.filter { $0 == .online }.count
    }

    // MARK: - 动作

    private func refreshStatuses() async {
        for server in servers.servers {
            if statuses[server.id] == nil { statuses[server.id] = .checking }
        }
        await withTaskGroup(of: (String, ServerStatus).self) { group in
            for server in servers.servers {
                group.addTask { (server.id, await probe(server)) }
            }
            for await (id, status) in group {
                withAnimation(.easeInOut(duration: 0.2)) { statuses[id] = status }
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

// MARK: - 服务器卡片

struct ServerCard: View {

    @Environment(\.olAccent) private var accent
    let server: ServerConfig
    let status: ServerStatus

    var body: some View {
        GlassCard(padding: OlSpace.md) {
            HStack(spacing: OlSpace.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.15))
                    Image(systemName: server.isAdmin
                          ? "externaldrive.connected.to.line.below"
                          : "externaldrive")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(accent)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(server.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        if server.isAdmin {
                            Text("管理")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(accent.opacity(0.16), in: Capsule())
                                .foregroundStyle(accent)
                        }
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 6, height: 6)
                        Text(server.hostText)
                            .lineLimit(1)
                        Text("·")
                        Text(status.label)
                            .foregroundStyle(status.color)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
