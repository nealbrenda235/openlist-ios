//
//  AdminShareCreate.swift
//  OpenList iOS
//
//  创建 / 编辑分享。
//
//  ★ 服务端 /api/share/update 是**全量覆盖**：未传字段会被写成零值。
//    所以编辑必须 GET 完整对象 → 改字段 → 整体提交（Android 版同样注释过这个坑）。
//

import SwiftUI

struct AdminShareCreateScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    let serverId: String
    /// 传入已存在的分享表示编辑。
    var editing: ShareItem? = nil
    var initialFiles: [String] = []
    var onDone: () -> Void = {}

    @State private var files: [String] = []
    @State private var pwd = ""
    @State private var remark = ""
    @State private var expireChoice = 0
    @State private var maxAccessed = 0
    @State private var readme = ""
    @State private var header = ""
    @State private var saving = false
    @State private var errorText: String?
    @State private var newPath = ""
    @State private var loading = false

    private var server: ServerConfig? { servers.get(serverId) }
    private var isEditing: Bool { editing != nil }

    private let expireOptions = [("永久", 0), ("1 天", 1), ("7 天", 7), ("30 天", 30)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if files.isEmpty {
                        Text("还没有选择文件。添加要分享的路径。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files, id: \.self) { path in
                            HStack {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet.sorted(by: >) where files.indices.contains(i) {
                                files.remove(at: i)
                            }
                        }
                    }

                    HStack {
                        TextField("添加路径，如 /docs/a.pdf", text: $newPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("添加") {
                            let p = PathUtil.normalize(newPath)
                            guard p != "/", !p.isEmpty else { return }
                            if !files.contains(p) { files.append(p) }
                            newPath = ""
                        }
                        .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("分享内容")
                } footer: {
                    Text("分享的是服务端绝对路径。多个文件可以一次分享。")
                }

                Section {
                    TextField("提取码（留空则不需要）", text: $pwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（仅自己可见）", text: $remark)
                    Picker("有效期", selection: $expireChoice) {
                        ForEach(expireOptions, id: \.1) { item in
                            Text(item.0).tag(item.1)
                        }
                    }
                    Stepper(value: $maxAccessed, in: 0...9999) {
                        HStack {
                            Text("访问上限")
                            Spacer()
                            Text(maxAccessed == 0 ? "不限" : "\(maxAccessed) 次")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("访问设置")
                }

                Section {
                    TextField("说明（访客可见）", text: $readme, axis: .vertical)
                        .lineLimit(2...6)
                    TextField("页头 HTML（高级）", text: $header, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("展示")
                } footer: {
                    Text("页头 HTML 会渲染在分享页顶部，留空即可。")
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            Task { await deleteShare() }
                        } label: {
                            Text("删除这个分享")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑分享" : "创建分享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text("保存") }
                    }
                    .disabled(saving || files.isEmpty)
                }
            }
            .task {
                files = editing?.files ?? initialFiles
                if let editing {
                    pwd = editing.pwd
                    remark = editing.remark
                    readme = editing.readme
                    header = editing.header
                    maxAccessed = editing.maxAccessed
                    await reloadFull()
                }
            }
        }
    }

    /// 编辑前先 GET 完整对象，避免全量覆盖把 readme / header / accessed 写零。
    private func reloadFull() async {
        guard let server, let editing else { return }
        loading = true
        defer { loading = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            if let full = try await container.admin.share(baseUrl: server.url, token: token, id: editing.id) {
                files = full.files
                pwd = full.pwd
                remark = full.remark
                maxAccessed = full.maxAccessed
            }
        } catch {
            // 拿不到完整对象就不阻断，用列表里的字段继续
        }
    }

    private var expiresValue: String? {
        guard expireChoice > 0 else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date().addingTimeInterval(Double(expireChoice) * 86400))
    }

    private func save() async {
        guard let server else { return }
        saving = true
        defer { saving = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            if let editing {
                try await container.admin.updateShare(
                    baseUrl: server.url, token: token,
                    id: editing.id,
                    files: files,
                    pwd: pwd,
                    remark: remark,
                    expires: expiresValue,
                    maxAccessed: maxAccessed,
                    readme: readme,
                    header: header,
                    accessed: editing.accessed,
                    disabled: editing.disabled
                )
                ToastCenter.shared.show("已更新分享")
            } else {
                let share = try await container.admin.createShare(
                    baseUrl: server.url, token: token,
                    files: files,
                    pwd: pwd,
                    remark: remark,
                    expires: expiresValue,
                    maxAccessed: maxAccessed,
                    readme: readme,
                    header: header
                )
                ToastCenter.shared.show("已创建分享 · \(share.id)")
            }
            onDone()
            dismiss()
        } catch {
            errorText = (error as? ApiError)?.message ?? "保存失败"
        }
    }

    private func deleteShare() async {
        guard let server, let editing else { return }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.admin.deleteShare(baseUrl: server.url, token: token, id: editing.id)
            ToastCenter.shared.show("已删除分享")
            onDone()
            dismiss()
        } catch {
            errorText = (error as? ApiError)?.message ?? "删除失败"
        }
    }
}
