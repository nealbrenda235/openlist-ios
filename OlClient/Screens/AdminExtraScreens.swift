//
//  AdminExtraScreens.swift
//  OpenList iOS
//
//  补齐后台管理剩下的三块：
//  - 新建挂载向导（选驱动 → 填必填项 → 创建）
//  - 元信息管理（路径加密 / 隐藏规则）
//  - 服务端公告（message）
//

import SwiftUI

// MARK: - 新建挂载

struct AdminStorageCreateScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    let serverId: String
    var onCreated: () -> Void = {}

    @State private var drivers: [String] = []
    @State private var driver = ""
    @State private var mountPath = ""
    @State private var schema: DriverSchema?
    @State private var values: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var errorText: String?

    private var server: ServerConfig? { servers.get(serverId) }

    var body: some View {
        Form {
            Section {
                Picker("驱动", selection: $driver) {
                    Text("请选择").tag("")
                    ForEach(drivers, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                TextField("挂载路径，如 /mydisk", text: $mountPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("基本信息")
            } footer: {
                Text("挂载路径不能与已有挂载重复。驱动选好后会自动加载它需要的参数。")
            }

            if loading && !driver.isEmpty {
                Section { LoadingRows(count: 3) }
            } else if let schema, !schema.allFields.isEmpty {
                Section {
                    ForEach(schema.allFields) { field in
                        dynamicField(field)
                    }
                } header: {
                    Text("驱动参数")
                } footer: {
                    if schema.noUpload {
                        Text("该驱动不支持上传。")
                    }
                }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("新建挂载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await create() }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("创建") }
                }
                .disabled(saving || driver.isEmpty || mountPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { await loadDrivers() }
        .onChange(of: driver) { _ in
            Task { await loadSchema() }
        }
    }

    @ViewBuilder
    private func dynamicField(_ field: DriverField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case "bool":
                Toggle(field.name, isOn: Binding(
                    get: { (values[field.name] ?? field.def).lowercased() == "true" },
                    set: { values[field.name] = $0 ? "true" : "false" }
                ))
            case "select":
                Picker(field.name, selection: Binding(
                    get: { values[field.name] ?? field.def },
                    set: { values[field.name] = $0 }
                )) {
                    ForEach(field.optionList, id: \.self) { Text($0).tag($0) }
                }
            case "text":
                TextField(field.name, text: Binding(
                    get: { values[field.name] ?? field.def },
                    set: { values[field.name] = $0 }
                ), axis: .vertical)
                .lineLimit(2...6)
            default:
                TextField(field.name, text: Binding(
                    get: { values[field.name] ?? field.def },
                    set: { values[field.name] = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            if !field.help.isEmpty {
                Text(field.help).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func loadDrivers() async {
        guard let server else { return }
        loading = true
        defer { loading = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            drivers = try await container.admin.driverNames(baseUrl: server.url, token: token)
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    private func loadSchema() async {
        guard let server, !driver.isEmpty else {
            schema = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            schema = try await container.admin.driverSchema(baseUrl: server.url, token: token, driver: driver)
            values = [:]
            if let schema {
                for field in schema.allFields where !field.def.isEmpty {
                    values[field.name] = field.def
                }
            }
            errorText = nil
        } catch {
            errorText = (error as? ApiError)?.message ?? "读取驱动参数失败"
        }
    }

    private func create() async {
        guard let server else { return }
        saving = true
        defer { saving = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token

            // addition 是 JSON 字符串：按字段类型还原成 bool / number / string
            var addition: [String: Any] = [:]
            if let schema {
                for field in schema.allFields {
                    let raw = values[field.name] ?? field.def
                    switch field.type {
                    case "bool":
                        addition[field.name] = raw.lowercased() == "true"
                    case "number":
                        addition[field.name] = Int(raw) ?? raw
                    default:
                        addition[field.name] = raw
                    }
                }
            }
            let additionText: String
            if let data = try? JSONSerialization.data(withJSONObject: addition, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                additionText = text
            } else {
                additionText = "{}"
            }

            var storage = container.admin.emptyStorage(driver: driver,
                                                       mountPath: PathUtil.normalize(mountPath))
            storage.addition = additionText
            try await container.admin.createStorage(baseUrl: server.url, token: token, storage: storage)
            ToastCenter.shared.show("已创建挂载「\(storage.mountPath)」")
            onCreated()
            dismiss()
        } catch {
            errorText = (error as? ApiError)?.message ?? "创建失败"
        }
    }
}

// MARK: - 元信息

struct AdminMetaScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String

    @State private var items: [AdminMetaItem] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var showCreate = false
    @State private var newPath = ""
    @State private var newPassword = ""
    @State private var deleteTarget: AdminMetaItem?

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

            Section {
                Text("给指定路径加访问密码、隐藏规则或只读限制。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if loading && items.isEmpty {
                Section { LoadingRows(count: 3) }
            } else if items.isEmpty {
                Section {
                    Text("还没有元信息规则。").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("规则 · \(items.count)") {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.path).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 5) {
                                if !item.password.isEmpty { Text("有密码") }
                                if item.pSub { Text("· 子目录生效") }
                                if item.write { Text("· 可写") }
                                if !item.hide.isEmpty { Text("· 隐藏 \(item.hide)") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteTarget = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("元信息")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newPath = ""
                    newPassword = ""
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    Section("新规则") {
                        TextField("路径，如 /private", text: $newPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("访问密码（留空则无）", text: $newPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("添加规则")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showCreate = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            Task { await create() }
                        }
                        .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .alert("删除规则？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { item in
            Button("删除", role: .destructive) {
                Task { await delete(item) }
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { item in
            Text("「\(item.path)」的密码与限制会被移除。")
        }
    }

    private func load() async {
        guard let server else { return }
        loading = true
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            items = try await container.admin.metaList(baseUrl: server.url, token: token)
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
            try await container.admin.createMeta(baseUrl: server.url, token: token,
                                                 path: newPath, password: newPassword)
            showCreate = false
            ToastCenter.shared.show("已添加规则")
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "添加失败")
        }
    }

    private func delete(_ item: AdminMetaItem) async {
        guard let server else { return }
        deleteTarget = nil
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.deleteMeta(baseUrl: server.url, token: token, id: item.id)
            ToastCenter.shared.show("已删除规则")
            await load()
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "删除失败")
        }
    }
}

// MARK: - 服务端公告

struct AdminMessageScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String

    @State private var message = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var errorText: String?

    private var server: ServerConfig? { servers.get(serverId) }
    private var changed: Bool { message != original }

    var body: some View {
        Form {
            Section {
                if loading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("读取中…").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    TextEditor(text: $message)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                }
            } header: {
                Text("公告内容")
            } footer: {
                Text("支持 Markdown。所有访客会在首页顶部看到这段公告，留空表示不显示。")
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("服务端公告")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("发布") }
                }
                .disabled(saving || !changed)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let server else { return }
        loading = true
        defer { loading = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            let msg = try await container.admin.messageGet(baseUrl: server.url, token: token)
            message = msg.content
            original = msg.content
            errorText = nil
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    private func save() async {
        guard let server else { return }
        saving = true
        defer { saving = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.messageSend(baseUrl: server.url, token: token, message: message)
            original = message
            ToastCenter.shared.show("公告已发布")
        } catch {
            errorText = (error as? ApiError)?.message ?? "发布失败"
        }
    }
}
