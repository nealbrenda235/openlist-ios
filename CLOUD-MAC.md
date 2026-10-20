# 云 Mac 出包操作步骤

> 目标：把 `olios` 工程传到云 Mac，在那边用 Xcode 编译出 `OpenList.ipa`，再取回本地。
> 好处：改一次代码约 1 分钟出包，不用等 GitHub Actions（排队 + 拉镜像要 2~4 分钟）。

---

## 第一步：把公钥加到云 Mac（只需做一次）

下面这行是**公钥**，可以公开，贴哪里都不会泄露私钥：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL5M9xLWYf2qBDGsgovIG2vxSk93g/e4LSk4jqC8gqbf ol.ios-build
```

加进去的方式看你租的是哪家：

**A. 面板里有「SSH 密钥」输入框**
直接把上面整行粘进去，保存。

**B. 提供的是密码登录**
先告诉我密码方式，或者你自己跑一次（把 `1.2.3.4` 换成真实 IP）：

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh 用户名@1.2.3.4 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

**C. 只能网页终端登录**
在网页终端里执行：

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL5M9xLWYf2qBDGsgovIG2vxSk93g/e4LSk4jqC8gqbf ol.ios-build" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---

## 第二步：告诉我连接信息

我需要这三项（**不需要密码**，用密钥就行）：

| 项 | 例子 |
|---|---|
| IP 或域名 | `203.0.113.45` |
| 用户名 | `admin` / `ec2-user` / `root` |
| 端口 | 22（默认，非标端口请说明） |

---

## 第三步：我来执行

我会跑两个命令：

```powershell
# 先探一下环境（确认 Xcode 在、系统版本够）
.\cloud-mac-build.ps1 -HostName 1.2.3.4 -User admin -Preflight

# 上传 + 编译 + 取回
.\cloud-mac-build.ps1 -HostName 1.2.3.4 -User admin
```

成功后 IPA 会落在 `C:\Users\xmwby\yb\OpenList-cloud.ipa`，我直接做成下载卡片给你。

---

## 需要先确认的一件事：云 Mac 的 Xcode 版本

**这是关键**。你要的液态玻璃需要 **Xcode 26（iOS 26 SDK）**。

如果云 Mac 只有 Xcode 15/16，编出来的包又会退回普通毛玻璃——就白折腾了。

我的 `-Preflight` 会打印：

```
--- XCODE ---
Xcode 26.6
Build version 17F113
--- SDK ---
iPhoneOS 26.5 -sdk iphoneos26.5
```

**看到 `Xcode 26.x` 和 `iPhoneOS 26.x` 才算合格。**

如果版本不够，在云 Mac 上执行（会下载十几 GB，视带宽 20~60 分钟）：

```bash
# 查看可用的 Xcode
xcodes list 2>/dev/null || echo "需要先装 xcodes"
brew install xcodesorg/made/xcodes

# 安装 Xcode 26
xcodes install 26.6
sudo xcode-select -s /Applications/Xcode_26.6.app
```

---

## 常见问题

**Q: 连不上 / Connection refused**
A: 检查云主机是否已开机、安全组是否放行 22 端口、IP 是否正确。

**Q: 报 `Permission denied (publickey)`**
A: 公钥没加到正确位置，或加了但权限太宽。在云 Mac 上执行 `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`。

**Q: 报 `bad permissions` 针对本地私钥**
A: Windows 上私钥权限必须只有你自己可读。脚本会自动修，也可以手动：
```powershell
icacls C:\Users\xmwby\yb\olios\.deploy\olios_ed25519 /inheritance:r /grant:r "$env:USERNAME:(R)"
```

**Q: 编译报错**
A: 脚本会自动把 `build.log` 拉回本地（`%TEMP%\remote-build.log`），我会读它并修代码。

**Q: 想要交互式终端自己看**
A: `.\cloud-mac-build.ps1 -HostName 1.2.3.4 -User admin -Shell`

---

## 两种出包方式对比

| | 云 Mac | GitHub Actions |
|---|---|---|
| 首次出包 | 快（1~3 分钟） | 慢（排队 + 拉 macos-26 镜像，2~4 分钟） |
| 后续出包 | 最快（约 1 分钟） | 2~4 分钟 |
| 成本 | 按小时计费 | 公开仓库免费 |
| 调试方便 | 能直接上机看 | 只能看日志 |
| Xcode 版本 | 自己装，可控 | 已固定 Xcode 26.6 |

两个都留着，云 Mac 用来快速迭代，GitHub 用来出正式包。
