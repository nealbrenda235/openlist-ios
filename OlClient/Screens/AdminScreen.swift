//
//  AdminScreen.swift
//  OpenList iOS
//
//  后台管理。与 Android 1.1.33 的 AdminScreen 对应，但按 iOS 习惯重划：
//  概览 / 存储 / 用户 / 设置 / 任务 / 分享，用 List 分组 + NavigationLink 下钻。
//
//  存储编辑是最容易出事的地方：服务端用「整体覆盖」语义，
//  漏字段会被写空（Android #39-b 真事故：只改备注，解压目录被清空）。
//  所以这里的编辑页一律基于完整 AdminStorage 拷贝后改字段。
//

import SwiftUI

struct AdminScreen: View {
    @Environment(\.olAccent) private var accent

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String

    @State private var storages: [AdminStorage] = []
    @State private var indexProgress = ScanProgress(total: 0, done: 0, running: false, error: "")
    @State private var loading = true
    @State private var errorText: String?
    @State private var busy: String?
    @State private var deleteTarget: AdminStorage?

    private var server: ServerConfig? { servers.get(serverId) }

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            overviewSection
            storageSection
            entriesSection
            dangerSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("后台管理")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .overlay {
            if let busy {
                ProgressView(busy)
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .alert("删除这个挂载？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { storage in
            Button("删除", role: .destructive) {
                Task { await delete(storage) }
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { storage in
            Text("「\(storage.mountPath)」的挂载配置会被删除，服务端本地文件不受影响。")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        AdminStorageCreateScreen(serverId: serverId) {
                            Task { await reload() }
                        }
                    } label: {
                        Label("新建挂载", systemImage: "plus.circle")
                    }
                    Button {
                        Task { await reload() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - 概览

    private var overviewSection: some View {
        Section {
            HStack(spacing: 0) {
                stat("挂载", "\(storages.count)")
                Divider().frame(height: 28)
                stat("启用", "\(storages.filter { !$0.disabled }.count)")
                Divider().frame(height: 28)
                stat("停用", "\(storages.filter(\.disabled).count)")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if indexProgress.running && indexProgress.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("正在建立索引")
                            .font(.subheadline)
                        Spacer()
                        Text("\(indexProgress.done)/\(indexProgress.total)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: indexProgress.fraction)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("概览")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 存储列表

    private var storageSection: some View {
        Section {
            if loading && storages.isEmpty {
                LoadingRows(count: 4)
            } else if storages.isEmpty {
                Text("还没有挂载任何存储。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(storages) { storage in
                    NavigationLink {
                        AdminStorageDetail(serverId: serverId, storage: storage) {
                            Task { await reload() }
                        }
                    } label: {
                        storageRow(storage)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTarget = storage
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            Task { await toggle(storage) }
                        } label: {
                            Label(storage.disabled ? "启用" : "停用",
                                  systemImage: storage.disabled ? "play.circle" : "pause.circle")
                        }
                        .tint(storage.disabled ? .green : .orange)
                    }
                }
            }
        } header: {
            Text("挂载 · \(storages.count)")
        }
    }

    private func storageRow(_ storage: AdminStorage) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(storage.disabled ? Color.gray.opacity(0.16) : accent.opacity(0.15))
                Image(systemName: storage.disabled ? "externaldrive.badge.xmark" : "externaldrive.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(storage.disabled ? Color.secondary : accent)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(storage.mountPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(storage.driver.isEmpty ? "未知驱动" : storage.driver)
                    if !storage.remark.isEmpty {
                        Text("·")
                        Text(storage.remark).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(storage.statusLabel)
                .font(.caption2)
                .foregroundStyle(storage.disabled ? Color.secondary : Color.green)
        }
        .padding(.vertical, 1)
    }

    // MARK: - 功能入口

    private var entriesSection: some View {
        Section {
            NavigationLink {
                AdminUsersScreen(serverId: serverId)
            } label: {
                Label("用户管理", systemImage: "person.2")
            }
            NavigationLink {
                AdminSettingsScreen(serverId: serverId)
            } label: {
                Label("服务端设置", systemImage: "slider.horizontal.3")
            }
            NavigationLink {
                AdminTasksScreen(serverId: serverId)
            } label: {
                Label("服务端任务", systemImage: "list.bullet.rectangle")
            }
            NavigationLink {
                AdminSharesScreen(serverId: serverId)
            } label: {
                Label("分享管理", systemImage: "square.and.arrow.up.on.square")
            }
            NavigationLink {
                AdminMetaScreen(serverId: serverId)
            } label: {
                Label("元信息与权限", systemImage: "lock.doc")
            }
            NavigationLink {
                AdminMessageScreen(serverId: serverId)
            } label: {
                Label("服务端公告", systemImage: "megaphone")
            }
            NavigationLink {
                AdminMetaScreen(serverId: serverId)
            } label: {
                Label("元信息与权限", systemImage: "lock.doc")
            }
            NavigationLink {
                AdminMessageScreen(serverId: serverId)
            } label: {
                Label("服务端公告", systemImage: "megaphone")
            }
        } header: {
            Text("管理")
        }
    }

    // MARK: - 危险操作

    private var dangerSection: some View {
        Section {
            Button {
                Task { await buildIndex() }
            } label: {
                Label("重建搜索索引", systemImage: "magnifyingglass.circle")
            }
            Button {
                Task { await startScan() }
            } label: {
                Label("扫描挂载", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                Task { await reloadStorages() }
            } label: {
                Label("重新加载全部挂载", systemImage: "arrow.clockwise.circle")
            }
        } header: {
            Text("维护")
        } footer: {
            Text("「重建索引」会遍历全部挂载，目录很大时耗时较久；期间搜索可能返回不完整结果。")
        }
    }

    // MARK: - 动作

    private func ensureToken(_ server: ServerConfig) async throws -> String {
        try await servers.ensureToken(serverId, api: container.api).token
    }

    private func reload() async {
        guard let server else {
            errorText = "服务器已被删除"
            loading = false
            return
        }
        loading = true
        do {
            let token = try await ensureToken(server)
            async let list = container.admin.storages(baseUrl: server.url, token: token)
            async let progress = container.admin.indexProgress(baseUrl: server.url, token: token)
            storages = try await list
            indexProgress = (try? await progress) ?? indexProgress
            errorText = nil
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
        loading = false
    }

    private func toggle(_ storage: AdminStorage) async {
        guard let server else { return }
        busy = storage.disabled ? "正在启用…" : "正在停用…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            try await container.admin.setStorageEnabled(baseUrl: server.url, token: token,
                                                        id: storage.id, enabled: storage.disabled)
            await reload()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "操作失败")
        }
    }

    private func delete(_ storage: AdminStorage) async {
        guard let server else { return }
        deleteTarget = nil
        busy = "正在删除…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            try await container.admin.deleteStorage(baseUrl: server.url, token: token, id: storage.id)
            ToastCenter.shared.show("已删除「\(storage.mountPath)」")
            await reload()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "删除失败")
        }
    }

    private func buildIndex() async {
        guard let server else { return }
        busy = "正在重建索引…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            try await container.admin.buildIndex(baseUrl: server.url, token: token)
            ToastCenter.shared.show("索引任务已提交")
            await reload()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "提交失败")
        }
    }

    private func startScan() async {
        guard let server else { return }
        busy = "正在启动扫描…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            try await container.admin.startScan(baseUrl: server.url, token: token)
            ToastCenter.shared.show("扫描已启动")
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "启动失败")
        }
    }

    private func reloadStorages() async {
        guard let server else { return }
        busy = "正在重载…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            try await container.admin.reloadStorages(baseUrl: server.url, token: token)
            ToastCenter.shared.show("已重新加载全部挂载")
            await reload()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "重载失败")
        }
    }
}
