//
//  OlClientApp.swift
//  OpenList iOS
//
//  应用入口。所有全局依赖在这里注入一次：
//  - AppContainer（含 api / downloads / uploads）
//  - SettingsStore / ServerStore / FilePrefs（各自独立发布状态）
//  NavModel 是每个 Tab 私有的，由 MainShell 逐个注入。
//

import SwiftUI

@main
struct OlClientApp: App {

    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            AdaptiveShell()
                .environmentObject(container)
                .environmentObject(container.settings)
                .environmentObject(container.servers)
                .environmentObject(container.files)
                .environmentObject(container.downloads)
                .environmentObject(container.uploads)
                .tint(container.settings.accent.color)
                .preferredColorScheme(container.settings.themeMode.colorScheme)
        }
    }
}
