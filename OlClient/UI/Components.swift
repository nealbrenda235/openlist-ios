//
//  Components.swift
//  OpenList iOS
//
//  共用视图组件。全部基于系统控件与 SF Symbols，颜色取语义色，
//  自动适配深浅色与动态字体。最低支持 iOS 16，不使用 iOS 17 才有的 API。
//

import SwiftUI

// MARK: - 文件图标

struct FileIcon: View {

    @Environment(\.olAccent) private var accent

    let file: RemoteFile
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.82, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
    }

    private var symbol: String {
        if file.isDir { return "folder.fill" }
        switch file.ext {
        case "mp4", "mkv", "webm", "mov", "avi", "ts", "m4v", "flv":
            return "film.fill"
        case "mp3", "flac", "wav", "aac", "m4a", "ogg", "opus":
            return "music.note"
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif":
            return "photo.fill"
        case "pdf":
            return "doc.richtext.fill"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "iso":
            return "archivebox.fill"
        case "txt", "md", "log", "json", "xml", "yml", "yaml", "ini", "csv":
            return "doc.text.fill"
        case "kt", "java", "py", "go", "rs", "c", "cpp", "js", "ts", "swift":
            return "chevron.left.forwardslash.chevron.right"
        case "apk", "ipa", "exe", "dmg":
            return "shippingbox.fill"
        default:
            return "doc.fill"
        }
    }

    private var tint: Color {
        if file.isDir { return accent }
        switch file.ext {
        case "mp4", "mkv", "webm", "mov", "avi", "ts", "m4v", "flv": return .red
        case "mp3", "flac", "wav", "aac", "m4a", "ogg", "opus": return .pink
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif": return .green
        case "pdf": return .orange
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "iso": return .brown
        default: return .secondary
        }
    }
}

// MARK: - 空状态（iOS 16 兼容）

struct EmptyState: View {

    let title: String
    let detail: String
    var symbol: String = "tray"
    var actions: (() -> AnyView)? = nil

    init(title: String, detail: String, symbol: String = "tray") {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.actions = nil
    }

    init<A: View>(title: String, detail: String, symbol: String = "tray", @ViewBuilder actions: @escaping () -> A) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.actions = { AnyView(actions()) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let actions {
                actions()
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

/// 让 EmptyState 能直接放进 List 的一行。
struct EmptyStateRow: View {
    let title: String
    let detail: String
    var symbol: String = "tray"

    var body: some View {
        EmptyState(title: title, detail: detail, symbol: symbol)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: - 加载骨架

struct LoadingRows: View {
    var count = 8
    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 12)
                        .frame(maxWidth: 180, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.quaternarySystemFill))
                        .frame(height: 9)
                        .frame(maxWidth: 96, alignment: .leading)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .redacted(reason: .placeholder)
        }
    }
}

// MARK: - 远程缩略图

struct RemoteThumb: View {

    let url: String
    let token: String
    var size: CGFloat = 44

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().scaleEffect(0.6)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        guard image == nil, !failed, !url.isEmpty, let link = URL(string: url) else {
            if url.isEmpty { failed = true }
            return
        }
        var request = URLRequest(url: link)
        request.timeoutInterval = 20
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await OlHttp.transfer.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let img = UIImage(data: data) else {
                failed = true
                return
            }
            image = img
        } catch {
            failed = true
        }
    }
}

// MARK: - 状态点

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}
