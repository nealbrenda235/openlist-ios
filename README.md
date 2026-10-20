# OpenList iOS 客户端

把 OpenList 服务端的文件浏览、播放、下载、上传搬到 iPhone 上。SwiftUI 原生实现，
界面全部使用系统组件（`List`、`Form`、`NavigationStack`、`TabView`、SF Symbols），
跟随系统深浅色与动态字体。

最低支持 **iOS 16.0**，与 Android 版 1.1.33 的接口语义一一对应。

---

## 一、这个工程是怎么来的

按 `D:\yunxi\src`（Android 版 1.1.33）的 API 调用、数据字段和页面结构逐个对照翻译，而不是另起一套设计：

| Android（Kotlin / Compose） | iOS（Swift / SwiftUI） |
|---|---|
| `data/net/OpenListApi.kt` | `Core/OpenListApi.swift` |
| `data/net/Http.kt`（3 个 OkHttp 实例） | `Core/Net.swift`（3 个 URLSession） |
| `data/store/ServerStore.kt`（Keystore 加密） | `Core/Storage.swift` 的 `ServerStore`（Keychain） |
| `data/store/SettingsStore.kt` | `Core/Storage.swift` 的 `SettingsStore` |
| `ui/screens/FilePreferences.kt` | `Core/Storage.swift` 的 `FilePrefs` |
| `data/download/DownloadManager.kt` | `Core/DownloadManager.swift` |
| `data/upload/UploadManager.kt` | `Core/UploadManager.swift` |
| `ui/nav/NavState.kt` | `Core/Nav.swift` |
| `ui/screens/*.kt` | `Screens/*.swift` |

关键语义都保留了：

- **`Authorization` 头不带 `Bearer` 前缀**（OpenList 的服务端约定，写错就 401）
- **下载走服务端 `/d` 代理**，`raw_url` 只作备用（云盘 CDN 校验会让手机端停在 0 B）
- **直链三种形态都要归一化**：`https://…`、`//host/x`、`/d/…`
- **`is_dir` 容错**：布尔 / `0-1` / `"true"` / `type=1` 都认，否则目录会被当文件下载
- **token 失效自动重登**：用保存的账号密码换新 token（对应 Android 的 `updateToken` 路径）

---

## 二、目录结构

```
olios/
├── OlClient.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/OpenList.xcscheme
├── OlClient/
│   ├── Info.plist
│   ├── Models.swift              数据模型、路径工具、格式化
│   ├── App/
│   │   ├── OlClientApp.swift     入口，注入全局依赖
│   │   └── MainShell.swift       4 个 Tab + 全局 Toast
│   ├── Core/
│   │   ├── Net.swift             3 个 URLSession、统一错误、JSON 容错读取
│   │   ├── OpenListApi.swift     全部 OpenList 接口
│   │   ├── Storage.swift         Keychain / 服务器 / 设置 / 文件偏好 / 文本编码
│   │   ├── DownloadManager.swift 后台下载 + 断点续传
│   │   ├── UploadManager.swift   PUT 上传 + 进度
│   │   ├── Container.swift       全局依赖容器
│   │   └── Nav.swift             Tab 与 Route、每个 Tab 独立页面栈
│   ├── UI/
│   │   └── Components.swift      文件图标、空状态、骨架、缩略图
│   └── Screens/
│       ├── FilesScreen.swift     服务器列表 / 收藏 / 继续观看
│       ├── BrowseScreen.swift    目录浏览、排序、网格、长按菜单、上传
│       ├── EditServerScreen.swift 添加 / 编辑服务器
│       ├── PlayerScreen.swift    AVPlayer + 鉴权头 + 断点续播
│       ├── PreviewScreen.swift   文本编辑 / 图片 / PDF
│       ├── SearchScreen.swift    全局搜索
│       ├── TasksScreen.swift     下载 / 上传任务
│       └── SettingsScreen.swift  设置 / 外观 / 关于
└── .github/workflows/build.yml   macOS 云编译出未签名 IPA
```

---

## 三、怎么出 IPA（你有证书和 TrollStore）

### 方式 A：本地 Mac 构建（最快）

```bash
cd olios
xcodebuild -project OlClient.xcodeproj -scheme OpenList \
  -configuration Release -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/OpenList.app Payload/
zip -qry OpenList.ipa Payload
```

拿到 `OpenList.ipa` 后：

- **TrollStore**：直接在「文件」里点 IPA → 用 TrollStore 打开安装
- **自签证书**：用你的证书工具重签即可（TrollStore 装的包不需要签名，包本身能跑就够）

### 方式 B：没有 Mac，用 GitHub Actions

推到一个 GitHub 仓库（公开仓库的 macOS 运行器免费），Actions 会自动跑 `build.yml`，
产物在 Artifacts 里的 **OpenList-ipa**。下载后同样直接丢给 TrollStore。

### 装完必须做的一步

首启动去「设置 → 服务器」添加你的 OpenList 地址和账号。因为用了 **明文 HTTP**，
`Info.plist` 里已经放开 `NSAllowsArbitraryLoads`；如果你用 HTTPS + 自签证书，
需要额外在 `Net.swift` 里挂 `URLSessionDelegate` 处理信任。

---

## 四、iOS 上和 Android 不一样的地方（都是系统限制）

| 项 | Android 1.1.33 | iOS 版 | 原因 |
|---|---|---|---|
| 分片下载 | 最多 94 线程并行 | 单连接 + `resumeData` | iOS 后台下载不支持自建分片，强行做会大量失败 |
| 后台下载 | 前台服务保活 | `URLSession` background | 系统按省电策略调度，可能延迟 |
| 上传断点 | 分块续传 | 无（失败重传整文件） | `PUT` 无 Range 语义 |
| 下载目录 | `/sdcard/Download/OpenList` | 「文件」App → 我的 iPhone → OpenList | 沙盒 |
| 在线播放 | ExoPlayer + OkHttp 数据源 | AVPlayer + `AVURLAssetHTTPHeaderFieldsKey` | 系统播放器 |
| 内置浏览器 | WebView 嗅探视频 | **未做** | WKWebView 无法拿到媒体请求头，嗅探价值不大 |
| 后台管理 | `AdminScreen`（存储/任务/设置等） | **未做** | 接口量大，建议在浏览器里操作 |
| 毛玻璃 / 自定义 Dock | Haze 库自绘 | 系统 `TabView` | 按你的要求改成纯 iOS 原生观感 |

想补哪个就说，我按同样的结构加文件，不动现有代码。

---

## 五、编译前自检过的点

Windows 上没有 Swift 工具链，无法本地编译，所以用脚本做了这些静态核对：

- 无 iOS 17+ 专属 API（`ContentUnavailableView` 全部换成自写的 `EmptyState`）
- `@Published` + `didSet` 的初始化走 `_xxx = Published(initialValue:)`，避免 init 期触发 didSet
- `DownloadManager` 的后台代理线程读取状态标了 `nonisolated(unsafe)`，写操作全部回主线程
- `Route` 的 6 个 case 在 `RouteDestination` 里全部有分支
- 所有 `@EnvironmentObject` 的依赖都在 `OlClientApp` / `MainShell` 注入了
- 大括号平衡、类型无重复定义、`PathUtil` / `OlHttp` / `ToastCenter` 等符号均已定义

如果 CI 报错，把日志贴给我，通常是个别 API 签名差异，改几行就好。

---

## 六、界面速览

- **文件**：服务器卡片（在线/管理/进行中统计）+ 继续观看 + 收藏 + 服务器列表
- **浏览**：顶部面包屑、底部筛选框 + 列表/网格切换 + 上传按钮、右上角菜单（排序/新建目录/离线下载）
- **播放**：全屏黑底、进度条、倍速（0.75~2.0）、断点续播
- **任务**：分段切换下载/上传，行内显示进度、速度、错误；已完成可点开 QuickLook
- **设置**：服务器、主题（跟随系统/浅/深）、强调色、密度、并发数、离线工具

所有按钮都是系统 `Button`，所以自带触感、按压高亮、动态字体和 VoiceOver 朗读。
