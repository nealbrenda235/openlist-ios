//
//  OlClientApp.swift
//  OpenList iOS
//
//  应用入口。
//
//  ★ 关键：这里必须监听 SettingsStore 的 @Published，否则「换主题色没反应」。
//  根视图用 @ObservedObject 订阅 settings —— 直接把 AppContainer 放进
//  @StateObject 是收不到 settings 内部变化的（container 本身不发布）。
//

import SwiftUI

@main
struct OlClientApp: App {

    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
        }
    }
}

/// 单独拆一层，才能用 @ObservedObject 订阅 settings / servers 的变化。
private struct RootView: View {

    let container: AppContainer

    @ObservedObject var settings: SettingsStore
    @ObservedObject var servers: ServerStore

    init(container: AppContainer) {
        self.container = container
        self.settings = container.settings
        self.servers = container.servers
    }

    var body: some View {
        AdaptiveShell()
            .environmentObject(container)
            .environmentObject(settings)
            .environmentObject(servers)
            .environmentObject(container.files)
            .environmentObject(container.downloads)
            .environmentObject(container.uploads)
            // ★ 强调色统一从这里下发，所有 @Environment(\.olAccent) 都能跟着变
            .olTint(settings.accent.color)
            .background {
                OlBackground(tone: settings.backgroundTone,
                             style: settings.backgroundStyle,
                             customColor: settings.customBackground)
            }
            .animation(.easeInOut(duration: 0.25), value: settings.backgroundTone)
            .animation(.easeInOut(duration: 0.25), value: settings.backgroundStyle)
            .preferredColorScheme(settings.themeMode.colorScheme)
            // 换颜色时加一点动画，避免生硬
            .animation(.easeInOut(duration: 0.22), value: settings.accent)
            .animation(.easeInOut(duration: 0.22), value: settings.themeMode)
    }
}
