//
//  TasksScreen.swift
//  OpenList iOS
//
//  任务页（iOS 26 风格）。胶囊分段 + 玻璃卡片 + 进度环。
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
    @State private var shareSheetItem: ShareSheetItem?

    var body: some View {
        NavigationStack(path: $nav.path) {
            ScrollView {
                VStack(spacing: OlSpace.md) {
                    CapsuleSegmented(options: Segment.allCases, selection: $segment) { item in
                        Text(item.label)
                    }
                    .padding(.horizontal, OlSpace.md)
                    .padding(.top, OlSpace.xs)

                    if segment == .download {
                        downloadContent
                    } else {
                        uploadContent
                    }

                    Color.clear.frame(height: OlSpace.lg)
                }
            }
            .olDockSafeArea()
            .background(Color.clear)
            .navigationTitle("任务")
            .olGlassNavBarLarge()
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            .toolbar { toolbar }
            .sheet(item: $previewItem) { item in
                QuickLookView(url: item.url).ignoresSafeArea()
            }
            .sheet(item: $shareSheetItem) { item in
                ShareSheet(items: [item.url])
                    .presentationDetents([.medium, .large])
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
                        Label("清理已完成（含文件）", systemImage: "trash")
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

    // MARK: - 下载

    @ViewBuilder
    private var downloadContent: some View {
        if downloads.items.isEmpty {
            EmptyState(title: "没有下载任务",
                       detail: "在文件页长按文件即可下载。",
                       symbol: "arrow.down.circle")
                .padding(.top, 40)
        } else {
            VStack(spacing: OlSpace.xs) {
                if downloads.activeCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(downloads.activeCount) 个进行中")
                        Text("·")
                        Text(Fmt.speed(downloads.totalSpeed))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, OlSpace.lg)
                }

                ForEach(downloads.items) { item in
                    downloadCard(item)
                }
            }
            .padding(.horizontal, OlSpace.md)
        }
    }

    /// 布局按用户要求调整：左侧进度环 + 文件名，右侧「打开」，删除改由长按 / 左滑触发。
    private func downloadCard(_ item: DownloadItem) -> some View {
        GlassCard(padding: OlSpace.sm) {
            HStack(spacing: OlSpace.sm) {
                ProgressRing(progress: item.state == .done ? 1 : item.progress,
                             tint: ringColor(item.state),
                             symbol: item.state == .done ? "checkmark" : nil)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(item.state.label) · \(Fmt.bytes(item.downloadedBytes))/\(Fmt.bytes(item.totalBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !item.error.isEmpty {
                        Text(item.error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: OlSpace.xs)

                // 右侧操作区
                if item.state == .done, !item.localFile.isEmpty {
                    Button {
                        openDownload(item)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("打开")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(accent)
                    }
                    .buttonStyle(.pressable)
                } else if item.state == .running {
                    Button {
                        downloads.pause(item.id)
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.pressable)
                } else if item.state == .paused || item.state == .failed {
                    Button {
                        downloads.resume(item.id)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(accent.opacity(0.14), in: Circle())
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .done { openDownload(item) }
        }
        .contextMenu {
            if item.state == .done {
                Button {
                    openDownload(item)
                } label: {
                    Label("打开", systemImage: "eye")
                }
                Button {
                    shareDownload(item)
                } label: {
                    Label("分享 / 用其它 App 打开", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = localURL(item)?.path ?? ""
                    ToastCenter.shared.show("已复制文件路径")
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) {
                    downloads.deleteFile(item.id)
                    ToastCenter.shared.show("已删除本地文件，记录保留")
                } label: {
                    Label("只删文件，保留记录", systemImage: "trash.slash")
                }
            } else if item.state == .running {
                Button {
                    downloads.pause(item.id)
                } label: {
                    Label("暂停", systemImage: "pause")
                }
            } else if item.state == .paused || item.state == .failed {
                Button {
                    downloads.resume(item.id)
                } label: {
                    Label("继续", systemImage: "play")
                }
            }
            Divider()
            Button(role: .destructive) {
                downloads.removeWithFile(item.id)
            } label: {
                Label("删除记录和文件", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
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

    // MARK: 下载文件操作

    private func localURL(_ item: DownloadItem) -> URL? {
        guard !item.localFile.isEmpty else { return nil }
        let url = DownloadManager.documentsDir.appendingPathComponent(item.localFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 系统不认识 .ipa/.zip/.apk 这类文件，QuickLook 会是空白页，
    /// 所以这些类型直接走分享面板（用户要的是「能操作」而不是「能预览」）。
    private func openDownload(_ item: DownloadItem) {
        guard let url = localURL(item) else {
            ToastCenter.shared.show("文件已不存在")
            return
        }
        if Self.previewableExtensions.contains(url.pathExtension.lowercased()) {
            previewItem = QLItem(url: url)
        } else {
            shareDownload(item)
        }
    }

    private static let previewableExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp",
        "pdf", "txt", "md", "json", "xml", "csv", "log",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "flac",
    ]

    private func shareDownload(_ item: DownloadItem) {
        guard let url = localURL(item) else { return }
        shareSheetItem = ShareSheetItem(url: url)
    }

    // MARK: - 上传

    @ViewBuilder
    private var uploadContent: some View {
        if uploads.items.isEmpty {
            EmptyState(title: "没有上传任务",
                       detail: "在浏览页点右下角「↑」选择文件上传。",
                       symbol: "arrow.up.circle")
                .padding(.top, 40)
        } else {
            VStack(spacing: OlSpace.xs) {
                ForEach(uploads.items) { item in
                    uploadCard(item)
                }
            }
            .padding(.horizontal, OlSpace.md)
        }
    }

    private func uploadCard(_ item: UploadItem) -> some View {
        GlassCard(padding: OlSpace.md) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: OlSpace.xs) {
                    ProgressRing(progress: item.progress,
                                 tint: item.state == .done ? .green : (item.state == .failed ? .red : accent),
                                 symbol: item.state == .done ? "checkmark" : nil)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(item.state.label) · \(Fmt.bytes(item.uploaded))/\(Fmt.bytes(item.size))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                if !item.error.isEmpty {
                    Text(item.error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                HStack(spacing: OlSpace.xs) {
                    if item.state == .uploading {
                        miniButton("暂停", "pause.fill") { uploads.pause(item.id) }
                    } else if item.state == .paused || item.state == .failed {
                        miniButton("继续", "play.fill") { uploads.resume(item.id) }
                    }
                    miniButton("删除", "trash", role: .destructive) { uploads.remove(item.id) }
                    Spacer()
                    Text(item.serverName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - 小组件

    private func miniButton(_ title: String, _ symbol: String,
                            role: ButtonRole? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.pressable)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }

    private func ringColor(_ state: DownloadState) -> Color {
        switch state {
        case .running: return accent
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}

// MARK: - 进度环

// MARK: - QuickLook

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
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
