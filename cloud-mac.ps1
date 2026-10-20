# ============================================================
#  cloud-mac.ps1 -- 连接云 Mac、上传工程、编译、取回 IPA
#
#  用法（三种模式）：
#    .\cloud-mac.ps1 -Preflight            # 只检查环境和 Xcode
#    .\cloud-mac.ps1 -Build                # 上传 + 编译 + 下载 IPA
#    .\cloud-mac.ps1 -Shell                # 开一个交互式 SSH 会话手动调试
#
#  连接参数优先从 cloud-mac.config.json 读取，
#  也可以用 -Host/-User/-Port 命令行覆盖。
# ============================================================

param(
    [switch]$Preflight,
    [switch]$Build,
    [switch]$Shell,
    [switch]$Force,                     # 覆盖远端同名目录
    [string]$MacHost,
    [string]$MacUser = "admin",
    [int]$MacPort = 22,
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'
$projDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$keyFile = Join-Path $projDir ".deploy\olios_ed25519"
$cfgFile = Join-Path $projDir ".deploy\cloud-mac.config.json"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------- 读取配置 ----------
if (Test-Path $cfgFile) {
    try {
        $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        if (-not $MacHost -and $cfg.host) { $MacHost = $cfg.host }
        if ($cfg.user) { $MacUser = $cfg.user }
        if ($cfg.port) { $MacPort = [int]$cfg.port }
    } catch {
        Write-Host "配置文件解析失败，忽略：$_" -ForegroundColor Yellow
    }
}

if (-not $MacHost) {
    Write-Host ""
    Write-Host "没有找到云 Mac 地址。" -ForegroundColor Yellow
    Write-Host "请二选一：" -ForegroundColor White
    Write-Host "  A) 把连接信息写进 .deploy\cloud-mac.config.json："
    Write-Host '     { "host": "1.2.3.4", "user": "admin", "port": 22 }'
    Write-Host "  B) 带参数运行："
    Write-Host '     .\cloud-mac.ps1 -Build -MacHost 1.2.3.4 -MacUser admin'
    Write-Host ""
    exit 1
}

if (-not (Test-Path $keyFile)) {
    Write-Host "私钥不存在：$keyFile" -ForegroundColor Red
    Write-Host "重新生成：ssh-keygen -t ed25519 -f `"$keyFile`" -N `"`"" -ForegroundColor Yellow
    exit 1
}

$target = "$MacUser@$MacHost"

# 关闭交互式主机密钥确认（首次连接不卡住），但保留 known_hosts
$sshBase = @(
    "-i", "`"$keyFile`"",
    "-p", "$MacPort",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "UserKnownHostsFile=`"$env:USERPROFILE\.ssh\known_hosts_olios`"",
    "-o", "ConnectTimeout=$TimeoutSec",
    "-o", "ServerAliveInterval=30",
    "-o", "BatchMode=yes"
)

function Invoke-Remote {
    param([string]$Command, [switch]$AllowFail)
    $args = $sshBase + @($target, $Command)
    $out = & ssh @args 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        Write-Host "远端命令失败（exit $LASTEXITCODE）：$Command" -ForegroundColor Red
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        throw "remote command failed"
    }
    return $out
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " 云 Mac 构建助手" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " 目标: $target : $MacPort"
Write-Host " 私钥: $keyFile"
Write-Host ""

# ---------- 1. 连通性 ----------
Write-Host "[1] 测试 SSH 连接..." -ForegroundColor Yellow
$probe = & ssh @($sshBase + @("-o", "BatchMode=yes", $target, "echo OL_OK")) 2>&1
if (-not ($probe -match "OL_OK")) {
    Write-Host "    连接失败。" -ForegroundColor Red
    $probe | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "排查顺序：" -ForegroundColor Yellow
    Write-Host "  1. 公钥是否已加进云 Mac 的 ~/.ssh/authorized_keys"
    Write-Host "  2. 端口是不是 22（很多云 Mac 给的是 2222 或随机高位端口）"
    Write-Host "  3. 用户名是不是 admin（也可能是 root / ubuntu / 平台自定义）"
    Write-Host "  4. 云 Mac 面板里是否要先「开机 / 唤醒」"
    Write-Host ""
    Write-Host "公钥内容（复制这一整行）：" -ForegroundColor White
    Get-Content "$keyFile.pub" | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
    exit 1
}
Write-Host "    OK" -ForegroundColor Green

# ---------- 2. 环境检查 ----------
Write-Host "[2] 检查 Xcode 与工具链..." -ForegroundColor Yellow
$envInfo = Invoke-Remote -AllowFail -Command @'
echo "OS:     $(sw_vers -productVersion)"
echo "ARCH:   $(uname -m)"
echo "HOST:   $(hostname)"
if command -v xcodebuild >/dev/null 2>&1; then
  echo "XCODE:  $(xcodebuild -version 2>/dev/null | head -1)"
  echo "PATH:   $(xcode-select -p)"
else
  echo "XCODE:  NOT_FOUND"
fi
if command -v xcrun >/dev/null 2>&1; then
  echo "SDKS:   $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo none)"
fi
echo "DISK:   $(df -h ~ | tail -1 | awk '{print $4" free"}')"
'@
$envInfo | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

$hasXcode = ($envInfo -join "`n") -match "XCODE:\s+\S"
if (-not $hasXcode) {
    Write-Host ""
    Write-Host "    这台机器上没有 Xcode 命令行工具。" -ForegroundColor Red
    Write-Host "    编译器只随 Xcode 分发，所以必须在 Mac 上装 Xcode。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    如果云 Mac 是图形界面可远程控制的（非纯 SSH），" -ForegroundColor White
    Write-Host "    就在它上面打开 App Store 装 Xcode，然后运行：" -ForegroundColor White
    Write-Host "      sudo xcode-select -s /Applications/Xcode.app" -ForegroundColor Green
    Write-Host "      sudo xcodebuild -license accept" -ForegroundColor Green
    Write-Host "    装好后重跑本脚本。" -ForegroundColor White
    exit 1
}
Write-Host "    Xcode 可用" -ForegroundColor Green

if ($Preflight) {
    Write-Host ""
    Write-Host "预检完成，环境就绪。" -ForegroundColor Green
    exit 0
}

# ---------- 3. 交互 Shell ----------
if ($Shell) {
    Write-Host "[3] 打开交互式会话（exit 退出）..." -ForegroundColor Yellow
    & ssh @($sshBase + @($target))
    exit $LASTEXITCODE
}

# ---------- 4. 打包上传 ----------
Write-Host "[3] 打包工程..." -ForegroundColor Yellow
$stage = Join-Path $env:TEMP "olios-upload-$stamp"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# 只带源码与工程文件，不带私钥、临时脚本
$include = @("OlClient", "OlClient.xcodeproj", ".github", "README.md", "BUILD-IPA.md", ".gitignore")
foreach ($item in $include) {
    $src = Join-Path $projDir $item
    if (Test-Path $src) {
        Copy-Item $src -Destination $stage -Recurse -Force
    }
}
$tarPath = Join-Path $env:TEMP "olios-$stamp.tar.gz"
if (Test-Path $tarPath) { Remove-Item $tarPath -Force }
& tar -czf $tarPath -C $stage .
$sizeMB = [math]::Round((Get-Item $tarPath).Length / 1MB, 2)
Write-Host "    归档: $sizeMB MB" -ForegroundColor DarkGray

$remoteDir = "~/olios-build-$stamp"
Write-Host "    上传到 $target:$remoteDir" -ForegroundColor DarkGray
& scp @("-i", "`"$keyFile`"", "-P", "$MacPort",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=`"$env:USERPROFILE\.ssh\known_hosts_olios`"",
        $tarPath, "${target}:~/olios-$stamp.tar.gz") 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "    scp 失败" -ForegroundColor Red
    exit 1
}
Write-Host "    上传完成" -ForegroundColor Green

# ---------- 5. 远端编译 ----------
Write-Host "[4] 远端编译（首次约 2-5 分钟，之后更快）..." -ForegroundColor Yellow
$buildScript = @"
set -e
mkdir -p $remoteDir
tar -xzf ~/olios-$stamp.tar.gz -C $remoteDir
cd $remoteDir

echo '--- 工程信息 ---'
xcodebuild -list -project OlClient.xcodeproj 2>/dev/null | head -20 || true

echo '--- 开始编译 ---'
set -o pipefail
xcodebuild \
  -project OlClient.xcodeproj \
  -scheme OpenList \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  ENABLE_BITCODE=NO \
  build 2>&1 | tee build.log

echo '--- 打包 IPA ---'
APP="build/Build/Products/Release-iphoneos/OpenList.app"
if [ ! -d "`$APP" ]; then
  echo "APP_NOT_FOUND"
  ls -R build/Build/Products 2>/dev/null || true
  exit 1
fi
rm -rf Payload OpenList.ipa
mkdir -p Payload
cp -R "`$APP" Payload/
zip -qry OpenList.ipa Payload
ls -lh OpenList.ipa
shasum -a 256 OpenList.ipa | tee ipa.sha256
echo "IPA_READY"
"@

$buildOut = Invoke-Remote -AllowFail -Command $buildScript
$buildOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

$joined = ($buildOut -join "`n")
if ($joined -notmatch "IPA_READY") {
    Write-Host ""
    Write-Host "    编译失败。" -ForegroundColor Red
    $errs = $buildOut | Where-Object { $_ -match "error:" }
    if ($errs) {
        Write-Host "    以下错误行请发回：" -ForegroundColor Yellow
        $errs | Select-Object -First 40 | ForEach-Object { Write-Host "      $_" -ForegroundColor White }
    } else {
        Write-Host "    没抓到 error: 行，完整日志在远端 $remoteDir/build.log" -ForegroundColor Yellow
        Write-Host "    可运行 .\cloud-mac.ps1 -Shell 进去看" -ForegroundColor Yellow
    }
    exit 1
}
Write-Host "    编译成功" -ForegroundColor Green

# ---------- 6. 取回 IPA ----------
Write-Host "[5] 下载 IPA..." -ForegroundColor Yellow
$localIpa = Join-Path "C:\Users\xmwby\yb" "OpenList-$stamp.ipa"
& scp @("-i", "`"$keyFile`"", "-P", "$MacPort",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=`"$env:USERPROFILE\.ssh\known_hosts_olios`"",
        "${target}:$remoteDir/OpenList.ipa", $localIpa) 2>&1 | Out-Null

if (-not (Test-Path $localIpa)) {
    Write-Host "    下载失败" -ForegroundColor Red
    exit 1
}

$ipa = Get-Item $localIpa
$md5 = (Get-FileHash $localIpa -Algorithm MD5).Hash
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " IPA 已生成" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host " 路径: $($ipa.FullName)"
Write-Host " 大小: $([math]::Round($ipa.Length / 1MB, 2)) MB"
Write-Host " MD5 : $md5"
Write-Host ""
Write-Host " 下一步：传到 iPhone，用 TrollStore 打开安装。"
Write-Host ""

# 清理远端临时文件（保留日志备查）
Invoke-Remote -AllowFail -Command "rm -f ~/olios-$stamp.tar.gz" | Out-Null
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
