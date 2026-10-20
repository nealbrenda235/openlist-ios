//
//  StreamResourceLoader.swift
//  OpenList iOS
//
//  给 AVPlayer 的请求注入自定义 HTTP 头。
//
//  ## 为什么必须自己写这层
//
//  `AVURLAssetHTTPHeaderFieldsKey` 是**私有 key**，在 AVPlayerItem 场景下经常不生效，
//  请求实际发出时不带 Authorization，服务端 401/403 → 用户看到黑屏。
//
//  正规做法：真实 URL 换成自定义 scheme（olstream://），由
//  `AVAssetResourceLoaderDelegate` 接管，用 URLSession 带完整请求头去拉，边拉边喂。
//
//  ## 一个致命的坑（v3 踩过）
//
//  `setDelegate(_:queue:)` **不持有** delegate（weak 引用）。
//  如果写成 `setDelegate(StreamingDelegate(...), queue:)`，临时对象当场释放，
//  播放器去找人处理 olstream:// 时 delegate 已经是 nil →
//  报「不支持的 URL」，视频完全打不开。
//
//  所以这里用一个 `Session` 对象把 delegate 强引用住，并让 asset 持有 Session。
//

import Foundation
import AVFoundation
import MobileCoreServices
import ObjectiveC

/// 给 asset 挂一个强引用容器：往 Objective-C 关联对象里塞，
/// 生命周期跟 asset 走，不需要调用方额外管理。
private var kLoaderSessionKey: UInt8 = 0

final class StreamResourceLoader {

    private static let customScheme = "olstream"

    /// 把真实 URL 包成播放器可用的 asset，并保证 delegate 活到 asset 释放。
    func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = Self.customScheme
        guard let fake = components?.url else {
            // scheme 替换失败就返回原 asset（至少还能试一下无鉴权直链）
            return AVURLAsset(url: url)
        }

        let asset = AVURLAsset(url: fake)
        let session = Session(realURL: url, headers: headers)
        asset.resourceLoader.setDelegate(session, queue: DispatchQueue(label: "io.openlist.streamloader"))
        // ★ 关键：强引用住 session，否则 delegate 会被 weak 释放
        objc_setAssociatedObject(asset, &kLoaderSessionKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    // MARK: - Session

    /// 持有 delegate 与实际请求逻辑。必须是 class 且被强引用。
    final class Session: NSObject, AVAssetResourceLoaderDelegate {

        private let realURL: URL
        private let headers: [String: String]
        private let queue = DispatchQueue(label: "io.openlist.streamloader.session")
        private var sessions: [ObjectIdentifier: URLSession] = [:]

        init(realURL: URL, headers: [String: String]) {
            self.realURL = realURL
            self.headers = headers
        }

        // MARK: 核心

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard let fake = loadingRequest.request.url else { return false }

            var request = URLRequest(url: realURL)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

            // 原样转发 Range：拖动进度条、识别时长的前提
            if let range = fake.query.flatMap(Self.rangeFromQuery) {
                request.setValue(range, forHTTPHeaderField: "Range")
            } else if let range = loadingRequest.request.allHTTPHeaderFields?["Range"] {
                request.setValue(range, forHTTPHeaderField: "Range")
            }

            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 3600
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: cfg)
            let key = ObjectIdentifier(loadingRequest)
            queue.sync { sessions[key] = session }

            let task = session.dataTask(with: request) { [weak self] data, response, error in
                self?.queue.sync { self?.sessions.removeValue(forKey: key) }
                session.invalidateAndCancel()

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

                guard (200..<300).contains(http.statusCode) || http.statusCode == 206 else {
                    let reason: String
                    switch http.statusCode {
                    case 401, 403:
                        reason = "服务端拒绝了访问（HTTP \(http.statusCode)）。\n可能是登录已过期，或该直链需要重新签名。"
                    case 404:
                        reason = "文件不存在（HTTP 404）"
                    case 416:
                        reason = "请求范围无效（HTTP 416）"
                    default:
                        reason = "播放失败：HTTP \(http.statusCode)"
                    }
                    loadingRequest.finishLoading(with: NSError(
                        domain: NSURLErrorDomain, code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: reason]))
                    return
                }

                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = Self.mimeType(http, incoming: loadingRequest.contentInformationRequest?.contentType)
                    info.isByteRangeAccessSupported = http.statusCode == 206
                        || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
                    if let lenText = http.value(forHTTPHeaderField: "Content-Length"), let len = Int64(lenText) {
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

            task.resume()
            return true
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            didCancel loadingRequest: AVAssetResourceLoadingRequest) {
            queue.sync {
                let key = ObjectIdentifier(loadingRequest)
                sessions[key]?.invalidateAndCancel()
                sessions.removeValue(forKey: key)
            }
        }

        // MARK: 工具

        private static func mimeType(_ response: HTTPURLResponse, incoming: String?) -> String {
            if let type = response.mimeType, !type.isEmpty, type != "application/octet-stream" {
                return type
            }
            if let incoming, !incoming.isEmpty { return incoming }
            return "video/mp4"
        }

        private static func totalFromContentRange(_ text: String) -> Int64? {
            guard let slash = text.lastIndex(of: "/") else { return nil }
            return Int64(text[text.index(after: slash)...])
        }

        /// AVPlayer 有时把 Range 放在原 URL 的 query 里
        private static func rangeFromQuery(_ query: String) -> String? {
            guard query.contains("bytes=") else { return nil }
            return query
        }
    }
}
