//
//  AdminSubScreens.swift
//  OpenList iOS
//
//  后台管理的四个子页：用户、服务端设置、服务端任务、分享。
//  都是「读列表 → 简单操作」，用 List + 系统控件，不做自绘。
//

import SwiftUI

// MARK: - 用户管理

struct AdminUsersScreen: View {
    @Environment(\.olAccent) private var accent

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String

    @State private var users: [ServerUser] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newPassword = ""
    @State private var newBasePath = "/"
    @State private var newRole = 0
    @State private var deleteTarget: ServerUser?

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

            if loading && users.isEmpty {
                Section { LoadingRows(count: 4) }
            } else if users.isEmpty {
                Section {
                    Text("还没有其他用户。").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("用户 · \(users.count)") {
                    ForEach(users) { user in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(user.username)
                                Spacer()
                                Text(user.roleLabel)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(accent.opacity(0.13), in: Capsule())
                                    .foregroundStyle(.tint)
                            }
                            Text(user.basePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = user
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                Task { await clearCache(user) }
                            } label: {
                                Label("清缓存", systemImage: "trash.slash")
                            }
                            .tint(.orange)
                            Button {
                                Task { await cancel2FA(user) }
                            } label: {
                                Label("取消 2FA", systemImage: "key.slash")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("用户")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    newPassword = ""
                    newBasePath = "/"
                    newRole = 0
                    showCreate = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    Section("新用户") {
                        TextField("用户名", text: $newName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $newPassword)
                        TextField("根路径", text: $newBasePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Picker("角色", selection: $newRole) {
                            Text("普通用户").tag(0)
                            Text("访客").tag(1)
                            Text("管理员").tag(2)
                        }
                    }
                }
                .navigationTitle("添加用户")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showCreate = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") {
                            Task { await create() }
                        }
                        .disabled(newName.isEmpty || newPassword.isEmpty)
                    }
                }
            }
        }
        .alert("删除用户？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { user in
            Button("删除", role: .destructive) {
                Task { await delete(user) }
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { user in
            Text("「\(user.username)」将无法再登录，但其文件不会被删除。")
        }
    }

    private func load() async {
        guard let server else { return }
        loading = true
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            users = try await container.admin.users(baseUrl: server.url, token: token)
            errorText = nil
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
        loading = false
    }

    private func create() async {
        guard let server else { return }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.createUser(baseUrl: server.url, token: token,
                                                 username: newName.trimmingCharacters(in: .whitespaces),
                                                 password: newPassword,
                                                 basePath: newBasePath,
                                                 role: newRole)
            showCreate = false
            ToastCenter.shared.show("已创建「\(newName)」")
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "创建失败")
        }
    }

    private func delete(_ user: ServerUser) async {
        guard let server else { return }
        deleteTarget = nil
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.deleteUser(baseUrl: server.url, token: token, id: user.id)
            ToastCenter.shared.show("已删除「\(user.username)」")
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "删除失败")
        }
    }

    private func clearCache(_ user: ServerUser) async {
        guard let server else { return }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.clearUserCache(baseUrl: server.url, token: token, id: user.id)
            ToastCenter.shared.show("已清理「\(user.username)」的缓存")
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "清理失败")
        }
    }

    private func cancel2FA(_ user: ServerUser) async {
        guard let server else { return }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.cancelUser2fa(baseUrl: server.url, token: token, id: user.id)
            ToastCenter.shared.show("已取消「\(user.username)」的 2FA")
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "操作失败")
        }
    }
}

// MARK: - 服务端设置

struct AdminSettingsScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String

    @State private var groups: [Int] = [0, 1, 2, 3, 4]
    @State private var group = 0
    @State private var items: [AdminSettingItem] = []
    @State private var drafts: [String: String] = [:]
    @State private var loading = true
    @State private var errorText: String?
    @State private var saving = false

    private var server: ServerConfig? { servers.get(serverId) }

    private var changed: [(key: String, value: String)] {
        items.compactMap { item in
            guard let draft = drafts[item.key], draft != item.value else { return nil }
            return (item.key, draft)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("分组", selection: $group) {
                    ForEach(groups, id: \.self) { value in
                        Text(groupLabel(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if loading && items.isEmpty {
                Section { LoadingRows(count: 5) }
            } else if items.isEmpty {
                Section {
                    Text("这个分组没有可编辑的设置项。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("设置项 · \(items.count)") {
                    ForEach(items) { item in
                        settingRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("服务端设置")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: group) { _ in
            Task { await load() }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await saveAll() }
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(changed.isEmpty ? "保存" : "保存(\(changed.count))")
                    }
                }
                .disabled(changed.isEmpty || saving)
            }
        }
    }

    @ViewBuilder
    private func settingRow(_ item: AdminSettingItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch item.type {
            case "bool":
                Toggle(item.key, isOn: Binding(
                    get: { (drafts[item.key] ?? item.value).lowercased() == "true" },
                    set: { drafts[item.key] = $0 ? "true" : "false" }
                ))
            case "select":
                Picker(item.key, selection: Binding(
                    get: { drafts[item.key] ?? item.value },
                    set: { drafts[item.key] = $0 }
                )) {
                    ForEach(options(item.options), id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            case "number":
                TextField(item.key, text: Binding(
                    get: { drafts[item.key] ?? item.value },
                    set: { drafts[item.key] = $0 }
                ))
                .keyboardType(.numbersAndPunctuation)
            default:
                TextField(item.key, text: Binding(
                    get: { drafts[item.key] ?? item.value },
                    set: { drafts[item.key] = $0 }
                ), axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            if !item.help.isEmpty {
                Text(item.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    private func options(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func groupLabel(_ value: Int) -> String {
        switch value {
        case 0: return "常规"
        case 1: return "样式"
        case 2: return "预览"
        case 3: return "全局"
        case 4: return "单点登录"
        default: return "分组 \(value)"
        }
    }

    private func load() async {
        guard let server else { return }
        loading = true
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            items = try await container.admin.settings(baseUrl: server.url, token: token, group: group)
            drafts = items.reduce(into: [:]) { $0[$1.key] = $1.value }
            errorText = nil
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
        loading = false
    }

    private func saveAll() async {
        guard let server else { return }
        saving = true
        defer { saving = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            for pair in changed {
                try await container.admin.saveSetting(baseUrl: server.url, token: token,
                                                      key: pair.key, value: pair.value)
            }
            ToastCenter.shared.show("已保存 \(changed.count) 项")
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "保存失败")
        }
    }
}

// MARK: - 服务端任务

struct AdminTasksScreen: View {
    @Environment(\.olAccent) private var accent

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String

    @State private var tasks: [ServerTask] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var autoRefresh = true
    @State private var timer: Timer?

    private var server: ServerConfig? { servers.get(serverId) }

    private var active: [ServerTask] { tasks.filter(\.isActive) }
    private var finished: [ServerTask] { tasks.filter { !$0.isActive } }

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("自动刷新（3 秒）", isOn: $autoRefresh)
            }

            if loading && tasks.isEmpty {
                Section { LoadingRows(count: 4) }
            } else if tasks.isEmpty {
                Section {
                    Text("服务端没有任务。").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                if !active.isEmpty {
                    Section("进行中 · \(active.count)") {
                        ForEach(active) { task in
                            taskRow(task)
                        }
                    }
                }
                if !finished.isEmpty {
                    Section("已结束 · \(finished.count)") {
                        ForEach(finished) { task in
                            taskRow(task)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("服务端任务")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await load()
            startTimer()
        }
        .onDisappear { stopTimer() }
        .onChange(of: autoRefresh) { value in
            value ? startTimer() : stopTimer()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await bulk("cancel") }
                    } label: {
                        Label("取消全部进行中", systemImage: "xmark.circle")
                    }
                    Button(role: .destructive) {
                        Task { await bulk("delete") }
                    } label: {
                        Label("删除全部已结束", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func taskRow(_ task: ServerTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(task.stateLabel)
                    .font(.caption2)
                    .foregroundStyle(task.isActive ? accent : Color.secondary)
            }

            if task.isActive {
                ProgressView(value: max(0, min(1, task.progress / 100)))
            }

            if !task.error.isEmpty {
                Text(task.error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await action(task, "delete") }
            } label: {
                Label("删除", systemImage: "trash")
            }
            if task.isActive {
                Button {
                    Task { await action(task, "cancel") }
                } label: {
                    Label("取消", systemImage: "xmark")
                }
                .tint(.orange)
            } else {
                Button {
                    Task { await action(task, "retry") }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .tint(.green)
            }
        }
    }

    private func startTimer() {
        stopTimer()
        guard autoRefresh else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { await load() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func load() async {
        guard let server else { return }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            tasks = try await container.admin.tasks(baseUrl: server.url, token: token)
            errorText = nil
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
        loading = false
    }

    private func action(_ task: ServerTask, _ name: String) async {
        guard let server else { return }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.taskAction(baseUrl: server.url, token: token,
                                                 tid: task.id, action: name)
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "操作失败")
        }
    }

    private func bulk(_ name: String) async {
        guard let server else { return }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            for kind in ServerTaskKind.allCases {
                try? await container.admin.taskAction(baseUrl: server.url, token: token,
                                                      tid: "\(kind.rawValue):", action: name)
            }
            // 单个 id 的接口不支持批量，这里逐个处理当前列表
            let targets = name == "cancel" ? active : finished
            for task in targets {
                try? await container.admin.taskAction(baseUrl: server.url, token: token,
                                                      tid: task.id, action: name)
            }
            ToastCenter.shared.show("已处理 \(targets.count) 个任务")
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "操作失败")
        }
    }
}

// MARK: - 分享管理

struct AdminSharesScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String

    @State private var shares: [ShareItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var deleteTarget: ShareItem?
    @State private var editing: ShareItem?
    @State private var showCreate = false

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

            if loading && shares.isEmpty {
                Section { LoadingRows(count: 4) }
            } else if shares.isEmpty {
                Section {
                    Text("还没有创建分享。").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("分享 · \(shares.count)") {
                    ForEach(shares) { share in
                        Button {
                            editing = share
                        } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(share.files.first.map { ($0 as NSString).lastPathComponent } ?? share.id)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(share.statusText)
                                    .font(.caption2)
                                    .foregroundStyle(share.disabled ? Color.secondary : Color.green)
                            }
                            HStack(spacing: 5) {
                                Text("\(share.accessed)/\(share.maxAccessed)")
                                if !share.pwd.isEmpty {
                                    Text("·")
                                    Text("密码 \(share.pwd)")
                                }
                                if !share.creator.isEmpty {
                                    Text("·")
                                    Text(share.creator)
                                }
                                if !share.expires.isEmpty {
                                    Text("·")
                                    Text(share.expires)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = share
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                UIPasteboard.general.string = shareURL(share)
                                ToastCenter.shared.show("已复制分享链接")
                            } label: {
                                Label("复制链接", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("分享")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            AdminShareCreateScreen(serverId: serverId) {
                Task { await load() }
            }
        }
        .sheet(item: $editing) { share in
            AdminShareCreateScreen(serverId: serverId, editing: share) {
                Task { await load() }
            }
        }
        .alert("删除分享？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { share in
            Button("删除", role: .destructive) {
                Task { await delete(share) }
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { share in
            Text("分享链接会立即失效，已发出的链接无法再打开。")
        }
    }

    private func shareURL(_ share: ShareItem) -> String {
        guard let server else { return share.id }
        let base = server.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/s/\(share.id)"
    }

    private func load() async {
        guard let server else { return }
        loading = true
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            shares = try await container.admin.shares(baseUrl: server.url, token: token)
            errorText = nil
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
        loading = false
    }

    private func delete(_ share: ShareItem) async {
        guard let server else { return }
        deleteTarget = nil
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.deleteShare(baseUrl: server.url, token: token, id: share.id)
            ToastCenter.shared.show("已删除分享")
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "删除失败")
        }
    }
}
