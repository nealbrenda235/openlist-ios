//
//  DownloadManager.swift
//  OpenList iOS
//
//  下载队列：后台 URLSession + 断点续传（resumeData）。
//  对应 Android 侧 DownloadManager 的能力子集——iOS 上多线程分片收益有限，
//  优先保证「切后台不中断 + 中断能续」。
//

import Foundation
import Combine
import Network

enum DownloadState: String, Codable {
    case queued, running, paused, done, failed, canceled

    var label: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .done: return "已完成"
        case .failed: return "失败"
        case .canceled: return "已取消"
        }
    }
}

struct DownloadItem: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var remotePath: String
    var serverName: String
    var url: String
    var fallbackUrl: String = ""
    var headers: [String: String] = [:]
    var totalBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var state: DownloadState = .queued
    var error: String = ""
    var localFile: String = ""
    var createdAt: Date = Date()

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {

    @Published private(set) var items: [DownloadItem] = []
    /// 完成提示（UI 侧清空）。
    @Published var flash: String = ""

    private var session: URLSession!
    /// 以下状态会被 URLSession 的后台代理线程读取，标 nonisolated(unsafe)：
    /// 代理里只做「按 taskIdentifier 查 id」这一件事，写操作全部回到主线程，
    /// 因此这里的并发访问是安全的（读到的旧值最坏只会被同值覆盖）。
    nonisolated(unsafe) private var taskMap: [Int: String] = [:]           // taskIdentifier -> item id
    nonisolated(unsafe) private var tasks: [String: URLSessionDownloadTask] = [:]   // item id -> task
    private var resumeData: [String: Data] = [:]
    private var speedSamples: [String: (bytes: Int64, at: Date)] = [:]
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: "io.openlist.client.download")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 12
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        restore()
    }

    // MARK: - 队列控制

    var activeCount: Int { items.filter { $0.state == .running }.count }

    var totalSpeed: Int64 {
        items.reduce(0) { $0 + ($1.state == .running ? speed($1.id) : 0) }
    }

    private func speed(_ id: String) -> Int64 {
        guard let sample = speedSamples[id],
              let item = items.first(where: { $0.id == id }) else { return 0 }
        let dt = Date().timeIntervalSince(sample.at)
        guard dt > 0.3 else { return 0 }
        let delta = item.downloadedBytes - sample.bytes
        guard delta > 0 else { return 0 }
        return Int64(Double(delta) / dt)
    }

    func enqueue(name: String,
                 remotePath: String,
                 serverName: String,
                 url: String,
                 size: Int64,
                 headers: [String: String],
                 fallbackUrl: String = "") {
        var item = DownloadItem(name: name,
                                remotePath: remotePath,
                                serverName: serverName,
                                url: url,
                                fallbackUrl: fallbackUrl,
                                headers: headers)
        item.totalBytes = size
        items.insert(item, at: 0)
        persist()
        pump()
    }

    func pause(_ id: String) {
        guard let task = tasks[id] else {
            update(id) { $0.state = .paused }
            return
        }
        task.cancel { data in
            Task { @MainActor in
                if let data { self.resumeData[id] = data }
                self.update(id) { $0.state = .paused }
                self.persist()
            }
        }
    }

    func resume(_ id: String) {
        update(id) { $0.state = .queued }
        pump()
    }

    func cancel(_ id: String) {
        if let task = tasks[id] {
            taskMap.removeValue(forKey: task.taskIdentifier)
            task.cancel()
            tasks.removeValue(forKey: id)
        }
        resumeData.removeValue(forKey: id)
        update(id) {
            $0.state = .canceled
            $0.error = ""
        }
        persist()
        pump()
    }

    func retry(_ id: String) {
        resumeData.removeValue(forKey: id)
        update(id) {
            $0.state = .queued
            $0.error = ""
            $0.downloadedBytes = 0
        }
        pump()
    }

    /// 只从列表移除**记录**，不碰已下载的文件。
    /// （之前分不清这两个语义，导致用户左滑删除后本地文件还在。）
    func remove(_ id: String) {
        if let task = tasks[id] {
            taskMap.removeValue(forKey: task.taskIdentifier)
            task.cancel()
            tasks.removeValue(forKey: id)
        }
        resumeData.removeValue(forKey: id)
        speedSamples.removeValue(forKey: id)
        items.removeAll { $0.id == id }
        persist()
    }

    /// 删除记录 **并删除本地文件**。左滑删除走这个。
    func removeWithFile(_ id: String) {
        let file = item(id)?.localFile ?? ""
        remove(id)
        guard !file.isEmpty else { return }
        let url = Self.documentsDir.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: url)
    }

    /// 只删本地文件，保留记录（用户想重新下载时还能看到条目）。
    func deleteFile(_ id: String) {
        guard let file = item(id)?.localFile, !file.isEmpty else { return }
        let url = Self.documentsDir.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: url)
        update(id) { $0.localFile = "" }
        persist()
    }

    func removeFinished() {
        for item in items where item.state == .done || item.state == .canceled {
            removeWithFile(item.id)
        }
    }

    func pauseAll() {
        for item in items where item.state == .running || item.state == .queued {
            pause(item.id)
        }
    }

    func resumeAll() {
        for item in items where item.state == .paused || item.state == .failed {
            update(item.id) { $0.state = .queued }
        }
        pump()
    }

    /// 清空已完成的记录，但保留文件。
    func clearRecords() {
        for item in items where item.state == .done {
            remove(item.id)
        }
    }

    /// 当前是否允许下载（仅 Wi-Fi 开关生效时必须检查，否则设置形同虚设）。
    private var networkAllowed: Bool {
        guard settings.downloadWifiOnly else { return true }
        let monitor = NWPathMonitor()
        let sema = DispatchSemaphore(value: 0)
        var wifi = false
        monitor.pathUpdateHandler = { path in
            wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            sema.signal()
        }
        monitor.start(queue: DispatchQueue.global())
        _ = sema.wait(timeout: .now() + 1.0)
        monitor.cancel()
        return wifi
    }

    private func pump() {
        guard networkAllowed else {
            // 把在跑的也暂停掉，不然开关只在「新任务」上生效
            for item in items where item.state == .running {
                pause(item.id)
            }
            return
        }
        let limit = max(1, settings.downloadConcurrency)
        var running = items.filter { $0.state == .running }.count
        guard running < limit else { return }
        for item in items where item.state == .queued {
            if running >= limit { break }
            start(item)
            running += 1
        }
    }

    private func start(_ item: DownloadItem) {
        guard let url = URL(string: item.url) else {
            update(item.id) {
                $0.state = .failed
                $0.error = "下载地址无效"
            }
            return
        }
        var request = URLRequest(url: url)
        request.setValue("OpenListiOS", forHTTPHeaderField: "User-Agent")
        for (k, v) in item.headers { request.setValue(v, forHTTPHeaderField: k) }

        let task: URLSessionDownloadTask
        if let data = resumeData[item.id] {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: request)
        }
        taskMap[task.taskIdentifier] = item.id
        tasks[item.id] = task
        speedSamples[item.id] = (item.downloadedBytes, Date())
        update(item.id) { $0.state = .running }
        task.resume()
    }

    // MARK: - 状态维护

    private func update(_ id: String, _ mutator: (inout DownloadItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[idx]
        mutator(&item)
        items[idx] = item
    }

    func item(_ id: String) -> DownloadItem? { items.first { $0.id == id } }

    // MARK: - 落盘

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        // 上次进程被杀时在跑的任务一律退回暂停，由用户决定是否续传
        items = list.map { item in
            var copy = item
            if copy.state == .running || copy.state == .queued { copy.state = .paused }
            return copy
        }
    }

    /// 下载目录（文件 App 可见，靠 Info.plist 的 UIFileSharingEnabled）。
    nonisolated static var documentsDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenList", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueURL(_ name: String) -> URL {
        let dir = Self.documentsDir
        let safe = name.isEmpty ? "download" : name
        var candidate = dir.appendingPathComponent(safe)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var index = 1
        while true {
            let tryName = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = dir.appendingPathComponent(tryName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// 主线程把暂存文件改成真实文件名。
    private func finalize(_ staged: URL, name: String) -> URL {
        let target = uniqueURL(name)
        do {
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        } catch {
            return staged
        }
    }
}

// MARK: - URLSession 代理

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let tid = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let id = self.taskMap[tid] else { return }
            self.update(id) {
                $0.downloadedBytes = totalBytesWritten
                if totalBytesExpectedToWrite > 0 { $0.totalBytes = totalBytesExpectedToWrite }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let tid = downloadTask.taskIdentifier
        // 必须在代理返回前把临时文件搬走，否则系统会立即删除
        let staged = try? Self.stash(location, taskId: tid)
        Task { @MainActor in
            guard let id = self.taskMap[tid] else { return }
            self.taskMap.removeValue(forKey: tid)
            self.tasks.removeValue(forKey: id)
            if let staged {
                let name = self.item(id)?.name ?? "download"
                let final = self.finalize(staged, name: name)
                self.update(id) {
                    $0.state = .done
                    $0.localFile = final.lastPathComponent
                    $0.error = ""
                    let size = (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int64) ?? 0
                    if size > 0 { $0.totalBytes = size }
                    $0.downloadedBytes = $0.totalBytes
                }
                self.flash = "「\(name)」下载完成"
            } else {
                self.update(id) {
                    $0.state = .failed
                    $0.error = "保存文件失败，请检查存储空间"
                }
            }
            self.resumeData.removeValue(forKey: id)
            self.speedSamples.removeValue(forKey: id)
            self.persist()
            self.pump()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let tid = task.taskIdentifier
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let id = self.taskMap[tid] else { return }
            self.taskMap.removeValue(forKey: tid)
            if let live = self.tasks[id], live.taskIdentifier == tid {
                self.tasks.removeValue(forKey: id)
            }
            if let resume {
                self.resumeData[id] = resume
                self.update(id) { $0.state = .paused }
            } else if (error as NSError).code != NSURLErrorCancelled {
                self.update(id) {
                    $0.state = .failed
                    $0.error = OlRequest.describe((error as? URLError) ?? URLError(.unknown))
                }
            }
            self.persist()
            self.pump()
        }
    }

    /// 把系统临时文件搬到我们自己的暂存名（代理回调里只能拿到 taskId）。
    private nonisolated static func stash(_ location: URL, taskId: Int) throws -> URL {
        let tmp = documentsDir.appendingPathComponent(".staging-\(taskId)")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.moveItem(at: location, to: tmp)
        return tmp
    }
}
