//
//  BrowseScreen.swift
//  OpenList iOS
//
//  目录浏览：列表 / 网格、本目录筛选、排序、分页、长按菜单、上传。
//  所有跳转都走 NavModel，网格与列表共用同一套动作。
//

import SwiftUI
import UniformTypeIdentifiers

struct BrowseScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var prefs: FilePrefs
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var nav: NavModel
    @Environment(\.olAccent) private var accent

    let serverId: String
    let initialPath: String

    @State private var files: [RemoteFile] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var layout: ListLayout = .list
    @State private var sort = SortChoice()
    @State private var filter = ""
    @State private var showUploadPicker = false
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var deleteTarget: RemoteFile?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var busy: String?
    @State private var page = 1
    @State private var total = 0
    @State private var hasMore = false
    @State private var showOfflineSheet = false
    @State private var offlineURL = ""

    private var server: ServerConfig? { servers.get(serverId) }
    private var path: String { PathUtil.normalize(initialPath) }

    private var visibleFiles: [RemoteFile] {
        var list = files
        if filter.trimmingCharacters(in: .whitespaces).isEmpty {
            if !settings.showHidden {
                list = list.filter { !$0.name.hasPrefix(".") }
            }
        } else {
            let key = filter.lowercased()
            list = list.filter { $0.name.lowercased().contains(key) }
        }
        return sort.apply(to: list)
    }

    var body: some View {
        content
            .navigationTitle(PathUtil.displayName(path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) { breadcrumbBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .fileImporter(isPresented: $showUploadPicker,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { handleImport($0) }
            .task {
                guard let server else {
                    errorText = "服务器已被删除"
                    loading = false
                    return
                }
                layout = prefs.layout(serverId: serverId, path: path, fallback: settings.layout)
                sort = settings.sort
                if files.isEmpty { await load(reset: true) }
            }
            .refreshable { await load(reset: true) }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("新名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("确定") { Task { await doRename() } }
            } message: {
                Text(renameTarget?.name ?? "")
            }
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) { newFolderName = "" }
                Button("创建") { Task { await doMkdir() } }
            }
            .alert("确定删除？", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ), presenting: deleteTarget) { file in
                Button("删除", role: .destructive) { Task { await doDelete(file) } }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: { file in
                Text(file.isDir
                     ? "「\(file.name)」及其中的全部内容都会被删除，此操作不可撤销。"
                     : "「\(file.name)」将被永久删除。")
            }
            .sheet(isPresented: $showOfflineSheet) { offlineSheet }
            .overlay {
                if let busy {
                    ProgressView(busy)
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if loading && files.isEmpty {
            List { LoadingRows() }.listStyle(.insetGrouped)
        } else if let errorText, files.isEmpty {
            ScrollView {
                EmptyState(title: "加载失败", detail: errorText, symbol: "exclamationmark.triangle") {
                    Button("重试") { Task { await load(reset: true) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if files.isEmpty {
            ScrollView {
                EmptyState(title: "空目录", detail: "这里还没有文件。", symbol: "folder") {
                    HStack(spacing: 10) {
                        Button("上传文件") { showUploadPicker = true }
                            .buttonStyle(.bordered)
                        Button("新建文件夹") { showNewFolder = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
        } else if layout == .grid {
            grid
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(visibleFiles) { file in
                Button {
                    open(file)
                } label: {
                    FileRowContent(file: file,
                                   token: server?.token ?? "",
                                   baseUrl: server?.url ?? "")
                }
                .buttonStyle(.plain)
                .contextMenu { menu(for: file) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = file
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        prefs.toggleFavorite(serverId: serverId, path: file.path)
                    } label: {
                        Label("收藏", systemImage: "star")
                    }
                    .tint(.yellow)
                }
            }
            if hasMore {
                Button {
                    Task { await loadMore() }
                } label: {
                    HStack {
                        Spacer()
                        Text(loading ? "加载中…" : "加载更多（\(files.count)/\(total)）")
                            .font(.footnote)
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
                ForEach(visibleFiles) { file in
                    Button {
                        open(file)
                    } label: {
                        VStack(spacing: 8) {
                            if file.isImage && !file.thumb.isEmpty {
                                RemoteThumb(url: OlHttp.join(server?.url ?? "", file.thumb),
                                            token: server?.token ?? "")
                                    .frame(width: 56, height: 56)
                            } else {
                                FileIcon(file: file, size: 44)
                                    .frame(height: 52)
                            }
                            Text(file.name)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.quaternary.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: file) }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 顶栏 / 底栏

    @ViewBuilder
    private var breadcrumbBar: some View {
        let parts = path.split(separator: "/").map(String.init)
        if !parts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button {
                        nav.pop()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)

                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        let accumulated = "/" + parts.prefix(index + 1).joined(separator: "/")
                        HStack(spacing: 4) {
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            if index == parts.count - 1 {
                                Text(part)
                                    .font(.caption.weight(.semibold))
                            } else {
                                Button(part) {
                                    nav.push(.browse(serverId: serverId, path: accumulated))
                                }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
            .background(.regularMaterial)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField("在本目录中筛选", text: $filter)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Button {
                withAnimation(.snappy) {
                    layout = layout == .list ? .grid : .list
                }
                prefs.setLayout(serverId: serverId, path: path, layout: layout)
            } label: {
                Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)

            Button {
                showUploadPicker = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 19))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("排序") {
                    Picker("排序字段", selection: $sort.field) {
                        ForEach(SortField.allCases) { field in
                            Label(field.label, systemImage: field.symbol).tag(field)
                        }
                    }
                    .pickerStyle(.inline)
                    Toggle("升序", isOn: $sort.ascending)
                    Toggle("文件夹优先", isOn: $sort.foldersFirst)
                }
                Section {
                    Toggle(isOn: $settings.showHidden) {
                        Label("显示隐藏文件", systemImage: "eye")
                    }
                }
                Section {
                    Button {
                        showNewFolder = true
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showOfflineSheet = true
                    } label: {
                        Label("离线下载链接", systemImage: "arrow.down.circle")
                    }
                    Button {
                        Task { await load(reset: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 长按菜单

    @ViewBuilder
    private func menu(for file: RemoteFile) -> some View {
        if file.isDir {
            Button {
                open(file)
            } label: {
                Label("打开", systemImage: "folder")
            }
        } else {
            if file.playable {
                Button {
                    nav.push(.play(serverId: serverId, path: file.path))
                } label: {
                    Label("播放", systemImage: "play.circle")
                }
            }
            Button {
                Task { await download(file) }
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            if file.isText || file.isImage || file.isPdf {
                Button {
                    nav.push(.preview(serverId: serverId, path: file.path))
                } label: {
                    Label("预览", systemImage: "eye")
                }
            }
        }

        Button {
            renameText = file.name
            renameTarget = file
        } label: {
            Label("重命名", systemImage: "pencil")
        }

        let fav = prefs.isFavorite(serverId: serverId, path: file.path)
        Button {
            prefs.toggleFavorite(serverId: serverId, path: file.path)
            ToastCenter.shared.show(fav ? "已取消收藏" : "已收藏")
        } label: {
            Label(fav ? "取消收藏" : "收藏", systemImage: fav ? "star.slash" : "star")
        }

        Button {
            UIPasteboard.general.string = file.path
            ToastCenter.shared.show("已复制路径")
        } label: {
            Label("复制路径", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            deleteTarget = file
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 动作

    private func open(_ file: RemoteFile) {
        if file.isDir {
            nav.push(.browse(serverId: serverId, path: file.path))
        } else if file.playable {
            nav.push(.play(serverId: serverId, path: file.path))
        } else if file.isText || file.isImage || file.isPdf {
            nav.push(.preview(serverId: serverId, path: file.path))
        } else {
            Task { await download(file) }
        }
    }

    private func download(_ file: RemoteFile) async {
        guard let server else { return }
        busy = "准备下载…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            let link = try await container.api.downloadLink(baseUrl: server.url, token: token, file: file)
            guard !link.isDir else {
                ToastCenter.shared.show("这是目录，请进入后逐个下载")
                return
            }
            var headers: [String: String] = [:]
            if OlHttp.sameHost(server.url, link.url) { headers["Authorization"] = token }
            downloads.enqueue(name: file.name,
                              remotePath: file.path,
                              serverName: server.displayName,
                              url: link.url,
                              size: link.size > 0 ? link.size : file.size,
                              headers: headers,
                              fallbackUrl: link.fallbackUrl)
            ToastCenter.shared.show("已加入下载队列")
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "获取下载地址失败")
        }
    }

    private func doRename() async {
        guard let server, let target = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renameTarget = nil
        guard !newName.isEmpty, newName != target.name else { return }
        do {
            let token = try await ensureToken(server)
            try await container.api.rename(baseUrl: server.url, token: token,
                                           path: target.path, newName: newName)
            ToastCenter.shared.show("已重命名")
            await load(reset: true)
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "重命名失败")
        }
    }

    private func doMkdir() async {
        guard let server else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        do {
            let token = try await ensureToken(server)
            try await container.api.mkdir(baseUrl: server.url, token: token, parent: path, name: name)
            ToastCenter.shared.show("已创建「\(name)」")
            await load(reset: true)
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "创建失败")
        }
    }

    private func doDelete(_ file: RemoteFile) async {
        guard let server else { return }
        deleteTarget = nil
        busy = "正在删除…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            try await container.api.remove(baseUrl: server.url, token: token,
                                           dir: PathUtil.parent(file.path), names: [file.name])
            ToastCenter.shared.show("已删除「\(file.name)」")
            await load(reset: true)
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "删除失败")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let server else { return }
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            var added = 0
            for url in urls {
                do {
                    try uploads.enqueue(fileURL: url, server: server, dir: path)
                    added += 1
                } catch {
                    ToastCenter.shared.show("「\(url.lastPathComponent)」上传失败：\(error.localizedDescription)")
                }
            }
            if added > 0 { ToastCenter.shared.show("已加入上传队列（\(added) 个）") }
        case .failure(let error):
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    private func ensureToken(_ server: ServerConfig) async throws -> String {
        try await servers.ensureToken(server.id, api: container.api).token
    }

    // MARK: - 加载

    private func load(reset: Bool) async {
        guard let server else {
            errorText = "服务器已被删除"
            loading = false
            return
        }
        if reset {
            page = 1
            loading = true
            errorText = nil
        }
        do {
            let token = try await ensureToken(server)
            let result = try await container.api.listPage(baseUrl: server.url,
                                                          token: token,
                                                          path: path,
                                                          page: page,
                                                          perPage: 300,
                                                          refresh: reset)
            if reset {
                files = result.files
            } else {
                let existing = Set(files.map(\.path))
                files.append(contentsOf: result.files.filter { !existing.contains($0.path) })
            }
            total = result.total
            hasMore = result.perPage > 0 && files.count < total
        } catch let error as ApiError {
            errorText = error.message
            if error.authRelated { ToastCenter.shared.show("登录已失效，请重新登录") }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func loadMore() async {
        guard hasMore, let server else { return }
        page += 1
        do {
            let token = try await ensureToken(server)
            let result = try await container.api.listPage(baseUrl: server.url, token: token,
                                                          path: path, page: page, perPage: 300)
            let existing = Set(files.map(\.path))
            files.append(contentsOf: result.files.filter { !existing.contains($0.path) })
            total = result.total
            hasMore = files.count < total
        } catch {
            page -= 1
            ToastCenter.shared.show("加载下一页失败")
        }
    }

    // MARK: - 离线下载

    private var offlineSheet: some View {
        NavigationStack {
            Form {
                Section("下载地址") {
                    TextField("每行一个链接", text: $offlineURL, axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("工具") {
                    Picker("下载工具", selection: $settings.offlineTool) {
                        Text("aria2").tag("aria2")
                        Text("qBittorrent").tag("qbit")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button("提交到服务器") { Task { await submitOffline() } }
                        .disabled(offlineURL.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("文件会下载到当前目录「\(path)」。需要服务端已配置 aria2 或 qBittorrent。")
                }
            }
            .navigationTitle("离线下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showOfflineSheet = false }
                }
            }
        }
    }

    private func submitOffline() async {
        guard let server else { return }
        let urls = offlineURL.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return }
        busy = "提交中…"
        defer { busy = nil }
        do {
            let token = try await ensureToken(server)
            try await container.api.addOfflineDownload(baseUrl: server.url, token: token,
                                                       path: path, urls: urls,
                                                       tool: settings.offlineTool)
            offlineURL = ""
            showOfflineSheet = false
            ToastCenter.shared.show("已提交 \(urls.count) 个链接")
        } catch {
            ToastCenter.shared.show((error as? ApiError)?.message ?? "提交失败")
        }
    }
}

// MARK: - 行内容

struct FileRowContent: View {

    let file: RemoteFile
    let token: String
    let baseUrl: String

    var body: some View {
        HStack(spacing: 12) {
            if file.isImage && !file.thumb.isEmpty {
                RemoteThumb(url: OlHttp.join(baseUrl, file.thumb), token: token)
            } else {
                FileIcon(file: file, size: 30)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    Text(file.isDir ? "文件夹" : Fmt.bytes(file.size))
                    if !file.modified.isEmpty {
                        Text("·")
                        Text(Fmt.relative(file.modified))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if file.isDir {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
