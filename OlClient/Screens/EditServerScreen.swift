//
//  EditServerScreen.swift
//  OpenList iOS
//
//  新增 / 编辑服务器。
//
//  ## 为什么有这个 wrapInNavigation 参数
//
//  这个视图有两种入口：
//  - 文件页用 `.sheet` 弹出 → 需要自带 NavigationStack（否则没有标题栏和按钮）
//  - 设置页用 `nav.push` 推进已有导航栈 → **不能**再包一层
//
//  v3 的 bug 就是无脑自带 NavigationStack，被 push 时形成
//  NavStack → NavStack 嵌套，iOS 不崩溃但导航失效，用户点服务器「没反应」。
//

import SwiftUI

struct EditServerScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    /// 传入 nil 表示新增。
    let server: ServerConfig?
    /// true = 自带 NavigationStack（sheet 用）；false = 由调用方提供（push 用）。
    var wrapInNavigation: Bool = true

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var rootPath = "/"
    @State private var useOTP = false
    @State private var otp = ""

    @State private var testing = false
    @State private var saving = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var errorText: String?
    @State private var showDeleteConfirm = false

    private var isNew: Bool { server == nil }
    private var canSave: Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if wrapInNavigation {
                NavigationStack { form }
            } else {
                form
            }
        }
    }

    private var form: some View {
        Form {
            Section("服务器") {
                TextField("名称（可选）", text: $name)
                    .textInputAutocapitalization(.never)
                TextField("地址", text: $url, prompt: Text("http://192.168.1.10:5244"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("起始路径", text: $rootPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            } header: {
                Text("账号")
            } footer: {
                Text("凭据保存在系统钥匙串中，仅本机可读。token 失效时用这里的账号自动重新登录。")
            }

            Section {
                Toggle("两步验证码", isOn: $useOTP)
                if useOTP {
                    TextField("otp_code", text: $otp)
                        .keyboardType(.numberPad)
                }
            } footer: {
                Text("只有开启了二次验证的账号才需要填写。")
            }

            if let testResult {
                Section {
                    Label {
                        Text(testResult.text).font(.footnote)
                    } icon: {
                        Image(systemName: testResult.ok
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(testResult.ok ? .green : .orange)
                    }
                }
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if testing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(testing || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !isNew {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text("删除这台服务器")
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
        .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .alert("删除服务器？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let server {
                    servers.remove(server.id)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("地址与凭据会一并删除，已下载的文件不受影响。")
        }
        .task { loadExisting() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if wrapInNavigation {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView().controlSize(.small) } else { Text("保存") }
            }
            .disabled(!canSave || saving)
        }
    }

    private var normalizedURL: String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return text }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: normalizedURL)?.host ?? normalizedURL
    }

    private func loadExisting() {
        guard let server else {
            if url.isEmpty { url = "http://" }
            return
        }
        name = server.name
        url = server.url
        username = server.username
        password = server.password
        rootPath = server.rootPath
    }

    // MARK: - 动作

    private func test() async {
        testing = true
        defer { testing = false }
        let base = normalizedURL
        guard !base.isEmpty else {
            testResult = (false, "请填写服务器地址")
            return
        }
        do {
            // 测试不写库，只验证连通与凭据
            let session = try await container.api.login(baseUrl: base,
                                                        username: username,
                                                        password: password,
                                                        otp: useOTP ? otp : "")
            let account = try await container.api.me(baseUrl: base, token: session.token)
            testResult = (true, "连接成功 · \(account.username)（\(account.roleLabel)）")
        } catch {
            testResult = (false, (error as? ApiError)?.message ?? error.localizedDescription)
        }
    }

    private func save() async {
        let base = normalizedURL
        guard !base.isEmpty else { return }
        saving = true
        defer { saving = false }

        var config = server ?? ServerConfig.new()
        config.name = name.trimmingCharacters(in: .whitespaces)
        config.url = base
        config.username = username
        config.password = password
        config.rootPath = PathUtil.normalize(rootPath)
        config.lastSeenAt = Date().timeIntervalSince1970

        do {
            let session = try await container.api.login(baseUrl: base,
                                                        username: username,
                                                        password: password,
                                                        otp: useOTP ? otp : "")
            let account = try await container.api.me(baseUrl: base, token: session.token)
            config.token = session.token
            config.role = account.role
        } catch {
            // 登录失败不阻断保存：配置先落地，用户可稍后点「重新登录」
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }

        if isNew {
            servers.add(config)
        } else {
            servers.update(config)
        }
        ToastCenter.shared.show(isNew ? "已添加「\(displayName)」" : "已保存")
        dismiss()
    }
}
