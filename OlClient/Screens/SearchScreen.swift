//
//  SearchScreen.swift
//  OpenList iOS
//
//  全局搜索：选服务器 → 关键词 → 结果列表。
//  OpenList 的搜索依赖服务端索引（未建索引时返回空），底部有对应提示。
//

import SwiftUI

struct SearchScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nav: NavModel

    @State private var serverId: String = ""
    @State private var keyword = ""
    @State private var scope = 0
    @State private var results: [RemoteFile] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var submitted = false

    var body: some View {
        NavigationStack(path: $nav.path) {
            List {
                Section {
                    Picker("服务器", selection: $serverId) {
                        ForEach(servers.servers) { server in
                            Text(server.displayName).tag(server.id)
                        }
                    }
                    Picker("范围", selection: $scope) {
                        Text("全部").tag(0)
                        Text("仅文件夹").tag(1)
                        Text("仅文件").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                if !submitted {
                    historySection
                    Section {
                        Text("输入关键词后按键盘的「搜索」提交。点结果可进入所在目录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if searching {
                    Section { LoadingRows(count: 6) }
                } else if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } else if results.isEmpty {
                    Section {
                        EmptyStateRow(title: "没有结果",
                                      detail: "换个关键词试试。若服务端未建立搜索索引，这里会一直为空。",
                                      symbol: "magnifyingglass")
                    }
                } else {
                    Section("结果 · \(results.count)") {
                        ForEach(results) { file in
                            Button {
                                open(file)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 10) {
                                        FileIcon(file: file, size: 24)
                                        Text(file.name)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if file.isDir {
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Text(PathUtil.parent(file.path))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("搜索")
            .olGlassNavBar()
            .searchable(text: $keyword, prompt: "文件名关键词")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if submitted {
                        Button {
                            submitted = false
                            results = []
                            keyword = ""
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteDestination(route: route)
            }
            .task {
                if serverId.isEmpty { serverId = servers.servers.first?.id ?? "" }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !settings.searchHistory.isEmpty {
            Section("最近搜索") {
                ForEach(settings.searchHistory, id: \.self) { item in
                    Button {
                        keyword = item
                        Task { await runSearch() }
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(item).foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            settings.removeSearchHistory(item)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                Button("清空历史", role: .destructive) {
                    settings.clearSearchHistory()
                }
            }
        }
    }

    private func runSearch() async {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, let server = servers.get(serverId) else { return }
        searching = true
        submitted = true
        errorText = nil
        settings.addSearchHistory(key)
        do {
            let token = try await servers.ensureToken(serverId, api: container.api).token
            let page = try await container.api.searchPage(baseUrl: server.url,
                                                          token: token,
                                                          keyword: key,
                                                          scope: scope,
                                                          page: 1,
                                                          perPage: 100)
            results = page.files
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
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
