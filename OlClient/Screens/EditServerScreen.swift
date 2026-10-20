//
//  EditServerScreen.swift
//  OpenList iOS
//
//  新增 / 编辑服务器。用 Form + 系统输入控件，
//  保存时会真的登录一次以拿到 token 与角色，失败允许强制保存。
//

import SwiftUI

struct EditServerScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    /// 传入 nil 表示新增。
    let server: ServerConfig?

    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var rootPath = "/"
    @State private var otp = ""
    @State private var showOTP = false

    @State private var testing = false
    @State private var saving = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var errorText: String?

    private var isNew: Bool { server == nil }

    private var canSave: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
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
                    Text("凭据保存在系统钥匙串中，仅本机可读。token 失效时会用这里的账号自动重新登录。")
                }

                Section {
                    Toggle("两步验证码", isOn: $showOTP)
                    if showOTP {
                        TextField("otp_code", text: $otp)
                            .keyboardType(.numberPad)
                    }
                } footer: {
                    Text("只有开启了二次验证的账号才需要填写。")
                }

                if let testResult {
                    Section {
                        Label {
                            Text(testResult.text)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
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

                    if isNew {
                        Button {
                            Task { await save() }
                        } label: {
                            HStack {
                                Text("保存")
                                Spacer()
                                if saving { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(!canSave || saving)
                    }
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            if let server {
                                servers.remove(server.id)
                                dismiss()
                            }
                        } label: {
                            Text("删除这台服务器")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task { await save() }
                    }
                    .disabled(!canSave || saving)
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("仅保存配置") {
                    persist(token: server?.token ?? "", role: server?.role ?? 0)
                    errorText = nil
                    dismiss()
                }
                Button("重试", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .task { loadExisting() }
        }
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

    private var normalizedURL: String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return text }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
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
            let session = try await container.api.login(baseUrl: base,
                                                        username: username,
                                                        password: password,
                                                        otp: showOTP ? otp : "")
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

        do {
            let session = try await container.api.login(baseUrl: base,
                                                        username: username,
                                                        password: password,
                                                        otp: showOTP ? otp : "")
            let account = try await container.api.me(baseUrl: base, token: session.token)
            persist(token: session.token, role: account.role)
            ToastCenter.shared.show(isNew ? "已添加「\(displayName)」" : "已保存")
            dismiss()
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: normalizedURL)?.host ?? normalizedURL
    }

    private func persist(token: String, role: Int) {
        var config = server ?? ServerConfig.new()
        config.name = name.trimmingCharacters(in: .whitespaces)
        config.url = normalizedURL
        config.username = username
        config.password = password
        config.token = token
        config.role = role
        config.rootPath = PathUtil.normalize(rootPath)
        config.lastSeenAt = Date().timeIntervalSince1970
        if isNew {
            servers.add(config)
        } else {
            servers.update(config)
        }
    }
}
