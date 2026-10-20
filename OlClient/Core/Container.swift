//
//  Container.swift
//  OpenList iOS
//
//  全局依赖容器，对应 Android 的 AppContainer。
//  实现 ObservableObject 只是为了能通过 environmentObject 下发；
//  它本身不发布状态（各 Store 各自发布）。
//

import Foundation
import SwiftUI

@MainActor
final class AppContainer: ObservableObject {

    static private(set) var shared: AppContainer?

    let settings: SettingsStore
    let servers: ServerStore
    let files: FilePrefs
    let api: OpenListApi
    let admin: AdminApi
    let downloads: DownloadManager
    let uploads: UploadManager

    init() {
        let settings = SettingsStore()
        let servers = ServerStore()
        self.settings = settings
        self.servers = servers
        self.files = FilePrefs.shared
        self.api = OpenListApi()
        self.admin = AdminApi()
        self.downloads = DownloadManager(settings: settings)
        self.uploads = UploadManager(settings: settings, servers: servers)
        AppContainer.shared = self
    }
}
