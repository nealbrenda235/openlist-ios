//
//  SearchScreen.swift
//  OpenList iOS
//
//  搜索页（重排）。
//
//  v3 的问题：`.searchable` 挂在 List 上，系统把搜索框塞进导航栏下方，
//  和下面第一张卡片之间没有任何间距，看起来「挤在一起」。
//
//  现在改成：搜索框自己做（不走 .searchable），
//  整页用 ScrollView + 统一的 OlSpace 节奏排版，
//  搜索框 → 服务器选择 → 历史 / 结果，各段之间都有明确的纵向留白。
//

import SwiftUI

struct SearchScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nav: NavModel
    @Environment(\.olAccent) private var accent

    @State private var serverId: String = ""
    @State private var keyword = ""
    @State private var scope = 0
    @State private var results: [RemoteFile] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var submitted = false
    @FocusState private var focused: Bool

    private let scopes = ["全部", "仅文件夹", "仅文件"]

    var body: some View {
        NavigationStack(path: $nav.path) {
            ScrollView {
                VStack(spacing: OlSpace.md) {
                    searchField
                    serverPicker

                    if !submitted {
                        historySection
                        tipCard
                    } else if searching {
                        loadingCard
                    } else if let errorText {
                        errorCard(errorText)
                    } else if results.isEmpty {
                        emptyCard
                    } else {
                        resultSection
                    }
                }
                .padding(.horizontal, OlSpace.md)
                .padding(.top, OlSpace.sm)
            }
            .olDockSafeArea()
            .background(Color.clear)
            .navigationTitle("搜索")
            .olGlassNavBarLarge()
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if submitted {
                        Button {
                            reset()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                    }
                }
            }
            .task {
                if serverId.isEmpty { serverId = servers.servers.first?.id ?? "" }
            }
        }
    }

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(focused ? accent : .secondary)

            TextField("文件名关键词", text: $keyword)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await runSearch() } }

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if !keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    Task { await runSearch() }
                } label: {
                    Text("搜索")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: OlRadius.inner + 4, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.07 : 0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: OlRadius.inner + 4, style: .continuous)
                        .strokeBorder(focused ? accent.opacity(0.45) : Color.clear, lineWidth: 1.2)
                }
        }
        .animation(.easeInOut(duration: 0.18), value: focused)
    }

    // MARK: - 服务器 + 范围

    private var serverPicker: some View {
        GlassCard(padding: OlSpace.sm) {
            VStack(spacing: OlSpace.xs) {
                HStack {
                    Text("服务器")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $serverId) {
                        ForEach(servers.servers) { server in
                            Text(server.displayName).tag(server.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Divider()

                CapsuleSegmented(options: Array(scopes.indices), selection: $scope) { index in
                    Text(scopes[index])
                }
            }
        }
    }

    // MARK: - 历史

    @ViewBuilder
    private var historySection: some View {
        if !settings.searchHistory.isEmpty {
            VStack(alignment: .leading, spacing: OlSpace.xs) {
                SectionHeader(title: "最近搜索",
                              trailing: nil)
                GlassCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(settings.searchHistory.enumerated()), id: \.element) { index, item in
                            Button {
                                keyword = item
                                Task { await runSearch() }
                            } label: {
                                HStack(spacing: OlSpace.sm) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, OlSpace.md)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                            .contextMenu {
                                Button(role: .destructive) {
                                    settings.removeSearchHistory(item)
                                } label: {
                                    Label("从历史中删除", systemImage: "trash")
                                }
                            }

                            if index != settings.searchHistory.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }

                        Divider()

                        Button {
                            settings.clearSearchHistory()
                        } label: {
                            HStack {
                                Text("清空历史")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                            .padding(.horizontal, OlSpace.md)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    // MARK: - 提示 / 状态

    private var tipCard: some View {
        HStack(alignment: .top, spacing: OlSpace.xs) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("输入关键词后按「搜索」提交。点结果可进入所在目录。若服务端未建立索引，结果可能为空。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(OlSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: OlRadius.inner, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var loadingCard: some View {
        GlassCard {
            HStack(spacing: OlSpace.sm) {
                ProgressView().controlSize(.small)
                Text("正在搜索…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: OlSpace.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(OlSpace.sm)
        .background {
            RoundedRectangle(cornerRadius: OlRadius.inner, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        }
    }

    private var emptyCard: some View {
        EmptyState(title: "没有结果",
                   detail: "换个关键词试试，或者检查服务端是否已建立搜索索引。",
                   symbol: "magnifyingglass")
            .padding(.top, OlSpace.lg)
    }

    // MARK: - 结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "结果", trailing: "\(results.count)")
            VStack(spacing: OlSpace.xs) {
                ForEach(results) { file in
                    SearchResultCard(file: file) { open(file) }
                }
            }
        }
    }

    // MARK: - 动作

    private func reset() {
        submitted = false
        results = []
        keyword = ""
        errorText = nil
    }

    private func runSearch() async {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        guard let server = servers.get(serverId) else {
            errorText = "请先添加服务器"
            return
        }
        focused = false
        searching = true
        submitted = true
        errorText = nil
        settings.addSearchHistory(key)
        Diagnostics.shared.info("搜索：\(key) @ \(server.displayName)")

        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            let page = try await container.api.searchPage(baseUrl: server.url,
                                                          token: token,
                                                          keyword: key,
                                                          scope: scope,
                                                          page: 1,
                                                          perPage: 100)
            results = page.files
            Diagnostics.shared.info("搜索完成：\(results.count) 条")
        } catch {
            let reason = (error as? ApiError)?.message ?? error.localizedDescription
            Diagnostics.shared.error("搜索失败：\(reason)")
            errorText = reason
            results = []
        }
        searching = false
    }

    private func open(_ file: RemoteFile) {
        if file.isDir {
            nav.push(.browse(serverId: serverId, path: file.path))
        } else if file.playable {
            nav.push(.play(serverId: serverId, path: file.path))
        } else {
            nav.push(.browse(serverId: serverId, path: PathUtil.parent(file.path)))
        }
    }
}

// MARK: - 搜索结果卡片

private struct SearchResultCard: View {

    @Environment(\.olAccent) private var accent
    let file: RemoteFile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCard(padding: OlSpace.sm) {
                HStack(spacing: OlSpace.sm) {
                    FileIcon(file: file, size: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                        Text(PathUtil.parent(file.path))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.pressable)
    }
}
