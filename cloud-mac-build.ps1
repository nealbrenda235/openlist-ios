# cloud-mac-build.ps1
# Upload the project to a rented cloud Mac over SSH, build the IPA there, fetch it back.
#
# Usage:
#   .\cloud-mac-build.ps1 -Host 1.2.3.4 -User admin -Key C:\path\to\key
#   .\cloud-mac-build.ps1 -Host 1.2.3.4 -User admin -Key ... -Preflight   # only check env
#   .\cloud-mac-build.ps1 -Host 1.2.3.4 -User admin -Key ... -Shell      # interactive ssh
#
# Notes:
# - Everything is ASCII on purpose: PowerShell 5.1 mis-parses UTF-8 .ps1 files
#   containing Chinese characters and breaks here-strings.
# - The private key must be readable only by the current user, otherwise OpenSSH refuses it.

param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [string]$User = "admin",
    [int]$Port = 22,
    [string]$Key  = "C:\Users\xmwby\yb\olios\.deploy\olios_ed25519",
    [string]$RemoteDir = "~/openlist-ios",
    [switch]$Preflight,
    [switch]$Shell
)

$ErrorActionPreference = "Stop"

$sshOpts = @(
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=30",
    "-o", "ConnectTimeout=20",
    "-p", "$Port",
    "-i", $Key
)

function Invoke-Remote([string]$cmd) {
    & ssh @sshOpts "$User@$HostName" $cmd
    return $LASTEXITCODE
}

# --- 0. key permission check -------------------------------------------------
if (-not (Test-Path $Key)) { throw "Key not found: $Key" }
$acl = Get-Acl $Key
$bad = $acl.Access | Where-Object {
    $_.AccessControlType -eq 'Allow' -and
    $_.IdentityReference -notmatch 'SYSTEM|Administrators|' + [regex]::Escape($env:USERNAME)
}
if ($bad) {
    Write-Host "Tightening key permissions..." -ForegroundColor Yellow
    icacls $Key /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
}

Write-Host "==> Target: $User@$HostName : $Port" -ForegroundColor Cyan

if ($Shell) {
    & ssh @sshOpts "$User@$HostName"
    exit
}

# --- 1. preflight ------------------------------------------------------------
Write-Host "[1/5] Checking remote environment..." -ForegroundColor Yellow
$check = @'
echo "--- OS ---"; sw_vers
echo "--- ARCH ---"; uname -m
echo "--- XCODE ---"; xcodebuild -version 2>&1 || echo "NO_XCODE"
echo "--- SDK ---"; xcodebuild -showsdks 2>/dev/null | grep -i iphoneos | tail -3
echo "--- DISK ---"; df -h ~ | tail -1
echo "--- DONE ---"
'@
$rc = Invoke-Remote $check
if ($rc -ne 0) { throw "SSH connection failed (exit $rc)" }

if ($Preflight) {
    Write-Host ""
    Write-Host "Preflight done. Xcode must be present for the build to work." -ForegroundColor Green
    exit
}

# --- 2. upload ---------------------------------------------------------------
Write-Host ""
Write-Host "[2/5] Uploading project (0.5 MB)..." -ForegroundColor Yellow

$localRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$tar = Join-Path $env:TEMP "openlist-ios-src.tar.gz"
if (Test-Path $tar) { Remove-Item $tar -Force }

# Exclude build artifacts and the private key
& tar -czf $tar -C $localRoot --exclude=.git --exclude=.deploy --exclude=build --exclude="*.ipa" .
if ($LASTEXITCODE -ne 0) { throw "tar failed" }
Write-Host ("      archive: {0:N0} bytes" -f (Get-Item $tar).Length)

$scpOpts = @(
    "-o", "StrictHostKeyChecking=accept-new",
    "-P", "$Port",
    "-i", $Key
)
& scp @scpOpts $tar "$User@$HostName`:/tmp/openlist-ios-src.tar.gz"
if ($LASTEXITCODE -ne 0) { throw "scp failed" }

$rc = Invoke-Remote "mkdir -p $RemoteDir && tar -xzf /tmp/openlist-ios-src.tar.gz -C $RemoteDir && ls $RemoteDir"
if ($rc -ne 0) { throw "extract failed" }

# --- 3. build ----------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] Building on the Mac (this takes 1-3 min)..." -ForegroundColor Yellow

$buildScript = @'
set -o pipefail
cd ~/openlist-ios || exit 1
rm -rf build OpenList.ipa Payload build.log

xcodebuild \
  -project OlClient.xcodeproj \
  -scheme OpenList \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  > build.log 2>&1

if grep -q ": error:" build.log; then
  echo "===== ERRORS ====="
  grep ": error:" build.log | head -30
  echo "===== END ====="
  exit 1
fi

APP="build/Build/Products/Release-iphoneos/OpenList.app"
if [ ! -d "$APP" ]; then
  echo "NO_APP_BUNDLE"
  tail -40 build.log
  exit 1
fi

mkdir -p Payload
cp -R "$APP" Payload/
zip -qry OpenList.ipa Payload
echo "IPA_OK"
ls -l OpenList.ipa
shasum -a 256 OpenList.ipa
'@

$rc = Invoke-Remote $buildScript
if ($rc -ne 0) {
    Write-Host ""
    Write-Host "Build failed. Fetching log for details..." -ForegroundColor Red
    & scp @scpOpts "$User@$HostName`:$RemoteDir/build.log" "$env:TEMP\remote-build.log"
    Write-Host "Log saved to $env:TEMP\remote-build.log" -ForegroundColor Yellow
    exit 1
}

# --- 4. download -------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] Downloading IPA..." -ForegroundColor Yellow
$dest = Join-Path (Split-Path -Parent $localRoot) "OpenList-cloud.ipa"
& scp @scpOpts "$User@$HostName`:$RemoteDir/OpenList.ipa" $dest
if ($LASTEXITCODE -ne 0) { throw "download failed" }

# --- 5. verify ---------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Result" -ForegroundColor Green
$f = Get-Item $dest
Write-Host ("      path: {0}" -f $f.FullName)
Write-Host ("      size: {0:N0} bytes ({1:N2} MB)" -f $f.Length, ($f.Length / 1MB))
Write-Host ("      md5 : {0}" -f (Get-FileHash $dest -Algorithm MD5).Hash)

Write-Host ""
Write-Host "Install: transfer the IPA to your iPhone and open it with TrollStore." -ForegroundColor Cyan
