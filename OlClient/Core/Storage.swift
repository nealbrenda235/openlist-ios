//
//  Storage.swift
//  OpenList iOS
//
//  存储层：
//  - ServerStore   服务器列表（密码 / token 走 Keychain，对应 Android 的 Keystore 加密）
//  - SettingsStore 界面与行为偏好（对应 Android SettingsStore）
//  - FilePrefs     目录视图 / 收藏 / 标签 / 最近搜索（对应 Android FilePreferences）
//

import Foundation
import SwiftUI
import Combine

// MARK: - Keychain

enum Keychain {
    private static let service = "io.openlist.client"

    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 服务器存储

@MainActor
final class ServerStore: ObservableObject {

    @Published private(set) var servers: [ServerConfig] = []

    private let indexKey = "openlist.servers.v1"
    private let defaults = UserDefaults.standard

    init() { reload() }

    func reload() {
        guard let raw = defaults.string(forKey: indexKey),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([ServerIndex].self, from: data) else {
            servers = []
            return
        }
        servers = list.map { idx in
            ServerConfig(
                id: idx.id,
                name: idx.name,
                url: idx.url,
                username: idx.username,
                password: Keychain.get("srv.\(idx.id).pwd"),
                token: Keychain.get("srv.\(idx.id).token"),
                role: idx.role,
                rootPath: idx.rootPath,
                lastSeenAt: idx.lastSeenAt
            )
        }
    }

    private struct ServerIndex: Codable {
        var id: String
        var name: String
        var url: String
        var username: String
        var role: Int
        var rootPath: String
        var lastSeenAt: Double
    }

    private func persist(_ list: [ServerConfig]) {
        let index = list.map {
            ServerIndex(id: $0.id, name: $0.name, url: $0.url, username: $0.username,
                        role: $0.role, rootPath: $0.rootPath, lastSeenAt: $0.lastSeenAt)
        }
        if let data = try? JSONEncoder().encode(index),
           let text = String(data: data, encoding: .utf8) {
            defaults.set(text, forKey: indexKey)
        }
        for server in list {
            Keychain.set(server.password, for: "srv.\(server.id).pwd")
            Keychain.set(server.token, for: "srv.\(server.id).token")
        }
        servers = list
    }

    func get(_ id: String) -> ServerConfig? { servers.first { $0.id == id } }

    func add(_ server: ServerConfig) {
        persist(servers + [server])
    }

    func update(_ server: ServerConfig) {
        persist(servers.map { $0.id == server.id ? server : $0 })
    }

    /// 只更新 token / 角色（自动续期路径，避免整体回写覆盖其他字段）。
    func updateToken(_ id: String, token: String, role: Int? = nil) {
        guard var server = get(id) else { return }
        server.token = token
        if let role { server.role = role }
        server.lastSeenAt = Date().timeIntervalSince1970
        persist(servers.map { $0.id == id ? server : $0 })
    }

    func touch(_ id: String) {
        guard var server = get(id) else { return }
        server.lastSeenAt = Date().timeIntervalSince1970
        persist(servers.map { $0.id == id ? server : $0 })
    }

    func remove(_ id: String) {
        Keychain.remove("srv.\(id).pwd")
        Keychain.remove("srv.\(id).token")
        persist(servers.filter { $0.id != id })
    }

    /// 保证 token 可用：失效时用账号密码自动重登一次。
    func ensureToken(_ id: String, api: OpenListApi) async throws -> ServerConfig {
        guard let server = get(id) else { throw ApiError.local("服务器已被删除") }
        if !server.token.isEmpty { return server }
        guard !server.username.isEmpty else { return server }
        let session = try await api.login(baseUrl: server.url,
                                          username: server.username,
                                          password: server.password)
        var account = Account()
        if let me = try? await api.me(baseUrl: server.url, token: session.token) { account = me }
        updateToken(id, token: session.token, role: account.role)
        return get(id) ?? server
    }
}

// MARK: - 设置

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case teal, blue, purple, orange, pink, green
    var id: String { rawValue }

    var label: String {
        switch self {
        case .teal: return "青绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .orange: return "橙"
        case .pink: return "粉"
        case .green: return "绿"
        }
    }

    var color: Color {
        switch self {
        case .teal: return Color(red: 0.31, green: 0.48, blue: 0.39)
        case .blue: return .blue
        case .purple: return .purple
        case .orange: return .orange
        case .pink: return .pink
        case .green: return .green
        }
    }
}

enum ListDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var label: String { self == .comfortable ? "宽松" : "紧凑" }
}

enum ListLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var label: String { self == .list ? "列表" : "网格" }
}

@MainActor
final class SettingsStore: ObservableObject {

    private let d = UserDefaults.standard

    @Published var themeMode: ThemeMode {
        didSet { d.set(themeMode.rawValue, forKey: "ui.theme") }
    }
    @Published var accent: AccentChoice {
        didSet { d.set(accent.rawValue, forKey: "ui.accent") }
    }
    /// 页面背景色调（对齐 Android 的 BackgroundTone）
    @Published var backgroundTone: BackgroundTone {
        didSet { d.set(backgroundTone.rawValue, forKey: "ui.bgTone") }
    }
    /// 渐变 / 纯色
    @Published var backgroundStyle: BackgroundStyle {
        didSet { d.set(backgroundStyle.rawValue, forKey: "ui.bgStyle") }
    }
    /// 自定义背景色的 RGB 分量（0~1），tone == .custom 时生效
    @Published var customBackground: Color {
        didSet {
            let ui = UIColor(customBackground)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            d.set([Double(r), Double(g), Double(b)], forKey: "ui.bgCustom")
        }
    }
    @Published var density: ListDensity {
        didSet { d.set(density.rawValue, forKey: "ui.density") }
    }
    /// 新建目录时默认的视图；可在浏览页按目录覆盖（见 FilePrefs）。
    @Published var layout: ListLayout {
        didSet { d.set(layout.rawValue, forKey: "ui.layout") }
    }
    @Published var sort: SortChoice {
        didSet {
            d.set(sort.field.rawValue, forKey: "ui.sort.field")
            d.set(sort.ascending, forKey: "ui.sort.asc")
            d.set(sort.foldersFirst, forKey: "ui.sort.folders")
        }
    }
    @Published var showHidden: Bool {
        didSet { d.set(showHidden, forKey: "ui.showHidden") }
    }
    @Published var autoRefresh: Bool {
        didSet { d.set(autoRefresh, forKey: "ui.autoRefresh") }
    }
    /// 单文件下载的分片连接数；1 = 单线程。
    @Published var downloadThreads: Int {
        didSet { d.set(downloadThreads, forKey: "dl.threads") }
    }
    @Published var downloadConcurrency: Int {
        didSet { d.set(downloadConcurrency, forKey: "dl.concurrency") }
    }
    @Published var downloadWifiOnly: Bool {
        didSet { d.set(downloadWifiOnly, forKey: "dl.wifiOnly") }
    }
    @Published var uploadConcurrency: Int {
        didSet { d.set(uploadConcurrency, forKey: "up.concurrency") }
    }
    @Published var backgroundPlayback: Bool {
        didSet { d.set(backgroundPlayback, forKey: "play.background") }
    }
    @Published var offlineTool: String {
        didSet { d.set(offlineTool, forKey: "offline.tool") }
    }
    @Published var onboardingDone: Bool {
        didSet { d.set(onboardingDone, forKey: "ui.onboarding") }
    }
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var recentSearches: [String] = []

    static let threadOptions = [1, 2, 4, 6, 8, 16]
    static let concurrencyOptions = [1, 2, 3, 4]

    init() {
        // 用 _xxx = Published(initialValue:) 而不是直接赋值：
        // 属性带 didSet 时，init 里直接赋值会触发 willSet/didSet，
        // 此时 self 尚未完成初始化（d 之外还有别的属性），会直接编译报错。
        _themeMode = Published(initialValue: ThemeMode(rawValue: d.string(forKey: "ui.theme") ?? "") ?? .system)
        _accent = Published(initialValue: AccentChoice(rawValue: d.string(forKey: "ui.accent") ?? "") ?? .teal)
        _backgroundTone = Published(initialValue: BackgroundTone(rawValue: d.string(forKey: "ui.bgTone") ?? "") ?? .system)
        _backgroundStyle = Published(initialValue: BackgroundStyle(rawValue: d.string(forKey: "ui.bgStyle") ?? "") ?? .gradient)
        let customRGB = (d.array(forKey: "ui.bgCustom") as? [Double]) ?? [0.31, 0.48, 0.39]
        _customBackground = Published(initialValue: Color(
            red: customRGB.count == 3 ? customRGB[0] : 0.31,
            green: customRGB.count == 3 ? customRGB[1] : 0.48,
            blue: customRGB.count == 3 ? customRGB[2] : 0.39
        ))
        _density = Published(initialValue: ListDensity(rawValue: d.string(forKey: "ui.density") ?? "") ?? .comfortable)
        _layout = Published(initialValue: ListLayout(rawValue: d.string(forKey: "ui.layout") ?? "") ?? .list)
        _sort = Published(initialValue: SortChoice(
            field: SortField(rawValue: d.string(forKey: "ui.sort.field") ?? "") ?? .name,
            ascending: d.object(forKey: "ui.sort.asc") == nil ? true : d.bool(forKey: "ui.sort.asc"),
            foldersFirst: d.object(forKey: "ui.sort.folders") == nil ? true : d.bool(forKey: "ui.sort.folders")
        ))
        _showHidden = Published(initialValue: d.bool(forKey: "ui.showHidden"))
        _autoRefresh = Published(initialValue: d.object(forKey: "ui.autoRefresh") == nil ? true : d.bool(forKey: "ui.autoRefresh"))
        let threads = d.integer(forKey: "dl.threads")
        _downloadThreads = Published(initialValue: Self.threadOptions.contains(threads) ? threads : 4)
        let concurrency = d.integer(forKey: "dl.concurrency")
        _downloadConcurrency = Published(initialValue: Self.concurrencyOptions.contains(concurrency) ? concurrency : 2)
        _downloadWifiOnly = Published(initialValue: d.bool(forKey: "dl.wifiOnly"))
        let up = d.integer(forKey: "up.concurrency")
        _uploadConcurrency = Published(initialValue: Self.concurrencyOptions.contains(up) ? up : 2)
        _backgroundPlayback = Published(initialValue: d.bool(forKey: "play.background"))
        _offlineTool = Published(initialValue: d.string(forKey: "offline.tool") ?? "aria2")
        _onboardingDone = Published(initialValue: d.bool(forKey: "ui.onboarding"))
        _searchHistory = Published(initialValue: (d.array(forKey: "search.history") as? [String]) ?? [])
        _recentSearches = Published(initialValue: (d.array(forKey: "search.recent") as? [String]) ?? [])
    }

    // MARK: 搜索历史

    private let maxHistory = 20

    func addSearchHistory(_ keyword: String) {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return }
        var next = searchHistory.filter { $0.lowercased() != k.lowercased() }
        next.insert(k, at: 0)
        if next.count > maxHistory { next = Array(next.prefix(maxHistory)) }
        searchHistory = next
        d.set(next, forKey: "search.history")
    }

    func removeSearchHistory(_ keyword: String) {
        let next = searchHistory.filter { $0 != keyword }
        searchHistory = next
        d.set(next, forKey: "search.history")
    }

    func clearSearchHistory() {
        searchHistory = []
        d.removeObject(forKey: "search.history")
    }

    // MARK: 播放进度

    func playbackPosition(serverId: String, path: String) -> Double {
        d.double(forKey: "play.\(serverId).\(path)")
    }

    func savePlaybackPosition(serverId: String, path: String, seconds: Double) {
        if seconds < 3 {
            d.removeObject(forKey: "play.\(serverId).\(path)")
        } else {
            d.set(seconds, forKey: "play.\(serverId).\(path)")
        }
    }
}

// MARK: - 文件偏好

@MainActor
final class FilePrefs: ObservableObject {

    static let shared = FilePrefs()

    private let d = UserDefaults.standard

    @Published private(set) var favorites: [String] = []
    @Published private(set) var tags: [String: String] = [:]
    @Published private(set) var layouts: [String: String] = [:]

    init() {
        favorites = (d.array(forKey: "fp.favorites") as? [String]) ?? []
        tags = (d.dictionary(forKey: "fp.tags") as? [String: String]) ?? [:]
        layouts = (d.dictionary(forKey: "fp.layouts") as? [String: String]) ?? [:]
    }

    static func key(_ serverId: String, _ path: String) -> String { "\(serverId):\(path)" }

    static func split(_ key: String) -> (String, String)? {
        guard let idx = key.firstIndex(of: ":") else { return nil }
        let sid = String(key[key.startIndex..<idx])
        let path = String(key[key.index(after: idx)...])
        if sid.isEmpty || path.isEmpty { return nil }
        return (sid, path)
    }

    // 视图

    func layout(serverId: String, path: String, fallback: ListLayout) -> ListLayout {
        guard let raw = layouts[Self.key(serverId, path)] else { return fallback }
        return ListLayout(rawValue: raw) ?? fallback
    }

    func setLayout(serverId: String, path: String, layout: ListLayout) {
        layouts[Self.key(serverId, path)] = layout.rawValue
        d.set(layouts, forKey: "fp.layouts")
    }

    // 收藏

    func isFavorite(serverId: String, path: String) -> Bool {
        favorites.contains(Self.key(serverId, path))
    }

    func toggleFavorite(serverId: String, path: String) {
        let k = Self.key(serverId, path)
        if let idx = favorites.firstIndex(of: k) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(k, at: 0)
        }
        d.set(favorites, forKey: "fp.favorites")
    }

    func removeFavorite(key: String) {
        favorites.removeAll { $0 == key }
        d.set(favorites, forKey: "fp.favorites")
    }

    /// 按服务器过滤，只保留仍能对应到现有服务器的条目。
    /// 返回纯 [String]：单元素带标签的元组 (path: String) 在 Swift 里非法。
    func favoritePaths(serverId: String) -> [String] {
        favorites.compactMap { key -> String? in
            guard let (sid, path) = Self.split(key), sid == serverId else { return nil }
            return path
        }
    }

    // 标签

    func tag(serverId: String, path: String) -> String? {
        tags[Self.key(serverId, path)]
    }

    func setTag(serverId: String, path: String, tag: String?) {
        let k = Self.key(serverId, path)
        if let tag {
            tags[k] = tag
        } else {
            tags.removeValue(forKey: k)
        }
        d.set(tags, forKey: "fp.tags")
    }
}

// MARK: - 文本编码

enum TextCodec {

    struct Decoded {
        var text: String
        var encoding: String
    }

    static func decode(_ data: Data) -> Decoded {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return Decoded(text: s, encoding: "utf-8")
        }
        if data.starts(with: [0xFF, 0xFE]),
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return Decoded(text: s, encoding: "utf-16le")
        }
        if data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16BigEndian) {
            return Decoded(text: s, encoding: "utf-16be")
        }
        if let s = String(data: data, encoding: .utf8) {
            return Decoded(text: s, encoding: "utf-8")
        }
        // 中文场景最常见的是 GB18030；iOS 上用 GB_18030_2000
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) {
            return Decoded(text: s, encoding: "gb18030")
        }
        return Decoded(text: String(decoding: data, as: UTF8.self), encoding: "utf-8")
    }

    static func encode(_ text: String, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "gb18030", "gbk", "gb2312":
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return text.data(using: String.Encoding(rawValue: gb)) ?? Data(text.utf8)
        case "utf-16le":
            return text.data(using: .utf16LittleEndian) ?? Data(text.utf8)
        case "utf-16be":
            return text.data(using: .utf16BigEndian) ?? Data(text.utf8)
        default:
            return Data(text.utf8)
        }
    }

    static let supported = ["utf-8", "gb18030", "utf-16le", "utf-16be"]
}
