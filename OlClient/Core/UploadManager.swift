//
//  UploadManager.swift
//  OpenList iOS
//
//  上传队列：走 `/api/fs/put`（File-Path 头 + 原始 body），与 Android 侧一致。
//  文件先拷进沙盒再上传——文件选择器给的 URL 在后台可能失效，直接流式读容易中断。
//

import Foundation
import Combine

/// Result 的失败分支必须符合 Error 协议，String 不符合。
struct UploadFailure: Error {
    let message: String
}

enum UploadState: String, Codable {
    case queued, uploading, paused, done, failed, canceled

    var label: String {
        switch self {
        case .queued: return "等待中"
        case .uploading: return "上传中"
        case .paused: return "已暂停"
        case .done: return "已完成"
        case .failed: return "失败"
        case .canceled: return "已取消"
        }
    }
}

struct UploadItem: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var serverId: String
    var targetPath: String
    var serverName: String
    var size: Int64 = 0
    var uploaded: Int64 = 0
    var state: UploadState = .queued
    var error: String = ""
    /// 沙盒内的暂存文件名（失效后可提示重新选择）。
    var localFile: String = ""
    var createdAt: Date = Date()

    var progress: Double {
        guard size > 0 else { return 0 }
        return min(1, Double(uploaded) / Double(size))
    }
}

@MainActor
final class UploadManager: ObservableObject {

    @Published private(set) var items: [UploadItem] = []
    @Published var flash: String = ""

    private let settings: SettingsStore
    private let servers: ServerStore
    private var tasks: [String: URLSessionUploadTask] = [:]
    private var delegates: [String: UploadProgressDelegate] = [:]

    init(settings: SettingsStore, servers: ServerStore) {
        self.settings = settings
        self.servers = servers
        restore()
    }

    var activeCount: Int { items.filter { $0.state == .uploading }.count }

    // MARK: - 入队

    func enqueue(fileURL: URL, server: ServerConfig, dir: String) throws {
        let staged = try stage(fileURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? 0
        var item = UploadItem(name: fileURL.lastPathComponent,
                              serverId: server.id,
                              targetPath: PathUtil.child(dir, fileURL.lastPathComponent),
                              serverName: server.displayName)
        item.size = size
        item.localFile = staged.lastPathComponent
        items.insert(item, at: 0)
        persist()
        pump()
    }

    func enqueue(data: Data, name: String, server: ServerConfig, dir: String) throws {
        let target = Self.stagingDir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: target, options: .atomic)
        var item = UploadItem(name: name,
                              serverId: server.id,
                              targetPath: PathUtil.child(dir, name),
                              serverName: server.displayName)
        item.size = Int64(data.count)
        item.localFile = target.lastPathComponent
        items.insert(item, at: 0)
        persist()
        pump()
    }

    private func stage(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let target = Self.stagingDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    nonisolated static var stagingDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 队列控制

    func pause(_ id: String) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        update(id) { $0.state = .paused }
        persist()
        pump()
    }

    func resume(_ id: String) {
        update(id) {
            $0.state = .queued
            $0.error = ""
        }
        pump()
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        update(id) { $0.state = .canceled }
        persist()
        pump()
    }

    func retry(_ id: String) {
        update(id) {
            $0.state = .queued
            $0.error = ""
            $0.uploaded = 0
        }
        pump()
    }

    func remove(_ id: String) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        if let item = item(id), !item.localFile.isEmpty {
            try? FileManager.default.removeItem(at: Self.stagingDir.appendingPathComponent(item.localFile))
        }
        items.removeAll { $0.id == id }
        persist()
    }

    func removeFinished() {
        for item in items where item.state == .done || item.state == .canceled {
            remove(item.id)
        }
    }

    func pauseAll() {
        for item in items where item.state == .uploading || item.state == .queued {
            pause(item.id)
        }
    }

    func resumeAll() {
        for item in items where item.state == .paused || item.state == .failed {
            update(item.id) { $0.state = .queued }
        }
        pump()
    }

    func item(_ id: String) -> UploadItem? { items.first { $0.id == id } }

    private func pump() {
        let limit = max(1, settings.uploadConcurrency)
        var running = items.filter { $0.state == .uploading }.count
        guard running < limit else { return }
        for item in items where item.state == .queued {
            if running >= limit { break }
            guard let server = servers.get(item.serverId) else {
                update(item.id) {
                    $0.state = .failed
                    $0.error = "服务器已被删除"
                }
                continue
            }
            start(item, server: server)
            running += 1
        }
    }

    private func start(_ item: UploadItem, server: ServerConfig) {
        guard !server.token.isEmpty else {
            update(item.id) {
                $0.state = .failed
                $0.error = "登录已失效，请重新登录服务器"
            }
            return
        }
        let fileURL = Self.stagingDir.appendingPathComponent(item.localFile)
        guard let data = try? Data(contentsOf: fileURL) else {
            update(item.id) {
                $0.state = .failed
                $0.error = "本地文件已被清理，请重新选择"
            }
            return
        }
        guard let url = URL(string: OlHttp.join(server.url, "/api/fs/put")) else {
            update(item.id) {
                $0.state = .failed
                $0.error = "服务器地址无效"
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(server.token, forHTTPHeaderField: "Authorization")
        // 路径先逐段编码，再由 URLComponents 处理一次，避免中文路径 400
        let encoded = PathUtil.encode(item.targetPath)
        request.setValue(encoded.addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment),
                         forHTTPHeaderField: "File-Path")
        request.setValue("true", forHTTPHeaderField: "Overwrite")
        request.setValue("false", forHTTPHeaderField: "As-Task")
        request.setValue("OpenListiOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(
            onProgress: { [weak self] sent in
                Task { @MainActor in
                    self?.update(item.id) { $0.uploaded = sent }
                }
            },
            onFinish: { [weak self] (result: Result<Void, UploadFailure>) in
                Task { @MainActor in
                    guard let self else { return }
                    self.tasks.removeValue(forKey: item.id)
                    self.delegates.removeValue(forKey: item.id)
                    switch result {
                    case .success:
                        self.update(item.id) {
                            $0.state = .done
                            $0.uploaded = $0.size
                            $0.error = ""
                        }
                        self.flash = "「\(item.name)」上传完成"
                        try? FileManager.default.removeItem(at: fileURL)
                    case .failure(let failure):
                        self.update(item.id) {
                            $0.state = .failed
                            $0.error = failure.message
                        }
                    }
                    self.persist()
                    self.pump()
                }
            }
        )

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.uploadTask(with: request, from: data)
        tasks[item.id] = task
        delegates[item.id] = delegate
        update(item.id) {
            $0.state = .uploading
            $0.uploaded = 0
            $0.error = ""
        }
        task.resume()
    }

    // MARK: - 状态

    private func update(_ id: String, _ mutator: (inout UploadItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[idx]
        mutator(&item)
        items[idx] = item
    }

    // MARK: - 落盘

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("uploads.json")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([UploadItem].self, from: data) else { return }
        items = list.map { item in
            var copy = item
            if copy.state == .uploading { copy.state = .paused }
            if copy.state != .done, copy.state != .canceled {
                let path = Self.stagingDir.appendingPathComponent(copy.localFile).path
                if !FileManager.default.fileExists(atPath: path) {
                    copy.state = .failed
                    copy.error = "本地文件已被清理，请重新选择"
                }
            }
            return copy
        }
    }
}

// MARK: - 进度代理

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {

    private let onProgress: (Int64) -> Void
    private let onFinish: (Result<Void, UploadFailure>) -> Void
    private var responseText = Data()

    init(onProgress: @escaping (Int64) -> Void,
         onFinish: @escaping (Result<Void, UploadFailure>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseText.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinish(.failure(UploadFailure(message: OlRequest.describe((error as? URLError) ?? URLError(.unknown)))))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            onFinish(.failure(UploadFailure(message: "无效的服务器响应")))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: responseText, encoding: .utf8) ?? ""
            onFinish(.failure(UploadFailure(message: "HTTP \(http.statusCode)：\(text.prefix(120))")))
            return
        }
        if let json = try? JSONSerialization.jsonObject(with: responseText) as? [String: Any] {
            let code = json.olInt("code", 200)
            if code != 200 {
                let msg = json.olString("message")
                onFinish(.failure(UploadFailure(message: msg.isEmpty ? "上传失败（code=\(code)）" : msg)))
                return
            }
        }
        onFinish(.success(()))
    }
}
