//
//  SettingsScreen.swift
//  OpenList iOS
//
//  设置页（iOS 26 风格重构）。
//
//  ## 这一版修掉的「不生效」
//
//  - 之前有 9 个设置项存在，但只有 3 个真正被代码读取。
//    现在每一项都能对上实际行为：
//      主题/强调色 → RootView + olAccent
//      密度 → BrowseScreen 行高
//      布局 → FilePrefs 按目录记忆
//      隐藏文件 → BrowseScreen 过滤
//      自动刷新 → BrowseScreen 的 refresh 参数
//      下载并发 → DownloadManager.pump
//      仅 Wi-Fi → DownloadManager.networkAllowed
//      上传并发 → UploadManager.pump
//      后台播放 → PlayerScreen 前后台监听
//      离线工具 → BrowseScreen 提交离线下载
//  - 补上缺失的「下载线程数」入口。
//

import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var nav: NavModel
    @Environment(\.olAccent) private var accent

    @State private var showAddServer = false

    var body: some View {
        NavigationStack(path: $nav.path) {
            ScrollView {
                VStack(spacing: OlSpace.md) {
                    serverSection
                    appearanceSection
                    transferSection
                    storageSection
                    aboutSection
                }
                .padding(.horizontal, OlSpace.md)
                .padding(.top, OlSpace.xs)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("设置")
            .olGlassNavBarLarge()
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            .sheet(isPresented: $showAddServer) { EditServerScreen(server: nil) }
        }
    }

    // MARK: - 服务器

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "服务器", trailing: servers.servers.isEmpty ? nil : "\(servers.servers.count)")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(servers.servers.enumerated()), id: \.element.id) { index, server in
                        Button {
                            nav.push(.editServer(serverId: server.id))
                        } label: {
                            HStack(spacing: OlSpace.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(server.hostText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if server.isAdmin {
                                    Text("管理员")
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(accent.opacity(0.16), in: Capsule())
                                        .foregroundStyle(accent)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, OlSpace.md)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)

                        if index != servers.servers.count - 1 { Divider().padding(.leading, OlSpace.md) }
                    }

                    if !servers.servers.isEmpty { Divider() }

                    Button {
                        showAddServer = true
                    } label: {
                        HStack(spacing: OlSpace.xs) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(accent)
                            Text("添加服务器")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
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

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "外观")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    // 主题：三选一胶囊
                    VStack(alignment: .leading, spacing: OlSpace.xs) {
                        Text("主题").font(.caption).foregroundStyle(.secondary)
                        CapsuleSegmented(options: ThemeMode.allCases, selection: $settings.themeMode) { mode in
                            Text(mode.label)
                        }
                    }
                    .padding(OlSpace.md)

                    Divider().padding(.horizontal, OlSpace.md)

                    // 强调色：圆形色板
                    VStack(alignment: .leading, spacing: OlSpace.xs) {
                        Text("强调色").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: OlSpace.sm) {
                            ForEach(AccentChoice.allCases) { choice in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        settings.accent = choice
                                    }
                                } label: {
                                    Circle()
                                        .fill(choice.color)
                                        .frame(width: 32, height: 32)
                                        .overlay {
                                            if settings.accent == choice {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .overlay {
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                                        }
                                }
                                .buttonStyle(.pressable)
                            }
                            Spacer()
                        }
                    }
                    .padding(OlSpace.md)

                    Divider().padding(.horizontal, OlSpace.md)

                    row("列表密度") {
                        Picker("", selection: $settings.density) {
                            ForEach(ListDensity.allCases) { d in
                                Text(d.label).tag(d)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }

                    Divider().padding(.leading, OlSpace.md)

                    row("默认视图") {
                        Picker("", selection: $settings.layout) {
                            ForEach(ListLayout.allCases) { l in
                                Text(l.label).tag(l)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }

                    Divider().padding(.leading, OlSpace.md)

                    row("显示隐藏文件") {
                        Toggle("", isOn: $settings.showHidden).labelsHidden()
                    }

                    Divider().padding(.leading, OlSpace.md)

                    row("进入目录时刷新") {
                        Toggle("", isOn: $settings.autoRefresh).labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - 传输

    private var transferSection: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "传输")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    row("同时下载") {
                        Picker("", selection: $settings.downloadConcurrency) {
                            ForEach(SettingsStore.concurrencyOptions, id: \.self) { v in
                                Text("\(v)").tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    Divider().padding(.leading, OlSpace.md)

                    // 之前这个设置完全没有 UI 入口，只有存值
                    row("下载线程数") {
                        Picker("", selection: $settings.downloadThreads) {
                            ForEach(SettingsStore.threadOptions, id: \.self) { v in
                                Text("\(v)").tag(v)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Divider().padding(.leading, OlSpace.md)

                    row("同时上传") {
                        Picker("", selection: $settings.uploadConcurrency) {
                            ForEach(SettingsStore.concurrencyOptions, id: \.self) { v in
                                Text("\(v)").tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    Divider().padding(.leading, OlSpace.md)

                    row("仅 Wi-Fi 下载") {
                        Toggle("", isOn: $settings.downloadWifiOnly).labelsHidden()
                    }

                    Divider().padding(.leading, OlSpace.md)

                    row("后台继续播放") {
                        Toggle("", isOn: $settings.backgroundPlayback).labelsHidden()
                    }

                    Divider().padding(.leading, OlSpace.md)

                    row("离线下载工具") {
                        Picker("", selection: $settings.offlineTool) {
                            Text("aria2").tag("aria2")
                            Text("qBit").tag("qbit")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }
                }
            }

            Text("并发数越大越快，弱网下更容易失败；「仅 Wi-Fi」开启后移动网络会暂停全部下载。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, OlSpace.xs)
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "存储")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    row("已下载文件") {
                        Text("\(fileCount) 个")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider().padding(.leading, OlSpace.md)

                    Button {
                        downloads.removeFinished()
                        uploads.removeFinished()
                        ToastCenter.shared.show("已清理完成的任务与文件")
                    } label: {
                        HStack {
                            Text("清理已完成（含文件）")
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

            Text("下载的文件保存在「文件」App → 我的 iPhone → OpenList。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, OlSpace.xs)
        }
    }

    private var fileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: DownloadManager.documentsDir.path).count) ?? 0
    }

    // MARK: - 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: OlSpace.xs) {
            SectionHeader(title: "关于")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    Button {
                        nav.push(.about)
                    } label: {
                        HStack {
                            Text("关于 OpenList").font(.subheadline).foregroundStyle(.primary)
                            Spacer()
                            Text(Bundle.main.shortVersion).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
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

    // MARK: - 行容器

    private func row<Trailing: View>(_ title: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            trailing()
        }
        .padding(.horizontal, OlSpace.md)
        .padding(.vertical, 10)
    }
}

// MARK: - 版本号

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - 外观（保留给 Route.appearance，已合并到主设置页）

struct AppearanceScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.olAccent) private var accent

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
                    ForEach(AccentChoice.allCases) { choice in
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                settings.accent = choice
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if settings.accent == choice {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                Text(choice.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 关于

struct AboutScreen: View {

    @Environment(\.olAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(spacing: OlSpace.md) {
                VStack(spacing: OlSpace.sm) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(accent)
                    Text("OpenList")
                        .font(.title2.weight(.semibold))
                    Text(Bundle.main.shortVersion)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, OlSpace.xl)

                GlassCard {
                    VStack(spacing: 10) {
                        infoRow("接口", "OpenList 服务端 v4")
                        Divider()
                        infoRow("系统", "iOS 16 及以上")
                        Divider()
                        infoRow("界面", "SwiftUI 原生")
                    }
                }

                GlassCard {
                    Link(destination: URL(string: "https://github.com/OpenListTeam/OpenList")!) {
                        HStack {
                            Label("OpenList 项目主页", systemImage: "link")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, OlSpace.md)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline)
        }
    }
}
