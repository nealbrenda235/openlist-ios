//
//  Net.swift
//  OpenList iOS
//
//  网络基础设施：三个 URLSession（API / 传输 / 播放）、统一错误类型、
//  以及一个容错的 JSON 读取扩展（对应 Android 侧的 optXxx 用法）。
//

import Foundation

// MARK: - 错误

struct ApiError: LocalizedError, Identifiable {
    let message: String
    var status: Int = 0
    var authRelated: Bool = false

    var id: String { message + "\(status)" }
    var errorDescription: String? { message }

    static func local(_ msg: String) -> ApiError { ApiError(message: msg) }
}

// MARK: - 会话

enum OlHttp {
    /// API 请求：超时偏短，卡住就报错而不是干等。
    static let api: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 文件传输：大文件下载可能长时间无数据，超时放宽。
    static let transfer: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    /// 播放：建连成功后若服务端不吐数据，20 秒就失败而不是永久缓冲。
    static let playback: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60 * 60 * 3
        return URLSession(configuration: cfg)
    }()

    /// 与服务端比较 host，决定是否附上 Authorization。
    static func sameHost(_ a: String, _ b: String) -> Bool {
        guard let ha = URL(string: a)?.host?.lowercased(),
              let hb = URL(string: b)?.host?.lowercased() else { return false }
        return ha == hb
    }

    static func join(_ base: String, _ path: String) -> String {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.isEmpty { b = base }
        let p = path.hasPrefix("/") ? path : "/" + path
        return b + p
    }
}

// MARK: - JSON 容错读取

extension Dictionary where Key == String, Value == Any {

    func olString(_ key: String, _ fallback: String = "") -> String {
        guard let v = self[key] else { return fallback }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if v is NSNull { return fallback }
        return fallback
    }

    func olInt(_ key: String, _ fallback: Int = 0) -> Int {
        guard let v = self[key] else { return fallback }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s) { return i }
        return fallback
    }

    func olLong(_ key: String, _ fallback: Int64 = 0) -> Int64 {
        guard let v = self[key] else { return fallback }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let i = Int64(s) { return i }
        return fallback
    }

    func olBool(_ key: String, _ fallback: Bool = false) -> Bool {
        guard let v = self[key] else { return fallback }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if let s = v as? String {
            return s.lowercased() == "true" || s.trimmingCharacters(in: .whitespaces) == "1"
        }
        return fallback
    }

    func olObject(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func olArray(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    /// 兼容不同存储驱动的目录标记：布尔 / 0-1 / "true" / type=1。
    func olIsDir() -> Bool {
        let raw = self["is_dir"] ?? self["isDir"] ?? self["is_folder"]
        var flag = false
        if let b = raw as? Bool {
            flag = b
        } else if let n = raw as? NSNumber {
            flag = n.intValue != 0
        } else if let s = raw as? String {
            flag = s.lowercased() == "true" || s.trimmingCharacters(in: .whitespaces) == "1"
        }
        if flag { return true }
        if let n = self["type"] as? NSNumber { return n.intValue == 1 }
        if let s = self["type"] as? String {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            return t == "1" || t == "folder" || t == "dir" || t == "directory"
        }
        return false
    }
}

// MARK: - 请求执行

enum OlRequest {

    /// 统一执行：HTTP 非 2xx 与业务 code != 200 都转成 ApiError。
    static func execute(_ request: URLRequest, session: URLSession = OlHttp.api) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ApiError(message: describe(error), status: 0)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ApiError.local("无效的服务器响应")
        }

        let text = String(data: data, encoding: .utf8) ?? ""

        guard (200..<300).contains(http.statusCode) else {
            let auth = http.statusCode == 401 || http.statusCode == 403
            throw ApiError(
                message: auth ? "登录已失效，请重新登录" : "HTTP \(http.statusCode)：\(text.prefix(160))",
                status: http.statusCode,
                authRelated: auth
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ApiError.local("服务端返回的不是合法 JSON：\(text.prefix(160))")
        }

        let code = json.olInt("code", 200)
        if code != 200 {
            let message = json.olString("message")
            throw ApiError(
                message: message.isEmpty ? "请求失败（code=\(code)）" : message,
                status: code,
                authRelated: code == 401 || code == 403
            )
        }
        return json
    }

    static func jsonBody(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "网络不可用，请检查连接"
        case .timedOut: return "请求超时，服务器没有响应"
        case .cannotFindHost: return "找不到服务器，请检查地址"
        case .cannotConnectToHost: return "无法连接服务器，请检查端口与防火墙"
        case .secureConnectionFailed: return "TLS 握手失败，检查证书或改用 http"
        case .networkConnectionLost: return "网络连接中断"
        case .cancelled: return "请求已取消"
        case .appTransportSecurityRequiresSecureConnection:
            return "系统拦截了明文 HTTP 请求"
        default: return error.localizedDescription
        }
    }
}
