# push-and-build.ps1 -- One-click: install git, init repo, push, trigger GitHub Actions
# Usage:
#   .\push-and-build.ps1 -RepoUrl https://github.com/<you>/<repo>.git
# Get the URL from https://github.com/new  (choose Public, do NOT add README)

param(
    [Parameter(Mandatory = $false)]
    [string]$RepoUrl
)

$ErrorActionPreference = 'Stop'
$projDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $projDir

Write-Host ""
Write-Host "=== OpenList iOS -> IPA builder ===" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. locate or install git ----------
function Find-Git {
    $cands = @(
        "C:\Program Files\Git\cmd\git.exe",
        "C:\Program Files (x86)\Git\cmd\git.exe",
        (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$git = Find-Git
if (-not $git) {
    Write-Host "[1/5] git not found. Installing via winget..." -ForegroundColor Yellow
    try {
        winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    } catch {
        Write-Host "winget install failed: $_" -ForegroundColor Red
        Write-Host "Please install git manually: https://git-scm.com/download/win" -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
    $git = Find-Git
    if (-not $git) {
        Write-Host "git installed but not on PATH yet." -ForegroundColor Red
        Write-Host "Close this window, open a NEW PowerShell, and run this script again." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}
Write-Host "[1/5] git: $git" -ForegroundColor Green

# ---------- 2. ask for repo url ----------
if (-not $RepoUrl) {
    Write-Host ""
    Write-Host "Create an EMPTY public repo first: https://github.com/new" -ForegroundColor Yellow
    Write-Host "(Public = free macOS runner. Do NOT initialize with README.)" -ForegroundColor DarkGray
    Write-Host ""
    $RepoUrl = Read-Host "Paste repo URL (https://github.com/you/repo.git)"
}
$RepoUrl = $RepoUrl.Trim()
if ($RepoUrl -notmatch '^https://github\.com/.+/.+') {
    Write-Host "That does not look like a GitHub https URL: $RepoUrl" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "[2/5] remote: $RepoUrl" -ForegroundColor Green

# ---------- 3. init repo ----------
if (-not (Test-Path (Join-Path $projDir ".git"))) {
    & $git init | Out-Null
    Write-Host "[3/5] git init done" -ForegroundColor Green
} else {
    Write-Host "[3/5] repo already initialized" -ForegroundColor Green
}

$curName = (& $git config user.name) 2>$null
if (-not $curName) { & $git config user.name "OpenList Builder" }
$curMail = (& $git config user.email) 2>$null
if (-not $curMail) { & $git config user.email "builder@localhost" }

& $git add -A
$staged = (& $git status --porcelain | Measure-Object -Line).Lines
Write-Host "      staged files: $staged"

& $git commit -m "OpenList iOS: SwiftUI client with admin panel" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "      (nothing new to commit)" -ForegroundColor DarkGray }

# ---------- 4. push ----------
$existing = & $git remote 2>$null
if ($existing -contains "origin") {
    & $git remote set-url origin $RepoUrl
} else {
    & $git remote add origin $RepoUrl
}

Write-Host "[4/5] pushing..." -ForegroundColor Yellow
Write-Host "      A browser window may open asking you to sign in to GitHub." -ForegroundColor DarkGray
& $git branch -M main

# Try a normal push first. --force only if the remote already has commits
# (e.g. the repo was created with a README) and the histories diverge.
& $git push -u origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host "      normal push rejected, retrying with --force..." -ForegroundColor DarkGray
    & $git push -u origin main --force
}

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Push failed." -ForegroundColor Red
    Write-Host "Common causes:" -ForegroundColor Yellow
    Write-Host "  - repo does not exist yet (create it at https://github.com/new)"
    Write-Host "  - wrong username in the URL"
    Write-Host "  - auth cancelled in browser"
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "[5/5] pushed" -ForegroundColor Green

# ---------- done ----------
$web = $RepoUrl -replace '\.git$', ''
Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " Build is starting on GitHub now." -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " 1. Open:  $web/actions" -ForegroundColor White
Write-Host " 2. Wait for 'build-ipa' (5-10 min)" -ForegroundColor White
Write-Host " 3. Scroll to Artifacts -> download 'OpenList-ipa'" -ForegroundColor White
Write-Host " 4. Unzip -> OpenList.ipa -> send to iPhone" -ForegroundColor White
Write-Host " 5. Open the .ipa with TrollStore -> Install" -ForegroundColor White
Write-Host ""
Write-Host "If the build fails, copy the lines starting with 'error:'" -ForegroundColor Yellow
Write-Host "from the 'Show errors on failure' step and send them back." -ForegroundColor Yellow
Write-Host ""

Start-Process "$web/actions"
Read-Host "Press Enter to close"
