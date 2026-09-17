#requires -Version 5.1
<#
  HerMemory 发行构建 —— 拆包后的「双产物」。

  产出两份东西，职责分离：
    1) build\app\HerMemory.exe            程序本体（约 69 MB）：托盘 + 主界面 + 安装向导
    2) build\Setup.exe                    安装器（约 230 MB）：内嵌上者 + 最小随包素材，负责安装与卸载

  为什么必须分两次发布：安装器要把「程序本体」当资源嵌进自己里面（csproj 的 app/ 逻辑名），
  所以程序本体必须先存在。反过来程序本体不能带任何随包素材（否则又变回几百 MB 的巨物）。

  随包素材为什么只有三件（2026-09-16 瘦身）：只带「国内没有可靠直连源」的东西——
  内核源码快照 / uv / rg。其余大头（PortableGit 60 MB、Node 33 MB、Python 运行时 50 MB、
  PyPI 与 npm 依赖 276 MB）安装时从国内镜像取（npmmirror / 清华 PyPI），装不上才怪。
  这也是 Setup 从 861.6 MB 降到约 230 MB 的原因。

  用法：
    powershell -ExecutionPolicy Bypass -File build-release.ps1 [-Version 0.1.0]
  前置：
    build\minimal\{hermes-agent.zip,uv.exe,rg.exe} 必须已存在
    （由 scripts\make-minimal-bundle.py 从 build\offline\assets-offline\ 派生）。
#>
param(
    [string]$Version = "0.1.0",
    [string]$Configuration = "Release",
    [switch]$SkipApp,         # 跳过程序本体发布。仅在「程序本体未改动」时可用；改过 C# 就一定要重发。
    [switch]$SkipPrivacyGate  # 仅当闸门误报、且你已确认那是误报时才用。别拿它当常规开关。
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = $PSScriptRoot
$Shell = Join-Path $Root "shell\HerMemory.csproj"
$AppDir = Join-Path $Root "build\app"
$SetupDir = Join-Path $Root "build\setup"

# ---- dotnet 定位（沙盒/CI 里常不在 PATH，回落到用户级安装目录） ----
$dotnet = $null
$cmd = Get-Command dotnet -ErrorAction SilentlyContinue
if ($cmd) { $dotnet = $cmd.Source }
if (-not $dotnet) {
    $cand = Join-Path $env:USERPROFILE ".dotnet\dotnet.exe"
    if (Test-Path $cand) { $dotnet = $cand }
}
if (-not $dotnet) { throw "找不到 dotnet SDK。请安装 .NET 8 SDK，或把 dotnet 加入 PATH。" }
Write-Host "dotnet: $dotnet"

function Step([string]$n) { Write-Host ""; Write-Host "=== $n ===" -ForegroundColor Cyan }

# ---- 隐私闸门：实现见 scripts\check-privacy.ps1（抽成独立文件，便于单独测试） ----
# 起因与判据写在该文件头部。这里只负责构建前调用它：宁可不产出，也不产出带个人信息的包。
. (Join-Path $Root "scripts\check-privacy.ps1")

$common = @(
    "-c", $Configuration,
    "-r", "win-x64",
    "--self-contained", "true",
    "-p:PublishSingleFile=true",
    "-p:EnableCompressionInSingleFile=true",
    "-p:IncludeNativeLibrariesForSelfExtract=true",
    "-p:Version=$Version",
    "--no-restore"
)

# ---- 0/3 隐私闸门（先于一切构建：宁可不产出，也不产出带个人信息的包） ----
Step "0/3 隐私闸门（随包源码不得含构建机用户名）"
if ($SkipPrivacyGate) { Write-Host "  已按 -SkipPrivacyGate 跳过。" -ForegroundColor Yellow }
else { Test-PrivacyGate -Root $Root }

# 依赖还原：publish 一律带 --no-restore（避免每次发布都重新解析依赖图、也避免离线机器上联网等待），
# 所以这里负责补上——既缺文件、也缺 win-x64 目标（首次用 -r 发布时常见）都要还原。
$assets = Join-Path $Root "shell\obj\project.assets.json"
$needRestore = $true
if (Test-Path $assets) {
    try { $needRestore = -not (Select-String -Path $assets -Pattern "win-x64" -Quiet -ErrorAction Stop) } catch { $needRestore = $true }
}
if ($needRestore) {
    Step "1/3 还原依赖（win-x64）"
    & $dotnet restore $Shell -r win-x64
    if ($LASTEXITCODE -ne 0) { throw "依赖还原失败（exit $LASTEXITCODE）" }
} else {
    Write-Host "依赖已就绪（含 win-x64 目标），跳过还原。"
}

# ---- 1. 程序本体 ----
if (-not $SkipApp) {
    Step "2/3 发布程序本体（不含离线素材）"
    & $dotnet publish $Shell @common "-p:SetupMode=false" "-o" "$AppDir"
    if ($LASTEXITCODE -ne 0) { throw "程序本体发布失败（exit $LASTEXITCODE）" }
    $appExe = Join-Path $AppDir "HerMemory.exe"
    if (-not (Test-Path $appExe)) { throw "程序本体未产出：$appExe" }
    Write-Host ("  -> {0}  ({1:N1} MB)" -f $appExe, ((Get-Item $appExe).Length / 1MB)) -ForegroundColor Green
} else {
    Step "2/3 跳过程序本体发布（-SkipApp）"
}

# ---- 2. 安装器 ----
Step "3/3 发布安装器（内嵌程序本体 + 最小素材）"
# 2026-09-16 瘦身：不再内嵌 assets-offline.zip（那是 860 MB 的唯一原因）。
# 只随包带「国内没有可靠直连源」的几件：内核源码快照 / uv / rg，由 build-offline.ps1 -Minimal 产出。
# 其余素材安装时从国内镜像取（npmmirror / 清华 PyPI），见 install.ps1 的镜像链。
$kernelZip = Join-Path $Root "build\minimal\hermes-agent.zip"
if (-not (Test-Path $kernelZip)) { throw "缺少内核源码快照：$kernelZip。请先运行 scripts\make-minimal-bundle.py（依赖 build\offline\assets-offline 里的完整素材）。" }

& $dotnet publish $Shell @common "-p:SetupMode=true" "-p:AssemblyName=HerMemorySetup" "-o" "$SetupDir"
if ($LASTEXITCODE -ne 0) { throw "安装器发布失败（exit $LASTEXITCODE）" }

$setupExe = Join-Path $SetupDir "HerMemorySetup.exe"
if (-not (Test-Path $setupExe)) { throw "安装器未产出：$setupExe" }
# 文件名固定为 Setup.exe（用户 2026-09-15 定）：版本显示在程序首页，靠文件名标版本会让人误以为
# "带版本号的那个才是最新的"，下载链接与文档也被迫随版本改。
$outExe = Join-Path $Root "build\Setup.exe"
try {
    Copy-Item $setupExe $outExe -Force -ErrorAction Stop
} catch {
    throw ("无法写入 {0} —— 多半是它正被占用（文件预览、杀软扫描或残留句柄）。" +
           "请关掉占用它的程序后重试，或先手动删除该文件。原始错误：{1}") -f $outExe, $_.Exception.Message
}

Write-Host ""
Write-Host "构建完成。" -ForegroundColor Green
Write-Host ("  程序本体：{0}  ({1:N1} MB)" -f (Join-Path $AppDir "HerMemory.exe"), ((Get-Item (Join-Path $AppDir "HerMemory.exe")).Length / 1MB))
Write-Host ("  安装器  ：{0}  ({1:N1} MB)  版本 v{2}" -f $outExe, ((Get-Item $outExe).Length / 1MB), $Version)
