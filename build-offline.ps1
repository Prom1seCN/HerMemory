#requires -Version 5.1
<#
  HerMemory 离线资源收集脚本（在打包机上跑一次，产出 assets-offline.zip）

  用法（打包机 = 有网络的 Windows，GitHub 类资源走系统代理/Clash）：
    powershell -ExecutionPolicy Bypass -File build-offline.ps1 [-OutDir build\offline] [-Tag v2026.8.31]

  依赖：git（PATH）、PowerShell 5.1+、tar/curl（Win10 自带）。uv 与 node 由本脚本自举。
  产出：OutDir\assets-offline.zip —— 交给 dotnet publish -p:IncludeOfflineAssets=true 嵌入 exe。

  内容清单（不含 Playwright 浏览器，第一版决定）：
    python-pbs.tar.gz    CPython 3.11 运行时（PBS，npmmirror）
    node.zip             Node.js 22 LTS（npmmirror）
    portable-git.7z.exe  PortableGit 64-bit（7z 自解压格式，安装期 -o -y 解开）
    rg.exe / ffmpeg.exe / ffprobe.exe   二进制成品
    uv.exe               uv 单文件（安装期放到上游 managed uv 探测位）
    hermes-agent.zip     上游仓库源码树（含 .git，pin tag）
    hermes-agent.bundle  git bundle（离线 fetch 用：上游 update 的 fetch origin 命中它）
    uv-cache\            uv sync --extra all --locked 预热的内容寻址缓存
    npm-cache\           npm ci + camofox 预热的缓存
    THIRD-PARTY-NOTICES.txt / manifest.json（清单 + sha256）
#>
param(
    [string]$OutDir = "build\offline",
    [string]$Tag = "v2026.8.31",
    [string]$GitVer = "2.47.1",          # PortableGit 版本；对应 git-for-windows tag v2.47.1.windows.1
    [string]$RipgrepVer = "15.2.0",
    [string]$RepoUrl = "https://github.com/NousResearch/hermes-agent.git",
    [switch]$SkipUvCache,                # 跳过 uv cache 预热（调试用）
    [switch]$SkipNpmCache
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
# 相对路径以脚本所在目录为基准（不是用户当前目录——system32 事故的根因）
$OutDir = Join-Path $PSScriptRoot $OutDir
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

function Fetch([string]$url, [string]$out, [int]$timeout = 1800) {
    Write-Host "[下载] $url"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec $timeout
    if (-not (Test-Path $out) -or (Get-Item $out).Length -eq 0) { throw "下载失败：$url" }
}
function ExtractTar([string]$zip, [string]$dest) {
    # tar 的 stderr 警告在 EAP=Stop 下会升级成终止错误——临时切 Continue，事后查退出码
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { tar -xf $zip -C $dest 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "tar 解压失败（exit $LASTEXITCODE）：$zip → $dest" }
}
function Ok([string]$m) { Write-Host "[完成] $m" -ForegroundColor Green }

$Assets = Join-Path $OutDir "assets-offline"
$Work = Join-Path $OutDir "work"
New-Item -ItemType Directory -Force -Path $Assets, $Work | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()

# ---------- 1. Python 3.11 运行时（PBS，npmmirror 直连） ----------
$pyOut = Join-Path $Assets "python-pbs.tar.gz"
if (-not (Test-Path $pyOut)) {
    Fetch "https://registry.npmmirror.com/-/binary/python-build-standalone/20260901/cpython-3.11.16+20260901-x86_64-pc-windows-msvc-install_only.tar.gz" $pyOut
    Ok "python-pbs.tar.gz"
} else { Write-Host "[跳过] python-pbs.tar.gz 已存在" }

# ---------- 2. Node 22（npmmirror，版本实测钉死——不做任何列表解析） ----------
$nodeVer = "22.23.0"   # 2026-09-10 实测 npmmirror HTTP 200（34MB）；须满足上游 engines ^22.22.0（npm ci EBADENGINE 教训），升级时改这里并重验
$nodeZip = Join-Path $Assets "node-v$nodeVer-win-x64.zip"
$nodeWork = Join-Path $Work "node-$nodeVer"
if (-not (Test-Path $nodeZip)) {
    Fetch "https://registry.npmmirror.com/-/binary/node/v$nodeVer/node-v$nodeVer-win-x64.zip" $nodeZip
    Ok "node.zip = v$nodeVer"
} else { Write-Host "[跳过] node.zip 已存在" }
if (-not (Test-Path (Join-Path $nodeWork "node.exe"))) {
    if (Test-Path $nodeWork) { Remove-Item -Recurse -Force $nodeWork }
    ExtractTar $nodeZip $Work
    $inner = Get-ChildItem $Work -Directory -Filter "node-v*" | Select-Object -First 1
    Move-Item $inner.FullName $nodeWork
    Ok "node 自举解压"
}

# ---------- 3. uv（github latest；单文件 exe） ----------
$uvExe = Join-Path $Assets "uv.exe"
if (-not (Test-Path $uvExe)) {
    $uvZip = Join-Path $Work "uv.zip"
    Fetch "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip" $uvZip
    $uvTmp = Join-Path $Work "uv-tmp"
    if (Test-Path $uvTmp) { Remove-Item -Recurse -Force $uvTmp }
    New-Item -ItemType Directory -Force -Path $uvTmp | Out-Null
    ExtractTar $uvZip $uvTmp
    $uvFound = Get-ChildItem $uvTmp -Recurse -Filter "uv.exe" | Select-Object -First 1
    if (-not $uvFound) { throw "uv.zip 里没找到 uv.exe" }
    Copy-Item $uvFound.FullName $uvExe -Force
    Ok "uv.exe"
} else { Write-Host "[跳过] uv.exe 已存在" }

# ---------- 4. PortableGit（github；7z 自解压器，安装期 -o -y 展开） ----------
$gitOut = Join-Path $Assets "portable-git.7z.exe"
if (-not (Test-Path $gitOut)) {
    $gitTag = "v$GitVer.windows.1"
    Fetch "https://github.com/git-for-windows/git/releases/download/$gitTag/PortableGit-$GitVer-64-bit.7z.exe" $gitOut
    Ok "portable-git.7z.exe ($GitVer)"
} else { Write-Host "[跳过] portable-git.7z.exe 已存在" }

# ---------- 5. ripgrep / ffmpeg（成品二进制） ----------
$rgOut = Join-Path $Assets "rg.exe"
if (-not (Test-Path $rgOut)) {
    $rgZip = Join-Path $Work "rg.zip"
    Fetch "https://github.com/BurntSushi/ripgrep/releases/download/$RipgrepVer/ripgrep-$RipgrepVer-x86_64-pc-windows-msvc.zip" $rgZip
    if (Test-Path "$Work\rg") { Remove-Item -Recurse -Force "$Work\rg" }
    New-Item -ItemType Directory -Force -Path "$Work\rg" | Out-Null
    ExtractTar $rgZip "$Work\rg"
    $rgFound = Get-ChildItem "$Work\rg" -Recurse -Filter "rg.exe" | Select-Object -First 1
    if (-not $rgFound) { throw "rg.zip 里没找到 rg.exe" }
    Copy-Item $rgFound.FullName $rgOut -Force
    Ok "rg.exe"
} else { Write-Host "[跳过] rg.exe 已存在" }

$ffOut = Join-Path $Assets "ffmpeg.exe"
if (-not (Test-Path $ffOut)) {
    $ffZip = Join-Path $Work "ffmpeg.zip"
    Fetch "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" $ffZip
    if (Test-Path "$Work\ff") { Remove-Item -Recurse -Force "$Work\ff" }
    New-Item -ItemType Directory -Force -Path "$Work\ff" | Out-Null
    ExtractTar $ffZip "$Work\ff"
    $ffFound = Get-ChildItem "$Work\ff" -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    $fpFound = Get-ChildItem "$Work\ff" -Recurse -Filter "ffprobe.exe" | Select-Object -First 1
    if (-not $ffFound) { throw "ffmpeg.zip 里没找到 ffmpeg.exe" }
    Copy-Item $ffFound.FullName $ffOut -Force
    if ($fpFound) { Copy-Item $fpFound.FullName (Join-Path $Assets "ffprobe.exe") -Force }
    Ok "ffmpeg.exe / ffprobe.exe"
} else { Write-Host "[跳过] ffmpeg.exe 已存在" }

# ---------- 6. 上游仓库（源码树含 .git 的 zip + 离线 fetch 用 bundle） ----------
$repoZip = Join-Path $Assets "hermes-agent.zip"
$repoDir = Join-Path $Work "repo"
if (-not (Test-Path $repoZip)) {
    if (Test-Path $repoDir) { Remove-Item -Recurse -Force $repoDir }
    $tryUrls = @($RepoUrl, "https://ghproxy.net/$RepoUrl")   # 直连 429/超时自动换 ghproxy 镜像
    $cloned = $false
    foreach ($u in $tryUrls) {
        Write-Host "[clone] $u ($Tag)"
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { & git clone --depth 1 --branch $Tag $u $repoDir 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
        if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $repoDir ".git"))) { $cloned = $true; break }
        if (Test-Path $repoDir) { Remove-Item -Recurse -Force $repoDir -ErrorAction SilentlyContinue }
        Write-Host "[重试] 该源失败（exit $LASTEXITCODE），换下一个源……"
    }
    if (-not $cloned) { throw "git clone 失败（含 ghproxy 镜像重试）。可等 3-5 分钟让 GitHub 限流冷却后重跑" }
    git -C $repoDir bundle create (Join-Path $Assets "hermes-agent.bundle") --all
    if ($LASTEXITCODE -ne 0) { throw "git bundle 失败" }
    tar -acf $repoZip -C $repoDir .
    Ok "hermes-agent.zip + bundle"
} else { Write-Host "[跳过] hermes-agent.zip 已存在" }

# ---------- 7. uv cache 预热（与上游安装命令完全一致：uv sync --extra all --locked） ----------
$uvCache = Join-Path $Assets "uv-cache"
if (-not $SkipUvCache) {
    if (-not (Test-Path $uvCache)) {
        if (-not (Test-Path $repoDir)) { throw "repo 不存在，无法预热 uv cache" }
        $env:UV_CACHE_DIR = $uvCache
        $env:UV_PROJECT_ENVIRONMENT = Join-Path $Work "venv"
        $env:UV_PYTHON_INSTALL_MIRROR = "https://registry.npmmirror.com/-/binary/python-build-standalone"
        Write-Host "[预热] uv sync --extra all --locked（首次约 3-10 分钟）……"
        Push-Location $repoDir
        & $uvExe sync --extra all --locked
        $code = $LASTEXITCODE
        Pop-Location
        if ($code -ne 0) { throw "uv sync 预热失败（exit $code）" }
        Ok "uv-cache 预热完成"
    } else { Write-Host "[跳过] uv-cache 已存在" }
}

# ---------- 8. npm cache 预热（npm ci + camofox；--ignore-scripts 防浏览器下载） ----------
$npmCache = Join-Path $Assets "npm-cache"
if (-not $SkipNpmCache) {
    if (-not (Test-Path $npmCache)) {
        $npm = Join-Path $nodeWork "npm.cmd"
        if (-not (Test-Path $npm)) { throw "自举 node 里没有 npm.cmd" }
        $env:npm_config_cache = $npmCache
        Push-Location $repoDir
        Write-Host "[预热] npm ci --ignore-scripts（首次约 3-8 分钟）……"
        & $npm ci --ignore-scripts
        if ($LASTEXITCODE -ne 0) { Pop-Location; throw "npm ci 预热失败" }
        Write-Host "[预热] npm cache add camofox……"
        & $npm install -g --prefix (Join-Path $Work "globalpkg") --ignore-scripts "@askjo/camofox-browser@^1.5.2"
        Pop-Location
        if ($LASTEXITCODE -ne 0) { throw "camofox cache 预热失败" }
        Ok "npm-cache 预热完成"
    } else { Write-Host "[跳过] npm-cache 已存在" }
}

# ---------- 9. THIRD-PARTY-NOTICES ----------
@(
"HerMemory 离线发行包 — 第三方软件声明与许可",
"===========================================================",
"本发行包内含以下第三方软件的二进制/源码，均按其原许可再分发。",
"各组件的完整许可文本与源码出处如下（保留所有版权声明）。",
"",
"1. Hermes Agent（hermes-agent 源码树）",
"   版权 (c) 2025 Nous Research。许可证：MIT License（随附于仓库内 LICENSE 文件）。",
"   源码：https://github.com/NousResearch/hermes-agent (tag $Tag)",
"",
"2. CPython 3.11 运行时（python-build-standalone 发行物）",
"   Python Software Foundation 许可证（PSF-2.0）；构建工具 MIT (astral-sh)。",
"   源码：https://github.com/astral-sh/python-build-standalone",
"",
"3. Node.js 与 npm",
"   Node.js：MIT License。npm：Artistic License 2.0。",
"   源码：https://github.com/nodejs/node",
"",
"4. Git for Windows（PortableGit）",
"   许可证：GNU GPL v2。源码：https://github.com/git-for-windows/git",
"   依据 GPL v2 随包分发二进制；源码可由上述官方仓库获取。",
"",
"5. ripgrep",
"   许可证：MIT OR Unlicense。源码：https://github.com/BurntSushi/ripgrep",
"",
"6. FFmpeg（gyan.dev essentials 构建）",
"   许可证：GNU GPL v3（该构建启用 GPL 组件）。源码：https://ffmpeg.org/download.html",
"   依据 GPL v3 随包分发二进制；源码可由上述官方渠道获取。",
"",
"7. uv",
"   许可证：MIT OR Apache-2.0。源码：https://github.com/astral-sh/uv",
"",
"8. Python / npm 依赖包",
"   以 uv.lock / package-lock.json 精确锁定的第三方库随缓存分发，",
"   各自许可（MIT/Apache/BSD/PSF 等）随包内元数据（*.dist-info/LICENSE 等）保留。",
"",
"HerMemory 本体：MIT License，Copyright (c) Prom1seCN。https://github.com/Prom1seCN/HerMemory"
) | Set-Content -Path (Join-Path $Assets "THIRD-PARTY-NOTICES.txt") -Encoding UTF8
Ok "THIRD-PARTY-NOTICES.txt"

# ---------- 10. manifest（清单 + 哈希）+ 打包 ----------
$files = Get-ChildItem $Assets -Recurse -File
$manifest = [ordered]@{
    tag = $Tag
    generated = (Get-Date).ToUniversalTime().ToString("o")
    includesBrowser = $false
    files = @($files | ForEach-Object {
        [ordered]@{ name = $_.FullName.Substring($Assets.Length + 1).Replace('\', '/'); bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash }
    })
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $Assets "manifest.json") -Encoding UTF8

$zipOut = Join-Path $OutDir "assets-offline.zip"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
# 必须用标准 zip 写入器（central directory 完整）——2026-09-10 VM 实录：
# 旧写法 `tar -acf out.zip -C $OutDir assets-offline` 走 bsdtar 的 zip writer，
# 打包机能解、VM 的 tar -xf 却只读到空归档（退出码依旧 0，manifest.json 不出现），
# 表现为"离线包在场但解不出来"→ 断言触发。教训：跨机器分发的归档不用 tar 写 zip。
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $Assets,
    $zipOut,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false   # 不写顶层 assets-offline/ 目录前缀：zip 内直接是清单文件，与 install.ps1 解压后布局一致
)
$sw.Stop()
$size = (Get-Item $zipOut).Length / 1MB
$assetsSize = ($files | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Ok ("离线资源包完成：{0}（解压态 {1:N0} MB → 压缩 {2:N0} MB，用时 {3:N0} 秒）" -f $zipOut, $assetsSize, $size, $sw.Elapsed.TotalSeconds)
Write-Host "下一步：dotnet publish -p:IncludeOfflineAssets=true 产出 HerMemory-offline.exe"
