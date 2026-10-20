//
//  PreviewScreen.swift
//  OpenList iOS
//
//  文本 / 图片 / PDF 预览。文本可直接编辑并回写（`/api/fs/put`）。
//  超过上限的文件只读预览，避免把手机内存打爆。
//

import SwiftUI
import PDFKit

struct PreviewScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore

    let serverId: String
    let path: String

    @State private var file: RemoteFile?
    @State private var text = ""
    @State private var originalText = ""
    @State private var encoding = "utf-8"
    @State private var image: UIImage?
    @State private var pdf: PDFDocument?
    @State private var loading = true
    @State private var errorText: String?
    @State private var saving = false
    @State private var editing = false

    private var changed: Bool { text != originalText }

    var body: some View {
        Group {
            if loading {
                ProgressView("加载中…")
            } else if let errorText {
                ScrollView {
                    EmptyState(title: "无法预览", detail: errorText, symbol: "exclamationmark.triangle") {
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                }
            } else if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }
                .background(Color(.systemBackground))
            } else if let pdf {
                PDFKitView(document: pdf)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                editor
            }
        }
        .navigationTitle(file?.name ?? "预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if file?.isText == true && image == nil && pdf == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    if editing {
                        Button("完成") {
                            Task { await save() }
                        }
                        .disabled(saving || !changed)
                    } else {
                        Button("编辑") { editing = true }
                    }
                }
            }
        }
        .task { await load() }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if editing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Text("编码 \(encoding.uppercased())")
                Spacer()
                Text("\(text.count) 字符")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.regularMaterial)
        }
    }

    // MARK: - 加载与保存

    private func load() async {
        loading = true
        errorText = nil
        do {
            guard let server = servers.get(serverId) else { throw ApiError.local("服务器已被删除") }
            let token = try await servers.ensureToken(serverId, api: container.api).token
            let name = (path as NSString).lastPathComponent
            let remote = RemoteFile(path: path, name: name)
            file = remote

            if remote.isText {
                let result = try await container.api.readText(baseUrl: server.url, token: token, file: remote)
                text = result.text
                originalText = result.text
                encoding = result.encoding
            } else {
                let data = try await container.api.readBytes(baseUrl: server.url, token: token, file: remote)
                if remote.isPdf {
                    pdf = PDFDocument(data: data)
                    if pdf == nil { errorText = "PDF 解析失败" }
                } else {
                    image = UIImage(data: data)
                    if image == nil { errorText = "图片格式不受支持" }
                }
            }
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
        }
        loading = false
    }

    private func save() async {
        guard let server = servers.get(serverId) else { return }
        saving = true
        defer { saving = false }
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            try await container.api.writeText(baseUrl: server.url, token: token,
                                              path: path, text: text, encoding: encoding)
            originalText = text
            editing = false
            ToastCenter.shared.show("已保存")
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "保存失败")
        }
    }
}

// MARK: - PDFKit 封装

struct PDFKitView: UIViewRepresentable {

    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document { uiView.document = document }
    }
}
