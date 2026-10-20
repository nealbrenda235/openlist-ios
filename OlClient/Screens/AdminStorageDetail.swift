//
//  AdminStorageDetail.swift
//  OpenList iOS
//
//  单个挂载的编辑页。
//
//  ★ 服务端语义：`/api/admin/storage/update` 是**整体覆盖**，
//    请求体里没有的字段会被写成空/零。Android 版曾经因为没建模
//    `extract_folder`，只改了个备注就把解压目录清空（数据损坏级问题）。
//    所以这里始终持有一份完整的 AdminStorage，改哪个字段就 copy 哪个，
//    提交时由 AdminApi.storageBody 一次性把全部字段带上。
//

import SwiftUI

struct AdminStorageDetail: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    let serverId: String
    @State private var storage: AdminStorage
    @State private var drivers: [String] = []
    @State private var schema: DriverSchema?
    @State private var additionValues: [String: String] = [:]
    @State private var saving = false
    @State private var loadingSchema = false
    @State private var errorText: String?
    @State private var showAddJSON = false
    @State private var rawJSON = ""

    private let onSaved: () -> Void

    init(serverId: String, storage: AdminStorage, onSaved: @escaping () -> Void) {
        self.serverId = serverId
        self._storage = State(initialValue: storage)
        self.onSaved = onSaved
    }

    private var server: ServerConfig? { servers.get(serverId) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("挂载路径")
                    Spacer()
                    Text(storage.mountPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Text("驱动")
                    Spacer()
                    Text(storage.driver.isEmpty ? "未选择" : storage.driver)
                        .foregroundStyle(.secondary)
                }
                TextField("备注", text: stringBinding(\.remark))
            } header: {
                Text("基本信息")
            }

            Section {
                Toggle("停用该挂载", isOn: boolBinding(\.disabled))
                Toggle("禁用索引", isOn: boolBinding(\.disableIndex))
                Toggle("签名直链", isOn: boolBinding(\.enableSign))
                Toggle("Web 代理", isOn: boolBinding(\.webProxy))
                Toggle("代理 Range 请求", isOn: boolBinding(\.proxyRange))
                Picker("WebDAV 策略", selection: stringBinding(\.webdavPolicy)) {
                    Text("302 重定向").tag("302_redirect")
                    Text("本机代理").tag("native_proxy")
                    Text("使用代理地址").tag("use_proxy_url")
                }
            } header: {
                Text("行为")
            } footer: {
                Text("签名直链开启后下载地址带 sign 参数；Web 代理让服务端转发文件流，兼容性更好但更耗服务器带宽。")
            }

            Section {
                TextField("缓存过期（分钟）", value: intBinding(\.cacheExpiration), format: .number)
                    .keyboardType(.numberPad)
                TextField("排序", text: stringBinding(\.orderBy))
                TextField("排序方向", text: stringBinding(\.orderDirection))
                TextField("解压目标目录", text: stringBinding(\.extractFolder))
                TextField("下载代理地址", text: stringBinding(\.downProxyUrl))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("高级")
            } footer: {
                Text("「解压目标目录」留空表示与压缩包同级。这些字段会随保存整体提交，不会因为没改而丢失。")
            }

            driverSection

            Section {
                Button {
                    rawJSON = storage.addition.isEmpty ? "{}" : storage.addition
                    showAddJSON = true
                } label: {
                    Label("编辑原始配置（JSON）", systemImage: "curlybraces")
                }
            } header: {
                Text("附加配置")
            } footer: {
                Text("驱动专属参数。上面的表单字段会写回这里，两处冲突时以最后保存的原始 JSON 为准。")
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(storage.mountPath)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("保存") }
                }
                .disabled(saving)
            }
        }
        .sheet(isPresented: $showAddJSON) {
            NavigationStack {
                TextEditor(text: $rawJSON)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .navigationTitle("附加配置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showAddJSON = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("应用") {
                                storage.addition = rawJSON
                                showAddJSON = false
                            }
                        }
                    }
            }
        }
        .task {
            await loadSchema()
        }
    }

    // MARK: - 驱动表单

    @ViewBuilder
    private var driverSection: some View {
        if loadingSchema {
            Section("驱动参数") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在读取驱动表单…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else if let schema, !schema.allFields.isEmpty {
            Section {
                ForEach(schema.allFields) { field in
                    fieldRow(field)
                }
            } header: {
                Text("驱动参数 · \(schema.name.isEmpty ? storage.driver : schema.name)")
            } footer: {
                if schema.noUpload {
                    Text("该驱动不支持上传。")
                }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: DriverField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case "bool":
                Toggle(field.name, isOn: Binding(
                    get: { (additionValues[field.name] ?? field.def).lowercased() == "true" },
                    set: { additionValues[field.name] = $0 ? "true" : "false" }
                ))

            case "select":
                Picker(field.name, selection: Binding(
                    get: { additionValues[field.name] ?? field.def },
                    set: { additionValues[field.name] = $0 }
                )) {
                    ForEach(field.optionList, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }

            case "text":
                TextField(field.name, text: Binding(
                    get: { additionValues[field.name] ?? field.def },
                    set: { additionValues[field.name] = $0 }
                ), axis: .vertical)
                .lineLimit(2...6)

            default:
                TextField(field.name, text: Binding(
                    get: { additionValues[field.name] ?? field.def },
                    set: { additionValues[field.name] = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            if !field.help.isEmpty {
                Text(field.help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 绑定

    private func stringBinding(_ keyPath: WritableKeyPath<AdminStorage, String>) -> Binding<String> {
        Binding(
            get: { storage[keyPath: keyPath] },
            set: { storage[keyPath: keyPath] = $0 }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<AdminStorage, Int>) -> Binding<Int> {
        Binding(
            get: { storage[keyPath: keyPath] },
            set: { storage[keyPath: keyPath] = $0 }
        )
    }

    /// 布尔字段单独命名：Swift 无法重载「仅 WritableKeyPath 泛型参数不同」的相同标签函数，
    /// 写成 stringBinding / boolBinding / intBinding 三个名字才不会报「ambiguous use」。
    private func boolBinding(_ keyPath: WritableKeyPath<AdminStorage, Bool>) -> Binding<Bool> {
        Binding(
            get: { storage[keyPath: keyPath] },
            set: { storage[keyPath: keyPath] = $0 }
        )
    }

    // MARK: - 加载与保存

    private func loadSchema() async {
        guard let server else { return }
        loadingSchema = true
        defer { loadingSchema = false }

        // 先把已有的 addition 摊平到表单
        additionValues = storage.additionObject.mapValues { value in
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            if let b = value as? Bool { return b ? "true" : "false" }
            return ""
        }

        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            drivers = (try? await container.admin.driverNames(baseUrl: server.url, token: token)) ?? []
            if !storage.driver.isEmpty {
                schema = try await container.admin.driverSchema(baseUrl: server.url,
                                                                token: token,
                                                                driver: storage.driver)
                // 补齐表单默认值
                if let schema {
                    for field in schema.allFields where additionValues[field.name] == nil && !field.def.isEmpty {
                        additionValues[field.name] = field.def
                    }
                }
            }
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    private func save() async {
        guard let server else { return }
        saving = true
        defer { saving = false }

        // 表单值合并回 addition（保持原有未在表单里的键）
        var merged = storage.additionObject
        for (key, value) in additionValues {
            merged[key] = value
        }
        if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            storage.addition = text
        }

        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.updateStorage(baseUrl: server.url, token: token, storage: storage)
            ToastCenter.shared.show("已保存")
            onSaved()
            dismiss()
        } catch {
            errorText = (error as? ApiError)?.message ?? "保存失败"
        }
    }
}
