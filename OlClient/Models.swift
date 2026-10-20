//
//  Models.swift
//  OpenList iOS
//
//  与 Android 1.1.33 的数据模型保持同一语义：
//  字段解析容错、路径一律 POSIX 风格、可播放/可预览判断集中在 MediaKind。
//

import Foundation

// MARK: - 扩展名分类

enum MediaKind {
    static let media: Set<String> = [
        "mp4", "mkv", "webm", "mov", "avi", "ts", "m4v", "flv",
        "mp3", "flac", "wav", "aac", "m4a", "ogg", "opus",
    ]
    static let image: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "svg",
    ]
    static let archive: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "iso", "cab",
    ]
    static let text: Set<String> = [
        "txt", "md", "markdown", "log", "json", "xml", "yaml", "yml", "toml", "ini",
        "conf", "properties", "csv", "tsv", "html", "htm", "css", "js", "ts", "jsx",
        "tsx", "kt", "kts", "java", "py", "go", "rs", "c", "h", "cpp", "hpp", "sh",
        "bat", "ps1", "sql", "srt", "ass", "vtt", "nfo",
    ]
}

// MARK: - 文件

struct RemoteFile: Identifiable, Hashable {
    /// OpenList 内的绝对路径，作为稳定标识。
    let path: String
    let name: String
    let size: Int64
    let isDir: Bool
    let modified: String
    let thumb: String
    let type: Int

    var id: String { path }

    var ext: String { (name as NSString).pathExtension.lowercased() }

    var playable: Bool { !isDir && MediaKind.media.contains(ext) }
    var isImage: Bool { !isDir && MediaKind.image.contains(ext) }
    var isPdf: Bool { !isDir && ext == "pdf" }
    var isArchive: Bool { !isDir && MediaKind.archive.contains(ext) }
    var isText: Bool { !isDir && MediaKind.text.contains(ext) }

    init(path: String,
         name: String,
         size: Int64 = 0,
         isDir: Bool = false,
         modified: String = "",
         thumb: String = "",
         type: Int = 0) {
        self.path = path
        self.name = name
        self.size = size
        self.isDir = isDir
        self.modified = modified
        self.thumb = thumb
        self.type = type
    }
}

struct FilePage {
    var files: [RemoteFile]
    var total: Int
    var page: Int
    var perPage: Int

    static let empty = FilePage(files: [], total: 0, page: 1, perPage: 0)
}

// MARK: - 服务器

struct ServerConfig: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// Base URL，例如 http://192.168.1.10:5244
    var url: String
    var username: String
    var password: String
    var token: String
    /// 0 普通 / 1 访客 / 2 管理员
    var role: Int
    var rootPath: String
    var lastSeenAt: Double

    var isAdmin: Bool { role == 2 }

    var normalizedRoot: String { PathUtil.normalize(rootPath) }

    /// 展示名：没起名字就退回主机名。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        return url
    }

    var hostText: String {
        guard let u = URL(string: url) else { return url }
        guard let host = u.host else { return url }
        if let port = u.port { return "\(host):\(port)" }
        return host
    }

    static func new() -> ServerConfig {
        ServerConfig(id: UUID().uuidString, name: "", url: "", username: "",
                     password: "", token: "", role: 0, rootPath: "/", lastSeenAt: 0)
    }
}

// MARK: - 账号与直链

struct Account {
    var id: Int = 0
    var username: String = ""
    /// 0 普通 / 1 访客 / 2 管理员
    var role: Int = 0
    var basePath: String = "/"

    var isAdmin: Bool { role == 2 }

    var roleLabel: String {
        switch role {
        case 2: return "管理员"
        case 1: return "访客"
        default: return "普通用户"
        }
    }
}

struct DirectLink {
    var url: String
    var size: Int64 = 0
    var isDir: Bool = false
    var fallbackUrl: String = ""
    var sign: String = ""
}

struct OfflineTask: Identifiable {
    var id: String
    var name: String
    var state: String
    var progress: Int
    var error: String
}

struct Session {
    var token: String
    var username: String
}

// MARK: - 排序

enum SortField: String, CaseIterable, Identifiable, Codable {
    case name, size, modified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .modified: return "修改时间"
        }
    }

    var symbol: String {
        switch self {
        case .name: return "textformat.abc"
        case .size: return "externaldrive"
        case .modified: return "clock"
        }
    }
}

struct SortChoice: Codable, Hashable {
    var field: SortField = .name
    var ascending: Bool = true
    var foldersFirst: Bool = true

    func apply(to files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { a, b in
            if foldersFirst && a.isDir != b.isDir { return a.isDir }
            let result: Bool
            switch field {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                result = a.size < b.size
            case .modified:
                result = a.modified < b.modified
            }
            return ascending ? result : !result
        }
    }
}

// MARK: - 路径工具

enum PathUtil {
    /// 路径拼接（OpenList 用 POSIX 风格路径）。
    static func child(_ parent: String, _ name: String) -> String {
        let p = normalize(parent)
        let n = name.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if n.isEmpty { return p }
        return p == "/" ? "/\(n)" : "\(p)/\(n)"
    }

    /// 父目录（根的父仍是根）。
    static func parent(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p.isEmpty || p == "/" { return "/" }
        guard let idx = p.lastIndex(of: "/") else { return "/" }
        if idx == p.startIndex { return "/" }
        return String(p[p.startIndex..<idx])
    }

    /// 规范化：补前导斜杠、去掉尾部斜杠。
    static func normalize(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 逐段百分号编码，避免空格/中文/# 让 URL 解析失败。
    static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { seg in
                String(seg).addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment) ?? String(seg)
            }
            .joined(separator: "/")
    }

    /// 显示用的目录名（根显示成服务器名）。
    static func displayName(_ path: String) -> String {
        if path == "/" || path.isEmpty { return "根目录" }
        return (path as NSString).lastPathComponent
    }
}

extension CharacterSet {
    /// 允许的路径段字符：保留 RFC3986 unreserved 与部分子分隔符，其余全部编码。
    static let olPathSegment: CharacterSet = {
        var set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")
        set.insert(charactersIn: " ")
        return set
    }()
}

// MARK: - 格式化

enum Fmt {
    static func bytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) \(units[unit])" }
        return String(format: "%.1f %@", value, units[unit])
    }

    static func speed(_ bytesPerSec: Int64) -> String {
        guard bytesPerSec > 0 else { return "—" }
        return bytes(bytesPerSec) + "/s"
    }

    /// OpenList 的时间字段格式：2024-05-12T10:33:21.000+08:00 或 2024-05-12 10:33
    static func date(_ raw: String) -> Date? {
        if raw.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = pattern
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    static func relative(_ raw: String) -> String {
        guard let date = date(raw) else { return raw.isEmpty ? "—" : raw }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
