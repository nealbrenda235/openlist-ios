//
//  OpenListApi.swift
//  OpenList iOS
//
//  与 Android 1.1.33 的 OpenListApi 一一对应：无状态，token 由调用方传入。
//  服务的 Authorization 头**不加 Bearer 前缀**，这一点很容易踩坑。
//

import Foundation

final class OpenListApi {

    // MARK: - 认证

    /// 登录时验证图形反爬（部分部署需要）。失败不阻断，仅提示。
    static var sendLoginCaptcha = false

    func login(baseUrl: String, username: String, password: String, otp: String = "") async throws -> Session {
        var body: [String: Any] = ["username": username, "password": password]
        if !otp.isEmpty { body["otp_code"] = otp }
        let json = try await post(baseUrl, "/api/auth/login", nil, body)
        guard let data = json.olObject("data") else { throw ApiError.local("登录响应缺少 data") }
        let token = data.olString("token")
        if token.isEmpty { throw ApiError.local("登录失败：未返回令牌") }
        return Session(token: token, username: username)
    }

    func me(baseUrl: String, token: String) async throws -> Account {
        let json = try await get(baseUrl, "/api/me", token)
        guard let data = json.olObject("data") else { throw ApiError.local("读取账号信息失败") }
        var account = Account()
        account.id = data.olInt("id")
        account.username = data.olString("username")
        account.role = data.olInt("role")
        let base = data.olString("base_path", "/")
        account.basePath = base.isEmpty ? "/" : base
        return account
    }

    func logout(baseUrl: String, token: String) async {
        _ = try? await get(baseUrl, "/api/auth/logout", token)
    }

    // MARK: - 目录

    /// `perPage = 0` 表示一次返回全部（文件管理器里分页体验差）。
    func list(baseUrl: String, token: String, path: String = "/", perPage: Int = 0) async throws -> [RemoteFile] {
        try await listPage(baseUrl: baseUrl, token: token, path: path, page: 1, perPage: perPage).files
    }

    func listPage(baseUrl: String,
                  token: String,
                  path: String = "/",
                  page: Int = 1,
                  perPage: Int = 300,
                  refresh: Bool = false) async throws -> FilePage {
        let body: [String: Any] = [
            "path": PathUtil.normalize(path),
            "password": "",
            "page": max(1, page),
            "per_page": max(0, perPage),
            "refresh": refresh,
        ]
        let json = try await post(baseUrl, "/api/fs/list", token, body)
        guard let data = json.olObject("data"),
              let content = data.olArray("content") else {
            return FilePage(files: [], total: 0, page: page, perPage: perPage)
        }

        let parent = PathUtil.normalize(path)
        var files: [RemoteFile] = []
        files.reserveCapacity(content.count)
        for element in content {
            guard let o = element as? [String: Any] else { continue }
            let name = o.olString("name")
            if name.isEmpty { continue }
            files.append(RemoteFile(
                path: PathUtil.child(parent, name),
                name: name,
                size: o.olLong("size"),
                isDir: o.olIsDir(),
                modified: o.olString("modified"),
                thumb: o.olString("thumb"),
                type: o.olInt("type")
            ))
        }

        var total = data.olInt("total", -1)
        if total < 0 { total = files.count }
        return FilePage(files: files, total: total, page: page, perPage: perPage)
    }

    // MARK: - 搜索

    /// scope：0 全部 / 1 仅文件夹 / 2 仅文件。
    func searchPage(baseUrl: String,
                    token: String,
                    keyword: String,
                    parent: String = "/",
                    scope: Int = 0,
                    page: Int = 1,
                    perPage: Int = 60) async throws -> FilePage {
        let body: [String: Any] = [
            "parent": PathUtil.normalize(parent),
            "keywords": keyword,
            "scope": scope,
            "page": max(1, page),
            "per_page": max(1, perPage),
            "password": "",
        ]
        let json = try await post(baseUrl, "/api/fs/search", token, body)
        guard let data = json.olObject("data"),
              let content = data.olArray("content") else {
            return FilePage(files: [], total: 0, page: page, perPage: perPage)
        }

        var files: [RemoteFile] = []
        for element in content {
            guard let o = element as? [String: Any] else { continue }
            let name = o.olString("name")
            if name.isEmpty { continue }
            // 搜索结果自带 parent，直接拼出完整路径
            let parentPath = o.olString("parent")
            let base = parentPath.isEmpty ? PathUtil.normalize(parent) : parentPath
            files.append(RemoteFile(
                path: PathUtil.child(base, name),
                name: name,
                size: o.olLong("size"),
                isDir: o.olIsDir(),
                modified: o.olString("modified")
            ))
        }
        var total = data.olInt("total", -1)
        if total < 0 { total = files.count }
        return FilePage(files: files, total: total, page: page, perPage: perPage)
    }

    // MARK: - 直链

    func getFile(baseUrl: String, token: String, path: String) async throws -> [String: Any]? {
        let json = try await post(baseUrl, "/api/fs/get", token, ["path": path, "password": ""])
        return json.olObject("data")
    }

    /// 播放 / 预览用直链：优先 raw_url，缺失时退回 `/d` 拼接形式。
    func directLink(baseUrl: String, token: String, file: RemoteFile) async throws -> DirectLink {
        let data = try await getFile(baseUrl: baseUrl, token: token, path: file.path)
        let isDir = (data?.olIsDir() ?? false) || file.isDir
        let raw = data?.olString("raw_url") ?? ""
        if !raw.isEmpty {
            return DirectLink(url: absolute(baseUrl, raw),
                              size: data?.olLong("size") ?? file.size,
                              isDir: isDir)
        }
        let sign = data?.olString("sign") ?? ""
        var url = OlHttp.join(baseUrl, "/d" + PathUtil.encode(file.path))
        if !sign.isEmpty {
            url += "?sign=" + (sign.addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment) ?? sign)
        }
        return DirectLink(url: url, size: file.size, isDir: isDir, sign: sign)
    }

    /// 下载用直链：优先走服务端 `/d` 代理（云盘 raw_url 常带 CDN 校验，手机直连会停在 0 B）。
    func downloadLink(baseUrl: String, token: String, file: RemoteFile) async throws -> DirectLink {
        let data = try await getFile(baseUrl: baseUrl, token: token, path: file.path)
        let isDir = (data?.olIsDir() ?? false) || file.isDir
        let size = (data?.olLong("size") ?? 0) > 0 ? data!.olLong("size") : file.size
        let sign = data?.olString("sign") ?? ""
        var proxy = OlHttp.join(baseUrl, "/d" + PathUtil.encode(file.path))
        if !sign.isEmpty {
            proxy += "?sign=" + (sign.addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment) ?? sign)
        }
        let raw = data?.olString("raw_url") ?? ""
        let fallback = raw.isEmpty ? "" : absolute(baseUrl, raw)
        return DirectLink(
            url: proxy,
            size: size,
            isDir: isDir,
            fallbackUrl: (fallback == proxy ? "" : fallback),
            sign: sign
        )
    }

    func resolveUrl(baseUrl: String, raw: String) -> String { absolute(baseUrl, raw) }

    private func absolute(_ baseUrl: String, _ raw: String) -> String {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.lowercased().hasPrefix("http://") || r.lowercased().hasPrefix("https://") { return r }
        if r.hasPrefix("//") { return "https:" + r }
        if r.hasPrefix("/") { return OlHttp.join(baseUrl, r) }
        return OlHttp.join(baseUrl, "/" + r)
    }

    // MARK: - 读写

    /// 读取字节（图片 / 文本 / PDF 预览共用），全程卡上限避免打爆内存。
    func readBytes(baseUrl: String, token: String, file: RemoteFile, maxBytes: Int = 40 * 1024 * 1024) async throws -> Data {
        let link = try await directLink(baseUrl: baseUrl, token: token, file: file)
        guard let url = URL(string: link.url) else {
            throw ApiError.local("直链地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("OpenListiOS", forHTTPHeaderField: "User-Agent")
        if OlHttp.sameHost(baseUrl, link.url) {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await OlHttp.transfer.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ApiError(message: "读取文件失败：HTTP \(http.statusCode)", status: http.statusCode)
        }
        if data.count > maxBytes {
            throw ApiError.local("文件超过 \(maxBytes / 1024 / 1024) MB，暂不支持预览")
        }
        return data
    }

    func readText(baseUrl: String, token: String, file: RemoteFile) async throws -> (text: String, encoding: String) {
        let data = try await readBytes(baseUrl: baseUrl, token: token, file: file, maxBytes: 2 * 1024 * 1024)
        if data.contains(0) {
            throw ApiError.local("检测到二进制内容，不能用文本编辑器打开")
        }
        let decoded = TextCodec.decode(data)
        return (decoded.text, decoded.encoding)
    }

    /// 覆盖写入文本（`/api/fs/put` + File-Path 头）。
    func writeText(baseUrl: String, token: String, path: String, text: String, encoding: String = "utf-8") async throws {
        let data = TextCodec.encode(text, encoding: encoding)
        if data.count > 2 * 1024 * 1024 {
            throw ApiError.local("文本超过 2 MB，暂不支持在线保存")
        }
        var request = URLRequest(url: URL(string: OlHttp.join(baseUrl, "/api/fs/put"))!)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(PathUtil.encode(path).addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment),
                         forHTTPHeaderField: "File-Path")
        request.setValue("true", forHTTPHeaderField: "Overwrite")
        request.setValue("false", forHTTPHeaderField: "As-Task")
        request.setValue("OpenListiOS", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain; charset=\(encoding)", forHTTPHeaderField: "Content-Type")

        let (body, response) = try await OlHttp.api.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ApiError.local("保存失败：无效响应") }
        if !(200..<300).contains(http.statusCode) {
            throw ApiError(message: "保存失败：HTTP \(http.statusCode)", status: http.statusCode)
        }
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let code = json.olInt("code", 200)
            if code != 200 {
                let msg = json.olString("message")
                throw ApiError(message: msg.isEmpty ? "保存失败（code=\(code)）" : msg)
            }
        }
    }

    // MARK: - 文件操作

    func mkdir(baseUrl: String, token: String, parent: String, name: String) async throws {
        _ = try await post(baseUrl, "/api/fs/mkdir", token,
                           ["path": PathUtil.child(parent, name)])
    }

    func rename(baseUrl: String, token: String, path: String, newName: String) async throws {
        _ = try await post(baseUrl, "/api/fs/rename", token, ["path": path, "name": newName])
    }

    func remove(baseUrl: String, token: String, dir: String, names: [String]) async throws {
        _ = try await post(baseUrl, "/api/fs/remove", token, ["dir": dir, "names": names])
    }

    func move(baseUrl: String, token: String, fromDir: String, names: [String], toDir: String) async throws {
        _ = try await post(baseUrl, "/api/fs/move", token,
                           ["src_dir": fromDir, "dst_dir": toDir, "names": names])
    }

    func copy(baseUrl: String, token: String, fromDir: String, names: [String], toDir: String) async throws {
        _ = try await post(baseUrl, "/api/fs/copy", token,
                           ["src_dir": fromDir, "dst_dir": toDir, "names": names])
    }

    // MARK: - 压缩包

    func archiveList(baseUrl: String,
                     token: String,
                     archivePath: String,
                     innerPath: String = "/",
                     archivePass: String = "",
                     page: Int = 1,
                     perPage: Int = 800) async throws -> FilePage {
        let body: [String: Any] = [
            "path": archivePath,
            "password": "",
            "refresh": false,
            "archive_pass": archivePass,
            "inner_path": innerPath.isEmpty ? "/" : innerPath,
            "page": max(1, page),
            "per_page": max(1, perPage),
        ]
        let json = try await post(baseUrl, "/api/fs/archive/list", token, body)
        guard let data = json.olObject("data"),
              let content = data.olArray("content") else { return .empty }
        var files: [RemoteFile] = []
        for element in content {
            guard let o = element as? [String: Any] else { continue }
            let name = o.olString("name")
            if name.isEmpty { continue }
            files.append(RemoteFile(
                path: PathUtil.child(innerPath, name),
                name: name,
                size: o.olLong("size"),
                isDir: o.olIsDir(),
                type: o.olInt("type")
            ))
        }
        var total = data.olInt("total", -1)
        if total < 0 { total = files.count }
        return FilePage(files: files, total: total, page: page, perPage: perPage)
    }

    func archiveDecompress(baseUrl: String,
                           token: String,
                           srcDir: String,
                           dstDir: String,
                           names: [String],
                           archivePass: String = "",
                           innerPath: String = "/",
                           cacheFull: Bool = true,
                           putIntoNewDir: Bool = false,
                           overwrite: Bool = false) async throws {
        let body: [String: Any] = [
            "src_dir": srcDir,
            "dst_dir": dstDir,
            "name": names,
            "archive_pass": archivePass,
            "inner_path": innerPath,
            "cache_full": cacheFull,
            "put_into_new_dir": putIntoNewDir,
            "overwrite": overwrite,
        ]
        _ = try await post(baseUrl, "/api/fs/archive/decompress", token, body)
    }

    // MARK: - 离线下载

    func addOfflineDownload(baseUrl: String,
                            token: String,
                            path: String,
                            urls: [String],
                            tool: String = "aria2",
                            deleteAfterDone: Bool = false) async throws {
        let body: [String: Any] = [
            "path": path,
            "urls": urls.joined(separator: "\n"),
            "tool": tool,
            "delete_policy": deleteAfterDone ? "delete_on_upload_succeed" : "delete_never",
        ]
        _ = try await post(baseUrl, "/api/fs/add_offline_download", token, body)
    }

    func offlineTasks(baseUrl: String, token: String) async -> [OfflineTask] {
        var out: [OfflineTask] = []
        for endpoint in ["/api/task/offline_download/undone", "/api/task/offline_download/done"] {
            guard let json = try? await get(baseUrl, endpoint, token),
                  let arr = json.olArray("data") else { continue }
            for element in arr {
                guard let o = element as? [String: Any] else { continue }
                var progress = o.olInt("progress", -1)
                if progress < 0 { progress = o.olInt("percent", -1) }
                out.append(OfflineTask(
                    id: o.olString("id"),
                    name: o.olString("name").isEmpty ? o.olString("id") : o.olString("name"),
                    state: o.olString("state"),
                    progress: progress,
                    error: o.olString("error")
                ))
            }
        }
        return out
    }

    // MARK: - 底层请求

    private func get(_ baseUrl: String, _ path: String, _ token: String?) async throws -> [String: Any] {
        guard let url = URL(string: OlHttp.join(baseUrl, path)) else {
            throw ApiError.local("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return try await OlRequest.execute(request)
    }

    private func post(_ baseUrl: String, _ path: String, _ token: String?, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: OlHttp.join(baseUrl, path)) else {
            throw ApiError.local("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = OlRequest.jsonBody(body)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return try await OlRequest.execute(request)
    }
}
