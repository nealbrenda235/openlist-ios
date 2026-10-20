//
//  StreamResourceLoader.swift
//  OpenList iOS
//
//  给 AVPlayer 的请求注入自定义 HTTP 头。
//
//  ## 为什么必须自己写这层
//
//  第一版用了 `AVURLAsset(url:options:)` 里的 `AVURLAssetHTTPHeaderFieldsKey`。
//  那是**私有 key**，在 AVPlayerItem 播放场景下经常不生效——请求实际发出时
//  不带 Authorization，服务端直接 401/403，用户看到的就是「点开黑屏、转两下没了」。
//
//  正规做法：把真实 URL 换成一个自定义 scheme（olstream://），
//  AVURLAsset 只认这个 scheme，再由 `AVAssetResourceLoaderDelegate` 接管，
//  用 URLSession 带完整请求头去拉，边拉边喂回给播放器。
//
//  ## 关键细节
//
//  - 自定义 scheme 必须是系统不认识的，否则 resource loader 不会被调用。
//  - 播放器会发 Range 请求，必须原样转发并在响应里带回 Content-Range，
//    否则拖动进度条会失效、时长识别不出来。
//  - 只对 same-host 的直链加 Authorization（云盘 CDN 加了反而 400）。
//

import Foundation
import AVFoundation
import MobileCoreServices

final class StreamResourceLoader: NSObject {

    /// 真实的 https 地址 → 自定义 scheme 的映射，播放器只看到后者。
    private var schemes: [String: URL] = [:]
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: URLSession] = [:]

    private static let customScheme = "olstream"

    /// 把真实 URL 包成播放器可用的 asset。
    /// - Parameters:
    ///   - url: 服务端真实直链
    ///   - headers: 需要附加的请求头（Authorization / Referer 等）
    func makeAsset(url: URL, headers: [String: String]) -> (AVURLAsset, StreamResourceLoader) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = Self.customScheme
        let fake = components?.url ?? url

        lock.lock()
        schemes[fake.absoluteString] = url
        lock.unlock()

        let asset = AVURLAsset(url: fake)
        let queue = DispatchQueue(label: "io.openlist.client.streamloader")
        asset.resourceLoader.setDelegate(StreamingDelegate(loader: self, headers: headers), queue: queue)
        return (asset, self)
    }

    fileprivate func realURL(for url: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let exact = schemes[url.absoluteString] { return exact }
        // 播放器可能带上 query / fragment，做一次宽松匹配
        for (key, value) in schemes where url.absoluteString.hasPrefix(key) {
            return value
        }
        return nil
    }
}

// MARK: - 实际处理请求的代理

private final class StreamingDelegate: NSObject, AVAssetResourceLoaderDelegate {

    private let loader: StreamResourceLoader
    private let headers: [String: String]
    private let session: URLSession
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(loader: StreamResourceLoader, headers: [String: String]) {
        self.loader = loader
        self.headers = headers
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let fake = loadingRequest.request.url,
              let real = loader.realURL(for: fake) else {
            loadingRequest.finishLoading(with: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorBadURL,
                userInfo: [NSLocalizedDescriptionKey: "无法解析直链"]))
            return false
        }

        var request = URLRequest(url: real)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        // 原样转发 Range：这是拖动进度条与识别时长的前提
        if let range = loadingRequest.request.allHTTPHeaderFields?["Range"] {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        // 播放器期望的类型，若服务端不返回 Content-Type 时兜底
        if let type = loadingRequest.contentInformationRequest?.contentType {
            request.setValue(type, forHTTPHeaderField: "Accept")
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            defer { self?.tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }

            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                loadingRequest.finishLoading(with: NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "服务端响应无效"]))
                return
            }

            // 鉴权失败要给出可读原因，否则用户只看到黑屏
            guard (200..<300).contains(http.statusCode) || http.statusCode == 206 else {
                let reason: String
                switch http.statusCode {
                case 401, 403: reason = "服务端拒绝了访问（HTTP \(http.statusCode)），可能是登录过期或直链需签名"
                case 404: reason = "文件不存在（HTTP 404）"
                default: reason = "播放失败：HTTP \(http.statusCode)"
                }
                loadingRequest.finishLoading(with: NSError(
                    domain: NSURLErrorDomain, code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: reason]))
                return
            }

            // 填充内容信息（时长、类型、是否支持 Range）
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = http.mimeType ?? "video/mp4"
                info.isByteRangeAccessSupported = http.statusCode == 206 ||
                    http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
                if let lenText = http.value(forHTTPHeaderField: "Content-Length"),
                   let len = Int64(lenText) {
                    info.contentLength = len
                } else if let rangeText = http.value(forHTTPHeaderField: "Content-Range"),
                          let total = Self.totalFromContentRange(rangeText) {
                    info.contentLength = total
                }
            }

            if let data, !data.isEmpty {
                loadingRequest.dataRequest?.respond(with: data)
            }
            loadingRequest.finishLoading()
        }

        tasks[ObjectIdentifier(loadingRequest)] = task
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    /// "bytes 0-1/12345" → 12345
    private static func totalFromContentRange(_ text: String) -> Int64? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        return Int64(text[text.index(after: slash)...])
    }
}
