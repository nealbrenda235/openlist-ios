//
//  TasksScreen.swift
//  OpenList iOS
//
//  下载 / 上传任务。分段控件切换，行内滑动暂停、继续、删除。
//  预览用 QLPreviewController 封装（不用 iOS 17 的 quickLookPreview）。
//

import SwiftUI
import QuickLook

struct TasksScreen: View {

    enum Segment: String, CaseIterable, Identifiable {
        case download, upload
        var id: String { rawValue }
        var label: String { self == .download ? "下载" : "上传" }
    }

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var nav: NavModel
    @Environment(\.olAccent) private var accent

    @State private var segment: Segment = .download
    @State private var previewItem: QLItem?

    var body: some View {
        NavigationStack(path: $nav.path) {
            Group {
                if segment == .download {
                    downloadList
                } else {
                    uploadList
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("类型", selection: $segment) {
                    ForEach(Segment.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
            .navigationTitle("任务")
            .olGlassNavBar()
            .navigationDestination(for: Route.self) { route in
                RouteDestination(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if segment == .download {
                            Button { downloads.pauseAll() } label: {
                                Label("全部暂停", systemImage: "pause.circle")
                            }
                            Button { downloads.resumeAll() } label: {
                                Label("全部继续", systemImage: "play.circle")
                            }
                            Divider()
                            Button(role: .destructive) { downloads.removeFinished() } label: {
                                Label("清理已完成", systemImage: "trash")
                            }
                        } else {
                            Button { uploads.pauseAll() } label: {
                                Label("全部暂停", systemImage: "pause.circle")
                            }
                            Button { uploads.resumeAll() } label: {
                                Label("全部继续", systemImage: "play.circle")
                            }
                            Divider()
                            Button(role: .destructive) { uploads.removeFinished() } label: {
                                Label("清理已完成", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $previewItem) { item in
                QuickLookView(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - 下载

    @ViewBuilder
    private var downloadList: some View {
        if downloads.items.isEmpty {
            ScrollView {
                EmptyState(title: "没有下载任务",
                           detail: "在文件页长按文件即可下载，或进入目录后选择下载。",
                           symbol: "arrow.down.circle")
            }
        } else {
            List {
                Section {
                    ForEach(downloads.items) { item in
                        downloadRow(item)
                    }
                } footer: {
                    if downloads.activeCount > 0 {
                        Text("\(downloads.activeCount) 个进行中 · 总速度 \(Fmt.speed(downloads.totalSpeed))")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func downloadRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: item.progress)
                .tint(tint(for: item.state))

            HStack(spacing: 5) {
                Text(item.state.label)
                Text("·")
                Text("\(Fmt.bytes(item.downloadedBytes)) / \(Fmt.bytes(item.totalBytes))")
                Spacer()
                Text(item.serverName).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !item.error.isEmpty {
                Text(item.error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.state == .done, !item.localFile.isEmpty else { return }
            let url = DownloadManager.documentsDir.appendingPathComponent(item.localFile)
            if FileManager.default.fileExists(atPath: url.path) {
                previewItem = QLItem(url: url)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                // 用户在列表里删掉一条，期望的是「这个下载连同文件一起没了」，
                // 所以这里调 removeWithFile 而不是仅移除记录。
                downloads.removeWithFile(item.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
            if item.state == .running {
                Button { downloads.pause(item.id) } label: {
                    Label("暂停", systemImage: "pause")
                }
                .tint(.orange)
            } else if item.state == .paused || item.state == .failed {
                Button { downloads.resume(item.id) } label: {
                    Label("继续", systemImage: "play")
                }
                .tint(.green)
            }
        }
    }

    // MARK: - 上传

    @ViewBuilder
    private var uploadList: some View {
        if uploads.items.isEmpty {
            ScrollView {
                EmptyState(title: "没有上传任务",
                           detail: "在浏览页点右下角「+」按钮选择要上传的文件。",
                           symbol: "arrow.up.circle")
            }
        } else {
            List {
                Section {
                    ForEach(uploads.items) { item in
                        uploadRow(item)
                    }
                } footer: {
                    if uploads.activeCount > 0 {
                        Text("\(uploads.activeCount) 个上传中")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func uploadRow(_ item: UploadItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: item.progress)
                .tint(tint(for: item.state))

            HStack(spacing: 5) {
                Text(item.state.label)
                Text("·")
                Text("\(Fmt.bytes(item.uploaded)) / \(Fmt.bytes(item.size))")
                Spacer()
                Text(item.serverName).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !item.error.isEmpty {
                Text(item.error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                uploads.remove(item.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
            if item.state == .uploading {
                Button { uploads.pause(item.id) } label: {
                    Label("暂停", systemImage: "pause")
                }
                .tint(.orange)
            } else if item.state == .paused || item.state == .failed {
                Button { uploads.resume(item.id) } label: {
                    Label("继续", systemImage: "play")
                }
                .tint(.green)
            }
        }
    }

    private func tint(for state: DownloadState) -> Color {
        switch state {
        case .running: return .accentColor
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }

    private func tint(for state: UploadState) -> Color {
        switch state {
        case .uploading: return .accentColor
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}

// MARK: - QuickLook 封装（兼容 iOS 16）

struct QLItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct QuickLookView: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
