//
//  SettingsScreen.swift
//  OpenList iOS
//
//  设置：服务器、外观、播放、传输、存储、关于。
//

import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var nav: NavModel

    @State private var showAddServer = false

    var body: some View {
        NavigationStack(path: $nav.path) {
            Form {
                serverSection
                appearanceSection
                playbackSection
                transferSection
                storageSection
                aboutSection
            }
            .navigationTitle("设置")
            .olGlassNavBarLarge()
            .navigationDestination(for: Route.self) { route in
                RouteDestination(route: route)
            }
            .sheet(isPresented: $showAddServer) {
                EditServerScreen(server: nil)
            }
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        Section {
            ForEach(servers.servers) { server in
                Button {
                    nav.push(.editServer(serverId: server.id))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName).foregroundStyle(.primary)
                            Text(server.hostText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(server.isAdmin ? "管理员" : (server.username.isEmpty ? "未登录" : server.username))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                showAddServer = true
            } label: {
                Label("添加服务器", systemImage: "plus.circle")
            }
        } header: {
            Text("服务器")
        } footer: {
            if servers.servers.isEmpty {
                Text("还没有服务器。添加后才能浏览文件。")
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: $settings.themeMode) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Picker("强调色", selection: $settings.accent) {
                ForEach(AccentChoice.allCases) { accent in
                    Text(accent.label).tag(accent)
                }
            }
            Picker("列表密度", selection: $settings.density) {
                ForEach(ListDensity.allCases) { dense in
                    Text(dense.label).tag(dense)
                }
            }
            Button {
                nav.push(.appearance)
            } label: {
                Label("更多外观选项", systemImage: "paintpalette")
            }
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section {
            Toggle(isOn: $settings.backgroundPlayback) {
                Label("离开后继续播放音频", systemImage: "waveform")
            }
        } header: {
            Text("播放")
        } footer: {
            Text("开启后切到后台仍能听到声音，适合听音乐和播客。")
        }
    }

    // MARK: - 传输

    private var transferSection: some View {
        Section {
            Picker("下载并发", selection: $settings.downloadConcurrency) {
                ForEach(SettingsStore.concurrencyOptions, id: \.self) { value in
                    Text("\(value) 个").tag(value)
                }
            }
            Picker("上传并发", selection: $settings.uploadConcurrency) {
                ForEach(SettingsStore.concurrencyOptions, id: \.self) { value in
                    Text("\(value) 个").tag(value)
                }
            }
            Toggle(isOn: $settings.downloadWifiOnly) {
                Label("仅 Wi-Fi 下载", systemImage: "wifi")
            }
            Picker("离线下载工具", selection: $settings.offlineTool) {
                Text("aria2").tag("aria2")
                Text("qBittorrent").tag("qbit")
            }
        } header: {
            Text("传输")
        } footer: {
            Text("并发数越大越快，弱网下更容易失败。iOS 在省电模式下可能暂停后台下载，恢复后会自动续传。")
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            Button {
                let dir = DownloadManager.documentsDir
                let count = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
                ToastCenter.shared.show("已下载 \(count) 个文件")
            } label: {
                Label("统计下载文件", systemImage: "folder")
            }
            Button {
                downloads.removeFinished()
                uploads.removeFinished()
                ToastCenter.shared.show("已清理完成记录")
            } label: {
                Label("清理已完成任务", systemImage: "trash")
            }
        } header: {
            Text("存储")
        } footer: {
            Text("下载的文件保存在「文件」App → 我的 iPhone → OpenList 目录下。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            Button {
                nav.push(.about)
            } label: {
                Label("关于 OpenList", systemImage: "info.circle")
            }
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.shortVersion).foregroundStyle(.secondary)
            }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - 外观

struct AppearanceScreen: View {

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("主题") {
                Picker("外观", selection: $settings.themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("强调色") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 12) {
                    ForEach(AccentChoice.allCases) { accent in
                        Button {
                            settings.accent = accent
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if settings.accent == accent {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                Text(accent.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("列表") {
                Toggle(isOn: $settings.showHidden) {
                    Label("显示隐藏文件", systemImage: "eye")
                }
                Toggle(isOn: $settings.autoRefresh) {
                    Label("进入目录时刷新", systemImage: "arrow.clockwise")
                }
                Picker("默认视图", selection: $settings.layout) {
                    ForEach(ListLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                Picker("排序字段", selection: $settings.sort.field) {
                    ForEach(SortField.allCases) { field in
                        Text(field.label).tag(field)
                    }
                }
                Toggle("升序", isOn: $settings.sort.ascending)
                Toggle("文件夹优先", isOn: $settings.sort.foldersFirst)
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 关于

struct AboutScreen: View {

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("OpenList")
                        .font(.title2.weight(.semibold))
                    Text(Bundle.main.shortVersion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section("说明") {
                LabeledContent("接口", value: "OpenList 服务端 v4")
                LabeledContent("系统", value: "iOS 16 及以上")
                LabeledContent("界面", value: "SwiftUI 原生")
            }

            Section {
                Link(destination: URL(string: "https://github.com/OpenListTeam/OpenList")!) {
                    Label("OpenList 项目主页", systemImage: "link")
                }
            } footer: {
                Text("本客户端为个人自用，不修改服务端。所有数据都保存在你自己的 OpenList 实例上。")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
