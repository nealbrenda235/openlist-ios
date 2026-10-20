//
//  OlClientApp.swift
//  OpenList iOS
//
//  应用入口。
//
//  ## 背景色为什么之前不生效
//
//  v4 把 `OlBackground` 挂在 `AdaptiveShell()` 的 `.background {}` 上。
//  但 AdaptiveShell → MainShell → 每个 Tab 都是 NavigationStack，
//  而 NavigationStack 内部会自己铺一层**不透明**的容器底色
//  （系统默认的 grouped background），把根视图的背景整个盖住，
//  所以无论把 tone 改成什么，屏幕上都不会有变化。
//
//  v5 的做法：
//  1. 关掉 NavigationStack 自带底色（用 `.scrollContentBackground(.hidden)`
//     配合把各页面自身的背景改成 clear）。
//  2. 背景层用 `ZStack` 垫在最底下并 `ignoresSafeArea()`，
//     这样它铺满整屏，所有透明页面都能透出它。
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
        ZStack {
            // ★ 背景在最底层，铺满全屏；所有页面必须保持透明才能看见它
            OlBackground(tone: settings.backgroundTone,
                         style: settings.backgroundStyle,
                         customColor: settings.customBackground)

            AdaptiveShell()
                .environmentObject(container)
                .environmentObject(settings)
                .environmentObject(servers)
                .environmentObject(container.files)
                .environmentObject(container.downloads)
                .environmentObject(container.uploads)
                .olTint(settings.accent.color)
        }
        .preferredColorScheme(settings.themeMode.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: settings.accent)
        .animation(.easeInOut(duration: 0.25), value: settings.themeMode)
        .animation(.easeInOut(duration: 0.30), value: settings.backgroundTone)
        .animation(.easeInOut(duration: 0.30), value: settings.backgroundStyle)
    }
}
