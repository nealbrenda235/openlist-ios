# 出 IPA 指南

> 你的目标：得到 `OpenList.ipa`，用 TrollStore 装到 iPhone。
> 关键限制：**IPA 必须由 macOS + Xcode 编译**。Swift 编译器和 iOS SDK 只随 Xcode 分发，
> Windows / Linux 上无论装什么都不能产出可运行的 iOS 二进制。

下面两条路，选一条。

---

## 路线 A：GitHub Actions 云编译（推荐，零硬件成本）

需要：一个 GitHub 账号（免费）、这台 Windows 上的 git。

### A-1 装 git（一次性）

```powershell
winget install --id Git.Git -e --source winget
```

装完**关掉并重开 PowerShell**，`git --version` 有输出即可。

### A-2 建仓库并推送

在 https://github.com/new 建一个仓库，名字随意（例如 `openlist-ios`），**选 Public**。
（Private 仓库也能用 CI，但会消耗 Actions 分钟数；Public 的 macOS 运行器免费无限。）

然后：

```powershell
cd C:\Users\xmwby\yb\olios
git init
git add .
git commit -m "OpenList iOS: SwiftUI 客户端"
git branch -M main
git remote add origin https://github.com/<你的用户名>/openlist-ios.git
git push -u origin main
```

`<你的用户名>` 换成你的 GitHub 用户名。推送时会要求登录，用浏览器授权即可
（git 新版会弹 GitHub 登录窗口，不需要手动配 token）。

### A-3 等 CI 出包

推送后打开仓库页面 → **Actions** → 左侧 `build-ipa` → 最新一次运行。

首次运行约 **5~10 分钟**（跑在 `macos-14` 的 M1 机器上）。完成后：

1. 拉到页面最下方 **Artifacts**
2. 下载 **OpenList-ipa**
3. 解压得到 `OpenList.ipa`
4. 传到手机 → TrollStore 打开 → 安装

### A-4 如果编译报错

Actions 里点进失败的运行，展开红色的 `Build unsigned app` 步骤，
把 **`error:`** 开头的行（通常带文件名和行号）发我，我直接改。

> 我第一次给你这版代码时说过：Windows 上没有 Swift 工具链，只能做静态核对，
> 真实编译才是唯一验证。CI 就是那个验证器。

---

## 路线 B：借一台 Mac（最快，改代码后出包只需 1 分钟）

任何装了 Xcode 的 Mac 都行（朋友的、网吧的、二手的 M1 Mac mini 都够）。

```bash
cd olios
xcodebuild -project OlClient.xcodeproj -scheme OpenList \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/OpenList.app Payload/
zip -qry OpenList.ipa Payload
```

产物 `OpenList.ipa` 直接丢给 TrollStore。

**这条路的好处**：报错立刻看到，改完立刻重编，不用等 CI 排队。
缺点是得能找到一台 Mac。

---

## 常见问题

### Q: 能不能用在线 IPA 转换 / 云打包服务？

不能。这类服务本质也是调 macOS 机器，而且会拿到你的源码。
自己跑 CI 更安全也免费。

### Q: 一定要 Public 仓库吗？

不必，但 Public 的 macOS 运行器免费。Private 会按分钟扣免费额度
（Free 计划每月 2000 分钟，macOS 按 10 倍计费 ≈ 200 分钟实际用量，
第一次编译约 8 分钟，够用 20 多次）。

### Q: TrollStore 装了要签名吗？

不用。TrollStore 利用的是系统漏洞（CoreTrust），装的是**未签名**的 IPA。
这也是为什么 CI 里要显式关掉签名：
`CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`。

### Q: 装完闪退怎么办？

TrollStore 要求 IPA 的 `MinimumOSVersion` 不高于你的系统版本。
本工程是 iOS 16.0。如果你的设备低于 16，告诉我，我把部署目标降下来
（但 `NavigationSplitView`、`LabeledContent` 等需要 16.0，降级要替换这些 API）。

### Q: 明文 HTTP 会不会被系统拦？

已在 `Info.plist` 里放开 `NSAllowsArbitraryLoads`，
所以 `http://192.168.x.x:5244` 可以直接用。
如果换成 HTTPS 自签证书，需要在 `Net.swift` 挂 `URLSessionDelegate` 处理信任。
