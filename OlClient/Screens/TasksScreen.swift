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
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("任务")
            .olGlassNavBarLarge()
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            .toolbar { toolbar }
            .sheet(item: $previewItem) { item in
                QuickLookView(url: item.url).ignoresSafeArea()
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

    private func downloadCard(_ item: DownloadItem) -> some View {
        GlassCard(padding: OlSpace.md) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: OlSpace.xs) {
                    ProgressRing(progress: item.progress,
                                 tint: ringColor(item.state),
                                 symbol: item.state == .done ? "checkmark" : nil)
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(item.state.label) · \(Fmt.bytes(item.downloadedBytes))/\(Fmt.bytes(item.totalBytes))")
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
                    if item.state == .running {
                        miniButton("暂停", "pause.fill") { downloads.pause(item.id) }
                    } else if item.state == .paused || item.state == .failed {
                        miniButton("继续", "play.fill") { downloads.resume(item.id) }
                    }
                    if item.state == .done, !item.localFile.isEmpty {
                        miniButton("打开", "eye") {
                            let url = DownloadManager.documentsDir.appendingPathComponent(item.localFile)
                            if FileManager.default.fileExists(atPath: url.path) {
                                previewItem = QLItem(url: url)
                            }
                        }
                    }
                    miniButton("删除", "trash", role: .destructive) {
                        downloads.removeWithFile(item.id)
                    }
                    Spacer()
                    Text(item.serverName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            if item.state == .done {
                Button {
                    UIPasteboard.general.string = DownloadManager.documentsDir
                        .appendingPathComponent(item.localFile).path
                    ToastCenter.shared.show("已复制文件路径")
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    downloads.deleteFile(item.id)
                    ToastCenter.shared.show("已删除本地文件")
                } label: {
                    Label("只删文件，保留记录", systemImage: "trash.slash")
                }
            }
        }
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

struct ProgressRing: View {

    let progress: Double
    let tint: Color
    var symbol: String? = nil

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                Text("\(Int(progress * 100))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

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
