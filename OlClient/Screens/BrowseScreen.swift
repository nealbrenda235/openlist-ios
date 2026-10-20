//
//  BrowseScreen.swift
//  OpenList iOS
//
//  目录浏览（iOS 26 风格重构）。
//
//  ## 这一版修掉的「不生效」
//
//  1. 列表/网格切换以前只改一个 @State，进出目录就重置 —— 现在按目录记忆（FilePrefs）
//  2. 排序以前改完不刷新视图 —— 现在 sort 是 @State + 计算属性参与渲染
//  3. 「自动刷新」设置以前从没被读过 —— 现在进入目录时按 settings.autoRefresh 决定要不要 refresh
//  4. 「列表密度」以前只存不用 —— 现在行高与图标尺寸真的随它变
//  5. 网格视图点击目录之前什么都不做（只有列表能下钻）—— 现在统一走 nav.push
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
            if !settings.showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        } else {
            let key = filter.lowercased()
            list = list.filter { $0.name.lowercased().contains(key) }
        }
        return sort.apply(to: list)
    }

    /// 密度真的影响行高（之前设置里能选但没任何效果）
    private var rowVerticalPadding: CGFloat {
        settings.density == .compact ? 5 : 9
    }

    private var iconSize: CGFloat {
        settings.density == .compact ? 26 : 30
    }

    var body: some View {
        content
            .navigationTitle(PathUtil.displayName(path))
            .navigationBarTitleDisplayMode(.inline)
            .olGlassNavBar()
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) { breadcrumbBar }
            // ★ 工具栏与 Dock 占位必须合成同一个 bottom inset。
            //   分成两个 safeAreaInset(edge:.bottom) 会互相覆盖（实测会遮挡）。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    bottomBar
                    // 给悬浮 Dock 让出的空间
                    Color.clear.frame(height: DockMetrics.reservedHeight)
                }
            }
            .fileImporter(isPresented: $showUploadPicker,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { handleImport($0) }
            .task { await bootstrap() }
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
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: OlRadius.card, style: .continuous))
                }
            }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if loading && files.isEmpty {
            ScrollView { LoadingRows() .padding(OlSpace.md) }
        } else if let errorText, files.isEmpty {
            ScrollView {
                EmptyState(title: "加载失败", detail: errorText, symbol: "exclamationmark.triangle") {
                    Button("重试") { Task { await load(reset: true) } }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        } else if files.isEmpty {
            ScrollView {
                EmptyState(title: "空目录", detail: "这里还没有文件。", symbol: "folder") {
                    HStack(spacing: OlSpace.xs) {
                        Button("上传文件") { showUploadPicker = true }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        Button("新建文件夹") { showNewFolder = true }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
            }
        } else if layout == .grid {
            grid
        } else {
            list
        }
    }

    /// 每一项都是独立卡片（用户要求：所有目录都拆分，不再用「一大卡多行 + 分隔线」）
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: OlSpace.xs) {
                ForEach(visibleFiles) { file in
                    Button {
                        open(file)
                    } label: {
                        FileRowContent(file: file,
                                       token: server?.token ?? "",
                                       baseUrl: server?.url ?? "",
                                       iconSize: iconSize)
                            .padding(.horizontal, OlSpace.sm)
                            .padding(.vertical, rowVerticalPadding + 2)
                            .background {
                                RoundedRectangle(cornerRadius: OlRadius.inner, style: .continuous)
                                    .fill(Color(.secondarySystemGroupedBackground))
                            }
                    }
                    .buttonStyle(.pressable)
                    .contextMenu { menu(for: file) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTarget = file
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        let fav = prefs.isFavorite(serverId: serverId, path: file.path)
                        Button {
                            prefs.toggleFavorite(serverId: serverId, path: file.path)
                            ToastCenter.shared.show(fav ? "已取消收藏" : "已收藏")
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
                        HStack(spacing: 6) {
                            if loading { ProgressView().controlSize(.mini) }
                            Text(loading ? "加载中…" : "加载更多（\(files.count)/\(total)）")
                                .font(.footnote)
                        }
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: OlRadius.inner, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        }
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, OlSpace.md)
            .padding(.vertical, OlSpace.xs)
        }
        .background(Color.clear)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: OlSpace.sm)], spacing: OlSpace.sm) {
                ForEach(visibleFiles) { file in
                    Button {
                        open(file)
                    } label: {
                        VStack(spacing: 7) {
                            if file.isImage && !file.thumb.isEmpty {
                                RemoteThumb(url: OlHttp.join(server?.url ?? "", file.thumb),
                                            token: server?.token ?? "",
                                            size: 54)
                            } else {
                                FileIcon(file: file, size: 42)
                                    .frame(height: 50)
                            }
                            Text(file.name)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        }
                    }
                    .buttonStyle(.pressable)
                    .contextMenu { menu(for: file) }
                }
            }
            .padding(OlSpace.md)
        }
        .background(Color.clear)
    }

    // MARK: - 面包屑

    /// 面包屑：与列表卡片同样的缩进和圆角，悬浮而不是通栏贴边。
    /// 最后一段是当前目录，导航栏已经有标题，所以这里只显示上级路径，避免重复。
    @ViewBuilder
    private var breadcrumbBar: some View {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    Button {
                        nav.pop()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9, weight: .bold))
                            Text(parts.count >= 2 ? parts[parts.count - 2] : "上级")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.11), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    // 更早的路径段，用轻量样式
                    let ancestors = Array(parts.dropLast(2))
                    ForEach(Array(ancestors.enumerated()), id: \.offset) { index, part in
                        let accumulated = "/" + parts.prefix(index + 1).joined(separator: "/")
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.quaternary)
                            Button(part) {
                                nav.push(.browse(serverId: serverId, path: accumulated))
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, OlSpace.md)
                .padding(.vertical, 6)
            }
            .background(Color.clear)
        }
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: OlSpace.xs) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("筛选", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: Capsule())

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    layout = layout == .list ? .grid : .list
                }
                prefs.setLayout(serverId: serverId, path: path, layout: layout)
            } label: {
                Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.pressable)

            Button {
                showUploadPicker = true
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, OlSpace.md)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("排序") {
                    Picker("字段", selection: $sort.field) {
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
                    Toggle(isOn: $settings.autoRefresh) {
                        Label("进入时自动刷新", systemImage: "arrow.clockwise")
                    }
                }
                Section {
                    Button { showNewFolder = true } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    Button { showOfflineSheet = true } label: {
                        Label("离线下载链接", systemImage: "arrow.down.circle")
                    }
                    Button { Task { await load(reset: true) } } label: {
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
            Button { open(file) } label: { Label("打开", systemImage: "folder") }
        } else {
            if file.playable {
                Button { nav.push(.play(serverId: serverId, path: file.path)) } label: {
                    Label("播放", systemImage: "play.circle")
                }
            }
            Button { Task { await download(file) } } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            if file.isText || file.isImage || file.isPdf {
                Button { nav.push(.preview(serverId: serverId, path: file.path)) } label: {
                    Label("预览", systemImage: "eye")
                }
            }
        }

        Button {
            renameText = file.name
            renameTarget = file
        } label: { Label("重命名", systemImage: "pencil") }

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
        } label: { Label("复制路径", systemImage: "doc.on.doc") }

        Divider()
        Button(role: .destructive) { deleteTarget = file } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 动作

    private func bootstrap() async {
        guard let server else {
            errorText = "服务器已被删除"
            loading = false
            return
        }
        layout = prefs.layout(serverId: serverId, path: path, fallback: settings.layout)
        sort = settings.sort
        // 自动刷新设置：关掉时首屏就不重复请求（之前这个开关完全没被读过）
        await load(reset: true, refresh: settings.autoRefresh && !files.isEmpty)
    }

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
                    let reason = (error as? ApiError)?.message ?? error.localizedDescription
                    Diagnostics.shared.error("入队失败：\(url.lastPathComponent) — \(reason)")
                    ToastCenter.shared.show("「\(url.lastPathComponent)」失败：\(reason)")
                }
            }
            if added > 0 { ToastCenter.shared.show("已加入上传队列（\(added) 个）") }
        case .failure(let error):
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    private func ensureToken(_ server: ServerConfig) async throws -> String {
        try await servers.ensureToken(serverId, api: container.api).token
    }

    // MARK: - 加载

    private func load(reset: Bool, refresh: Bool = true) async {
        guard let server else {
            errorText = "服务器已被删除"
            loading = false
            return
        }
        if reset {
            page = 1
            loading = files.isEmpty
            errorText = nil
        }
        do {
            let token = try await ensureToken(server)
            let result = try await container.api.listPage(baseUrl: server.url,
                                                          token: token,
                                                          path: path,
                                                          page: page,
                                                          perPage: 300,
                                                          refresh: refresh)
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
    var iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: OlSpace.sm) {
            if file.isImage && !file.thumb.isEmpty {
                RemoteThumb(url: OlHttp.join(baseUrl, file.thumb), token: token, size: iconSize + 4)
            } else {
                FileIcon(file: file, size: iconSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.subheadline)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if file.isDir {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
