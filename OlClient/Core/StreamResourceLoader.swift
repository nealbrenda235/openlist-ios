//
//  StreamResourceLoader.swift
//  OpenList iOS
//
//  给 AVPlayer 的请求注入鉴权头，并**真正支持流式 Range 传输**。
//
//  ## 前两版为什么都播不了
//
//  v3：用私有的 `AVURLAssetHTTPHeaderFieldsKey` → 在 AVPlayerItem 下经常不生效。
//
//  v4：改成 AVAssetResourceLoaderDelegate 了，但 delegate 被 weak 释放，
//      报「不支持的 URL」。
//
//  v5（本版）修掉 v4 的另一个致命问题：
//  v4 的实现是 `session.dataTask` 把整个响应收完，然后一次性
//  `respond(with: data)` + `finishLoading()`。
//  这对**大文件视频是死路**：
//    - 数据要全下完才开始播，几十 MB 的视频要等很久，用户以为「播不了」
//    - AVPlayer 请求的是 Range `bytes=0-1`（探测），服务端返回 206 + 2 字节，
//      但 v4 却对 `dataRequest?.requestedLength` 不理会，Content-Length 也算错
//    - 没有处理 `requestsAllDataToEndOfResource`，导致时长/seek 判断失效
//
//  正确做法：用 `URLSessionDataDelegate` **边收边喂**，
//  每收到一段 chunk 就 `respond(with:)`，收完再 `finishLoading()`。
//  这样播放器能立刻开始缓冲播放，也能自由 seek。
//

import Foundation
import AVFoundation
import ObjectiveC

private var kLoaderKey: UInt8 = 0

final class StreamResourceLoader {

    private static let scheme = "olstream"

    /// 把真实 URL 换成自定义 scheme，并把 delegate 强引用到 asset 上。
    func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = Self.scheme
        guard let fake = comps?.url else {
            return AVURLAsset(url: url)
        }

        let asset = AVURLAsset(url: fake)
        let session = Session(realURL: url, headers: headers)
        asset.resourceLoader.setDelegate(session, queue: session.queue)
        // ★ 强引用：setDelegate 是 weak，不挂住就会被释放 → 「不支持的 URL」
        objc_setAssociatedObject(asset, &kLoaderKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    // MARK: - Session

    final class Session: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {

        let queue: OperationQueue
        private let realURL: URL
        private let headers: [String: String]

        private var urlSession: URLSession!
        /// taskIdentifier -> 正在处理的 loadingRequest
        private var pending: [Int: AVAssetResourceLoadingRequest] = [:]

        init(realURL: URL, headers: [String: String]) {
            self.realURL = realURL
            self.headers = headers
            self.queue = OperationQueue()
            self.queue.maxConcurrentOperationCount = 1
            super.init()

            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 3600
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        }

        // MARK: AVAssetResourceLoaderDelegate

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {

            var request = URLRequest(url: realURL)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

            // 转发 Range：AVPlayer 会在 request 里塞它，也可能塞在 fake URL 的 query
            var rangeHeader: String?
            if let r = loadingRequest.request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
                rangeHeader = r
            } else if let q = loadingRequest.request.url?.query, q.hasPrefix("bytes=") {
                rangeHeader = q
            }
            if let rangeHeader {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }

            let task = urlSession.dataTask(with: request)
            pending[task.taskIdentifier] = loadingRequest
            task.resume()
            return true
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            didCancel loadingRequest: AVAssetResourceLoadingRequest) {
            for (id, req) in pending where req === loadingRequest {
                pending.removeValue(forKey: id)
                urlSession.getAllTasks { tasks in
                    tasks.first { $0.taskIdentifier == id }?.cancel()
                }
                break
            }
        }

        // MARK: URLSessionDataDelegate —— 边收边喂

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

            guard let req = pending[dataTask.taskIdentifier] else {
                completionHandler(.cancel)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(req, error: NSError(domain: NSURLErrorDomain,
                                           code: NSURLErrorBadServerResponse,
                                           userInfo: [NSLocalizedDescriptionKey: "服务端响应无效"]))
                completionHandler(.cancel)
                return
            }

            // 鉴权失败要给出明确原因，否则用户只看到黑屏
            guard (200..<300).contains(http.statusCode) else {
                let reason: String
                switch http.statusCode {
                case 401, 403:
                    reason = "服务端拒绝访问（HTTP \(http.statusCode)）。\n登录可能已过期，或该直链需要重新签名。"
                case 404:
                    reason = "文件不存在（HTTP 404）"
                case 416:
                    reason = "请求范围无效（HTTP 416）"
                default:
                    reason = "播放失败：HTTP \(http.statusCode)"
                }
                finish(req, error: NSError(domain: NSURLErrorDomain,
                                           code: http.statusCode,
                                           userInfo: [NSLocalizedDescriptionKey: reason]))
                completionHandler(.cancel)
                return
            }

            // 填 contentInformation —— 这是播放器判断能不能播的关键
            if let info = req.contentInformationRequest {
                info.contentType = Self.mimeType(http, fallback: info.contentType)
                info.isByteRangeAccessSupported =
                    http.statusCode == 206
                    || (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes")
                if let lenText = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = Self.totalFromRange(lenText) {
                    info.contentLength = total
                } else if let lenText = http.value(forHTTPHeaderField: "Content-Length"),
                          let len = Int64(lenText) {
                    info.contentLength = len
                }
            }

            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            guard let req = pending[dataTask.taskIdentifier],
                  let dataRequest = req.dataRequest else { return }

            // 只喂播放器要的那一段，避免越界
            if dataRequest.requestsAllDataToEndOfResource {
                dataRequest.respond(with: data)
            } else {
                var remaining = data
                while !remaining.isEmpty {
                    let needed = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
                    let offset = dataRequest.currentOffset
                    if offset >= needed { break }
                    let available = Int64(remaining.count)
                    let take = min(needed - offset, available)
                    if take <= 0 { break }
                    dataRequest.respond(with: remaining.prefix(Int(take)))
                    remaining = remaining.dropFirst(Int(take))
                }
            }
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let req = pending.removeValue(forKey: task.taskIdentifier) else { return }
            if let error {
                let ns = error as NSError
                // 播放器主动取消时不算错误
                if ns.code == NSURLErrorCancelled { return }
                finish(req, error: error)
            } else {
                if !req.isFinished { req.finishLoading() }
            }
        }

        // MARK: 工具

        private func finish(_ req: AVAssetResourceLoadingRequest, error: Error) {
            if !req.isFinished { req.finishLoading(with: error) }
        }

        private static func mimeType(_ response: HTTPURLResponse, fallback: String?) -> String {
            if let t = response.mimeType, !t.isEmpty, t != "application/octet-stream" { return t }
            if let f = fallback, !f.isEmpty { return f }
            return "video/mp4"
        }

        private static func totalFromRange(_ text: String) -> Int64? {
            guard let slash = text.lastIndex(of: "/") else { return nil }
            let total = text[text.index(after: slash)...]
            return Int64(total)
        }
    }
}
