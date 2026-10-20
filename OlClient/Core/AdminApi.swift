//
//  AdminApi.swift
//  OpenList iOS
//
//  后台管理接口，对应 Android 1.1.33 的 OpenListAdminApi。
//
//  与 OpenListApi 分开的原因（沿用 Android 的判断）：普通用户路径只需要文件接口，
//  把 admin 混进去会让「非管理员」也频繁触发 403 异常处理。
//
//  两个必须注意的点：
//  1. `addition` 是 JSON **字符串**，不是对象；提交时必须原样回传字符串。
//  2. `extract_folder` 等字段漏传会被服务端当成空值覆盖（Android #39-b 的真事故），
//     所以 StorageDraft 一律从原 Storage 整体拷贝后改字段，不要新建一份只填部分字段的草稿。
//

import Foundation

// MARK: - 数据模型

struct AdminStorage: Identifiable, Hashable {
    var id: Int
    var mountPath: String
    var driver: String
    var status: String
    var remark: String
    var order: Int
    var cacheExpiration: Int
    var disabled: Bool
    var disableIndex: Bool
    var enableSign: Bool
    var webProxy: Bool
    var webdavPolicy: String
    var proxyRange: Bool
    var downProxyUrl: String
    var orderBy: String
    var orderDirection: String
    var extractFolder: String
    var addition: String

    var additionObject: [String: Any] {
        guard let data = addition.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    var statusLabel: String {
        if disabled { return "已停用" }
        if status.isEmpty { return "正常" }
        return status
    }
}

struct DriverField: Identifiable, Hashable {
    var name: String
    var type: String
    var def: String
    var options: String
    var required: Bool
    var help: String

    var id: String { name }

    var optionList: [String] {
        options.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct DriverSchema {
    var name: String
    var common: [DriverField]
    var additional: [DriverField]
    var noUpload: Bool
    var needMs: Bool

    var allFields: [DriverField] { common + additional }
}

struct AdminSettingItem: Identifiable, Hashable {
    var key: String
    var value: String
    var type: String
    var help: String
    var group: Int
    var options: String

    var id: String { key }
}

struct ServerUser: Identifiable, Hashable {
    var id: Int
    var username: String
    var basePath: String
    var role: Int
    var permission: Int
    var disabled: Bool

    var roleLabel: String {
        switch role {
        case 2: return "管理员"
        case 1: return "访客"
        default: return "普通用户"
        }
    }
}

struct ScanProgress {
    var total: Int
    var done: Int
    var running: Bool
    var error: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }
}

enum ServerTaskKind: String, CaseIterable, Identifiable {
    case upload, copy, move, offlineDownload = "offline_download"
    case offlineTransfer = "offline_download_transfer"
    case decompress, decompressUpload = "decompress_upload"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .upload: return "上传"
        case .copy: return "复制"
        case .move: return "移动"
        case .offlineDownload: return "离线下载"
        case .offlineTransfer: return "离线转存"
        case .decompress: return "解压"
        case .decompressUpload: return "解压上传"
        }
    }
}

struct ServerTask: Identifiable, Hashable {
    var id: String
    var name: String
    var state: String
    var progress: Double
    var error: String
    var startTime: Double
    var endTime: Double

    var stateLabel: String {
        switch state.lowercased() {
        case "pending": return "等待中"
        case "queued": return "排队中"
        case "running": return "进行中"
        case "succeeded", "done": return "已完成"
        case "failed", "error": return "失败"
        case "canceled", "cancelled": return "已取消"
        case "waiting_retry": return "等待重试"
        default: return state.isEmpty ? "未知" : state
        }
    }

    var isActive: Bool {
        ["pending", "queued", "running", "waiting_retry"].contains(state.lowercased())
    }
}

struct ShareItem: Identifiable, Hashable {
    var id: String
    var files: [String]
    var remark: String
    var creator: String
    var created: String
    var expires: String
    var pwd: String
    var disabled: Bool
    var accessed: Int
    var maxAccessed: Int

    var statusText: String {
        if disabled { return "已取消" }
        if accessed > 0 && maxAccessed > 0 && accessed >= maxAccessed { return "次数用尽" }
        return "正常"
    }
}

struct AdminMetaItem: Identifiable, Hashable {
    var id: Int
    var path: String
    var password: String
    var pSub: Bool
    var write: Bool
    var hide: String
    var readme: String
    var header: String
}

struct AdminMessage {
    var title: String
    var content: String
}

// MARK: - API

final class AdminApi {

    // ---------- 存储 ----------

    func storages(baseUrl: String, token: String) async throws -> [AdminStorage] {
        let json = try await get(baseUrl, "/api/admin/storage/list?page=1&per_page=0", token)
        guard let content = json.olObject("data")?.olArray("content") else { return [] }
        return content.compactMap { Self.parseStorage($0 as? [String: Any]) }
    }

    func storage(baseUrl: String, token: String, id: Int) async throws -> AdminStorage? {
        let json = try await get(baseUrl, "/api/admin/storage/get?id=\(id)", token)
        return Self.parseStorage(json.olObject("data"))
    }

    func createStorage(baseUrl: String, token: String, storage: AdminStorage) async throws {
        _ = try await post(baseUrl, "/api/admin/storage/create", token, Self.storageBody(storage))
    }

    func updateStorage(baseUrl: String, token: String, storage: AdminStorage) async throws {
        var body = Self.storageBody(storage)
        body["id"] = storage.id
        _ = try await post(baseUrl, "/api/admin/storage/update", token, body)
    }

    func deleteStorage(baseUrl: String, token: String, id: Int) async throws {
        _ = try await post(baseUrl, "/api/admin/storage/delete", token, ["id": id])
    }

    func setStorageEnabled(baseUrl: String, token: String, id: Int, enabled: Bool) async throws {
        let path = enabled ? "/api/admin/storage/enable" : "/api/admin/storage/disable"
        _ = try await post(baseUrl, path, token, ["id": id])
    }

    func reloadStorages(baseUrl: String, token: String) async throws {
        _ = try await post(baseUrl, "/api/admin/storage/load_all", token, [:])
    }

    func driverNames(baseUrl: String, token: String) async throws -> [String] {
        let json = try await get(baseUrl, "/api/admin/driver/names", token)
        return json.olArray("data")?.compactMap { $0 as? String } ?? []
    }

    func driverSchema(baseUrl: String, token: String, driver: String) async throws -> DriverSchema? {
        let encoded = driver.addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment) ?? driver
        let json = try await get(baseUrl, "/api/admin/driver/info?driver=\(encoded)", token)
        guard let data = json.olObject("data") else { return nil }
        return DriverSchema(
            name: data.olString("name"),
            common: Self.parseFields(data.olArray("common")),
            additional: Self.parseFields(data.olArray("additional")),
            noUpload: data.olBool("no_upload"),
            needMs: data.olBool("need_ms")
        )
    }

    // ---------- 设置 ----------

    func settings(baseUrl: String, token: String, group: Int = 0) async throws -> [AdminSettingItem] {
        let json = try await get(baseUrl, "/api/admin/setting/list?group=\(group)", token)
        guard let arr = json.olArray("data") else { return [] }
        return arr.compactMap { element in
            guard let o = element as? [String: Any] else { return nil }
            return AdminSettingItem(
                key: o.olString("key"),
                value: o.olString("value"),
                type: o.olString("type", "string"),
                help: o.olString("help"),
                group: o.olInt("group"),
                options: o.olString("options")
            )
        }
    }

    func saveSetting(baseUrl: String, token: String, key: String, value: String) async throws {
        _ = try await post(baseUrl, "/api/admin/setting/save", token, ["key": key, "value": value])
    }

    func deleteSetting(baseUrl: String, token: String, key: String) async throws {
        _ = try await post(baseUrl, "/api/admin/setting/delete", token, ["key": key])
    }

    func resetSetting(baseUrl: String, token: String, key: String) async throws {
        _ = try await post(baseUrl, "/api/admin/setting/reset_token", token, ["key": key])
    }

    // ---------- 索引 / 扫描 ----------

    func buildIndex(baseUrl: String, token: String) async throws {
        _ = try await post(baseUrl, "/api/admin/index/build", token, [:])
    }

    func stopIndex(baseUrl: String, token: String) async throws {
        _ = try await post(baseUrl, "/api/admin/index/stop", token, [:])
    }

    func clearIndex(baseUrl: String, token: String) async throws {
        _ = try await post(baseUrl, "/api/admin/index/clear", token, [:])
    }

    func indexProgress(baseUrl: String, token: String) async throws -> ScanProgress {
        let json = try await get(baseUrl, "/api/admin/index/progress", token)
        return Self.parseProgress(json.olObject("data"))
    }

    func startScan(baseUrl: String, token: String) async throws {
        _ = try await post(baseUrl, "/api/admin/scan/start", token, [:])
    }

    func stopScan(baseUrl: String, token: String) async throws {
        _ = try await post(baseUrl, "/api/admin/scan/stop", token, [:])
    }

    func scanProgress(baseUrl: String, token: String) async throws -> ScanProgress {
        let json = try await get(baseUrl, "/api/admin/scan/progress", token)
        return Self.parseProgress(json.olObject("data"))
    }

    // ---------- 任务 ----------

    func tasks(baseUrl: String, token: String) async throws -> [ServerTask] {
        var out: [ServerTask] = []
        for kind in ServerTaskKind.allCases {
            for suffix in ["undone", "done"] {
                guard let json = try? await get(baseUrl, "/api/task/\(kind.rawValue)/\(suffix)", token),
                      let arr = json.olArray("data") else { continue }
                for element in arr {
                    guard let o = element as? [String: Any] else { continue }
                    let id = o.olString("id")
                    if id.isEmpty { continue }
                    out.append(ServerTask(
                        id: "\(kind.rawValue):\(id)",
                        name: o.olString("name").isEmpty ? id : o.olString("name"),
                        state: o.olString("state"),
                        progress: o["progress"] as? Double ?? Double(o.olInt("progress")),
                        error: o.olString("error"),
                        startTime: Double(o.olLong("start_time")),
                        endTime: Double(o.olLong("end_time"))
                    ))
                }
            }
        }
        return out
    }

    func taskAction(baseUrl: String, token: String, tid: String, action: String) async throws {
        guard let kind = tid.split(separator: ":").first.map(String.init) else { return }
        let realId = String(tid.dropFirst(kind.count + 1))
        let encoded = realId.addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment) ?? realId
        _ = try await get(baseUrl, "/api/task/\(kind)/\(action)?tid=\(encoded)", token)
    }

    // ---------- 用户 ----------

    func users(baseUrl: String, token: String) async throws -> [ServerUser] {
        let json = try await get(baseUrl, "/api/admin/user/list?page=1&per_page=0", token)
        guard let content = json.olObject("data")?.olArray("content") else { return [] }
        return content.compactMap { element in
            guard let o = element as? [String: Any] else { return nil }
            return ServerUser(
                id: o.olInt("id"),
                username: o.olString("username"),
                basePath: o.olString("base_path", "/"),
                role: o.olInt("role"),
                permission: o.olInt("permission"),
                disabled: o.olBool("disabled")
            )
        }
    }

    func createUser(baseUrl: String, token: String,
                    username: String, password: String,
                    basePath: String, role: Int) async throws {
        _ = try await post(baseUrl, "/api/admin/user/create", token, [
            "username": username,
            "password": password,
            "base_path": PathUtil.normalize(basePath),
            "role": role,
        ])
    }

    func deleteUser(baseUrl: String, token: String, id: Int) async throws {
        _ = try await post(baseUrl, "/api/admin/user/delete", token, ["id": id])
    }

    func cancelUser2fa(baseUrl: String, token: String, id: Int) async throws {
        _ = try await post(baseUrl, "/api/admin/user/cancel_2fa", token, ["id": id])
    }

    func clearUserCache(baseUrl: String, token: String, id: Int) async throws {
        _ = try await post(baseUrl, "/api/admin/user/del_cache", token, ["id": id])
    }

    // ---------- 元信息 ----------

    func metaList(baseUrl: String, token: String) async throws -> [AdminMetaItem] {
        let json = try await get(baseUrl, "/api/admin/meta/list?page=1&per_page=0", token)
        guard let content = json.olObject("data")?.olArray("content") else { return [] }
        return content.compactMap { element in
            guard let o = element as? [String: Any] else { return nil }
            return AdminMetaItem(
                id: o.olInt("id"),
                path: o.olString("path"),
                password: o.olString("password"),
                pSub: o.olBool("p_sub"),
                write: o.olBool("write"),
                hide: o.olString("hide"),
                readme: o.olString("readme"),
                header: o.olString("header")
            )
        }
    }

    func createMeta(baseUrl: String, token: String, path: String, password: String) async throws {
        _ = try await post(baseUrl, "/api/admin/meta/create", token, [
            "path": PathUtil.normalize(path), "password": password,
        ])
    }

    func deleteMeta(baseUrl: String, token: String, id: Int) async throws {
        _ = try await post(baseUrl, "/api/admin/meta/delete", token, ["id": id])
    }

    // ---------- 消息 ----------

    func messageGet(baseUrl: String, token: String) async throws -> AdminMessage {
        let json = try await get(baseUrl, "/api/admin/message/get", token)
        let data = json.olObject("data")
        return AdminMessage(title: data?.olString("title") ?? "",
                            content: data?.olString("content") ?? "")
    }

    func messageSend(baseUrl: String, token: String, message: String) async throws {
        _ = try await post(baseUrl, "/api/admin/message/send", token, ["message": message])
    }

    // ---------- 分享 ----------

    func shares(baseUrl: String, token: String) async throws -> [ShareItem] {
        let json = try await get(baseUrl, "/api/share/list?page=1&per_page=0", token)
        guard let content = json.olObject("data")?.olArray("content") else { return [] }
        return content.compactMap { element in
            guard let o = element as? [String: Any] else { return nil }
            return ShareItem(
                id: o.olString("id"),
                files: o.olArray("files")?.compactMap { $0 as? String } ?? [],
                remark: o.olString("remark"),
                creator: o.olString("creator"),
                created: o.olString("created"),
                expires: o.olString("expires"),
                pwd: o.olString("pwd"),
                disabled: o.olBool("disabled"),
                accessed: o.olInt("accessed"),
                maxAccessed: o.olInt("max_accessed")
            )
        }
    }

    func deleteShare(baseUrl: String, token: String, id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment) ?? id
        _ = try await get(baseUrl, "/api/share/delete?id=\(encoded)", token)
    }

    func share(baseUrl: String, token: String, id: String) async throws -> ShareItem? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.olPathSegment) ?? id
        let json = try await get(baseUrl, "/api/share/get?id=\(encoded)", token)
        return Self.parseShare(json.olObject("data"))
    }

    /// 分享提交体。`expires` 必须显式传 null 表示永久，传空字符串服务端会当成非法时间。
    private func shareBody(files: [String],
                           pwd: String,
                           remark: String,
                           expires: String?,
                           maxAccessed: Int,
                           readme: String,
                           header: String) -> [String: Any] {
        var body: [String: Any] = [
            "files": files,
            "pwd": pwd,
            "remark": remark,
            "max_accessed": maxAccessed,
            "readme": readme,
            "header": header,
            "order_by": "name",
            "order_direction": "asc",
            "extract_folder": "front",
        ]
        if let expires, !expires.isEmpty {
            body["expires"] = expires
        } else {
            body["expires"] = NSNull()
        }
        return body
    }

    @discardableResult
    func createShare(baseUrl: String,
                     token: String,
                     files: [String],
                     pwd: String,
                     remark: String,
                     expires: String?,
                     maxAccessed: Int,
                     readme: String,
                     header: String) async throws -> ShareItem {
        let body = shareBody(files: files, pwd: pwd, remark: remark,
                             expires: expires, maxAccessed: maxAccessed,
                             readme: readme, header: header)
        let json = try await post(baseUrl, "/api/share/create", token, body)
        return Self.parseShare(json.olObject("data")) ?? ShareItem(id: "", files: files, remark: remark,
                                                                  creator: "", created: "", expires: "",
                                                                  pwd: pwd, disabled: false, accessed: 0, maxAccessed: maxAccessed)
    }

    /// 编辑分享。⚠️ 全量覆盖：必须把 accessed / disabled / readme / header 原样带上，
    /// 否则服务端会把它们写成零值（用户看到的“分享突然失效/次数归零”就是这么来的）。
    func updateShare(baseUrl: String,
                     token: String,
                     id: String,
                     files: [String],
                     pwd: String,
                     remark: String,
                     expires: String?,
                     maxAccessed: Int,
                     readme: String,
                     header: String,
                     accessed: Int,
                     disabled: Bool) async throws {
        var body = shareBody(files: files, pwd: pwd, remark: remark,
                             expires: expires, maxAccessed: maxAccessed,
                             readme: readme, header: header)
        body["id"] = id
        body["accessed"] = accessed
        body["disabled"] = disabled
        _ = try await post(baseUrl, "/api/share/update", token, body)
    }

    static func parseShare(_ o: [String: Any]?) -> ShareItem? {
        guard let o else { return nil }
        return ShareItem(
            id: o.olString("id"),
            files: o.olArray("files")?.compactMap { $0 as? String } ?? [],
            remark: o.olString("remark"),
            creator: o.olString("creator"),
            created: o.olString("created"),
            expires: o.olString("expires"),
            pwd: o.olString("pwd"),
            disabled: o.olBool("disabled"),
            accessed: o.olInt("accessed"),
            maxAccessed: o.olInt("max_accessed")
        )
    }

    // ---------- 新建存储（向导） ----------

    /// 用驱动表单单字段拼一个空存储，供创建向导使用。
    func emptyStorage(driver: String, mountPath: String = "/new") -> AdminStorage {
        AdminStorage(id: 0, mountPath: mountPath, driver: driver, status: "", remark: "",
                     order: 0, cacheExpiration: 30, disabled: false, disableIndex: false,
                     enableSign: false, webProxy: false, webdavPolicy: "302_redirect",
                     proxyRange: false, downProxyUrl: "", orderBy: "", orderDirection: "",
                     extractFolder: "", addition: "{}")
    }

    // ---------- 元信息 ----------

    func updateMeta(baseUrl: String, token: String,
                    id: Int, path: String, password: String,
                    pSub: Bool, write: Bool, hide: String) async throws {
        _ = try await post(baseUrl, "/api/admin/meta/update", token, [
            "id": id, "path": path, "password": password,
            "p_sub": pSub, "write": write, "hide": hide,
        ])
    }

    // ---------- 消息 ----------

    // messageGet / messageSend 已存在

    // ---------- 底层 ----------

    private func get(_ baseUrl: String, _ path: String, _ token: String) async throws -> [String: Any] {
        guard let url = URL(string: OlHttp.join(baseUrl, path)) else {
            throw ApiError.local("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        return try await OlRequest.execute(request)
    }

    private func post(_ baseUrl: String, _ path: String, _ token: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: OlHttp.join(baseUrl, path)) else {
            throw ApiError.local("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = OlRequest.jsonBody(body)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        return try await OlRequest.execute(request)
    }

    // ---------- 解析 ----------

    static func parseStorage(_ o: [String: Any]?) -> AdminStorage? {
        guard let o else { return nil }
        return AdminStorage(
            id: o.olInt("id"),
            mountPath: o.olString("mount_path"),
            driver: o.olString("driver"),
            status: o.olString("status"),
            remark: o.olString("remark"),
            order: o.olInt("order"),
            cacheExpiration: o.olInt("cache_expiration", 30),
            disabled: o.olBool("disabled"),
            disableIndex: o.olBool("disable_index"),
            enableSign: o.olBool("enable_sign"),
            webProxy: o.olBool("web_proxy"),
            webdavPolicy: o.olString("webdav_policy", "302_redirect"),
            proxyRange: o.olBool("proxy_range"),
            downProxyUrl: o.olString("down_proxy_url"),
            orderBy: o.olString("order_by"),
            orderDirection: o.olString("order_direction"),
            extractFolder: o.olString("extract_folder"),
            addition: o.olString("addition", "{}")
        )
    }

    /// 整体提交挂载配置。`extract_folder` 必须带上，漏传会被服务端覆盖成空值。
    static func storageBody(_ s: AdminStorage) -> [String: Any] {
        [
            "mount_path": s.mountPath,
            "driver": s.driver,
            "remark": s.remark,
            "order": s.order,
            "cache_expiration": s.cacheExpiration,
            "disabled": s.disabled,
            "disable_index": s.disableIndex,
            "enable_sign": s.enableSign,
            "web_proxy": s.webProxy,
            "webdav_policy": s.webdavPolicy,
            "proxy_range": s.proxyRange,
            "down_proxy_url": s.downProxyUrl,
            "order_by": s.orderBy,
            "order_direction": s.orderDirection,
            "extract_folder": s.extractFolder,
            "addition": s.addition,
        ]
    }

    private static func parseFields(_ arr: [Any]?) -> [DriverField] {
        guard let arr else { return [] }
        return arr.compactMap { element in
            guard let o = element as? [String: Any] else { return nil }
            return DriverField(
                name: o.olString("name"),
                type: o.olString("type", "string"),
                def: o.olString("default"),
                options: o.olString("options"),
                required: o.olBool("required"),
                help: o.olString("help")
            )
        }
    }

    private static func parseProgress(_ o: [String: Any]?) -> ScanProgress {
        guard let o else { return ScanProgress(total: 0, done: 0, running: false, error: "") }
        return ScanProgress(
            total: o.olInt("total"),
            done: o.olInt("done"),
            running: o.olBool("running"),
            error: o.olString("error")
        )
    }
}
