#requires -Version 5.1
<#
  HerMemory 随包素材构建（v0.22 架构：只产两件）

  用法（打包机 = 有网络的 Windows；GitHub 走系统代理）：
    powershell -ExecutionPolicy Bypass -File build-offline.ps1 [-Tag v0.22.2] [-OutDir build\minimal]

  产出（默认 build\minimal\）：
    hermes-agent.bundle   上游源码的 git bundle：refs/heads/main 指向 pin commit，并带 pin tag
    uv.exe                PM 的引导器（版本/哈希直接取自上游 pm\lock.json，不手抄）
    uv.version            uv 的版本号（install.ps1 用它算 PM store 槽位名，保证与随包 exe 一致）

  为什么只剩这两件：上游 v0.22 把重依赖整体交给 PM（pm/lock.json 逐件 sha256 钉死）。
  Python 3.14 / Node 26 / Chromium / PyPI 依赖都在安装时由 PM 从官方 sha256 镜像
  （hermes-assets.nousresearch.com）与国内索引取，随包只需要「内核本身」和「引导 PM 的 uv」。
  旧的 assets-offline（1.2 GB）与 scripts\make-minimal-bundle.py 随之作废。

  为什么用 bundle 而不是源码 zip：上游 v0.22 的 Stage-Repository 只认真正的 git 仓库
  （clone --filter=blob:none --branch main，并校验 -Commit 是 origin/main 的祖先）。
  把 main 指到 pin 提交再打包，安装时 HERMES_REPO_URL 指向这个 bundle 即零网络落位。
#>
param(
    [string]$Tag = "v0.22.2",
    [string]$OutDir = "build\minimal",
    [string]$RepoUrl = "https://github.com/NousResearch/hermes-agent.git",
    [string]$WorkDir = "build\offline",
    [switch]$Force
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Root = $PSScriptRoot
$Out = Join-Path $Root $OutDir
$Work = Join-Path $Root $WorkDir
New-Item -ItemType Directory -Force -Path $Out, $Work | Out-Null

function Step([string]$n) { Write-Host ""; Write-Host "=== $n ===" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[完成] $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "[错误] $m" -ForegroundColor Red; exit 1 }

$Bundle = Join-Path $Out "hermes-agent.bundle"
$Src = Join-Path $Work "pin-src"

# ---------- 1/2. 取上游源码并打 bundle ----------
Step "1/4 获取上游源码并打 bundle（$Tag）"
if ((Test-Path $Bundle) -and -not $Force) {
    Ok "已存在，跳过：$Bundle（要重建加 -Force）"
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail "需要 git（PATH 里没有）" }
    if (Test-Path $Src) { Remove-Item $Src -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "[clone] $RepoUrl ($Tag)"
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & git clone --depth 1 --branch $Tag $RepoUrl $Src 2>&1 | Out-String | Write-Host } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Src ".git"))) { Fail "git clone 失败（网络/GitHub 限流？换时间或挂代理重试）" }

    Step "2/4 打包 git bundle"
    # 浅克隆 + --branch <tag> 是分离 HEAD，仓库里没有分支引用。上游 Stage-Repository 要
    # `git clone --branch main`，并用 merge-base 校验 pin 属于 origin/main，所以显式造 main。
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & git -C $Src branch -f main HEAD 2>&1 | Out-String | Write-Host } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { Fail "git branch -f main HEAD 失败（bundle 会缺 refs/heads/main）" }

    $pinSha = (& git -C $Src rev-parse HEAD).Trim()
    Write-Host "pin commit: $pinSha"

    if (Test-Path $Bundle) { Remove-Item $Bundle -Force }
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & git -C $Src bundle create $Bundle main --tags 2>&1 | Out-String | Write-Host } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Bundle)) { Fail "git bundle create 失败" }

    # 引用校验：少了 main 安装时必失败；少了 tag 则 pin 不可审计
    $heads = (& git bundle list-heads $Bundle) -join "`n"
    if ($heads -notmatch "refs/heads/main") { Fail "bundle 缺 refs/heads/main —— 上游 clone --branch main 会直接失败" }
    if ($heads -notmatch [regex]::Escape("refs/tags/$Tag")) { Fail "bundle 缺 refs/tags/$Tag" }
    Ok ("bundle 引用校验通过（main + $Tag，pin $($pinSha.Substring(0,12))）")

    # 给发布者一个可核对的 pin 摘要（不进包，只留作构建台账）
    @{ tag = $Tag; commit = $pinSha; created = (Get-Date).ToUniversalTime().ToString("o") } |
        ConvertTo-Json | Set-Content (Join-Path $Work "pin.json") -Encoding UTF8
}

# ---------- 3. uv（版本与哈希取上游 pm/lock.json，不手抄） ----------
Step "3/4 取 uv 引导器"
$UvExe = Join-Path $Out "uv.exe"
$UvVerFile = Join-Path $Out "uv.version"
if ((Test-Path $UvExe) -and -not $Force) {
    Ok "已存在，跳过 uv 获取：$UvExe（要重建加 -Force）"
} else {
    $lockPath = Join-Path $Src "pm\lock.json"
    if (-not (Test-Path $lockPath)) { Fail "读不到上游 pm\lock.json（源码没取到？）" }
    $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $uvPin = $lock.packages.uv
    $art = $uvPin.artifacts.'win32-x64'
    if (-not $art -or -not $art.url) { Fail "pm\lock.json 里没有 uv 的 win32-x64 制品" }
    $uvVer = "$($uvPin.version)"
    Write-Host "uv pin: $uvVer"
    Write-Host "[download] $($art.url)"

    $tmpZip = Join-Path $Work "uv.zip"
    $tmpDir = Join-Path $Work "uv-unpack"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    Invoke-WebRequest -Uri $art.url -OutFile $tmpZip -UseBasicParsing
    if (-not (Test-Path $tmpZip)) { Fail "uv 下载失败" }

    # 哈希必须对上：随包分发的可执行文件不能只靠「下载成功」
    if ($art.sha256) {
        $actual = (Get-FileHash $tmpZip -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne "$($art.sha256)".ToLower()) { Fail "uv 哈希不符：期望 $($art.sha256)，实际 $actual" }
        Ok "uv 哈希校验通过"
    }

    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $found = Get-ChildItem $tmpDir -Recurse -Filter "uv.exe" | Select-Object -First 1
    if (-not $found) { Fail "uv.zip 里没有 uv.exe" }
    Copy-Item $found.FullName $UvExe -Force
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    # 版本戳：install.ps1 用它算 PM store 槽位（uv-<版本>-win32-x64），必须与 exe 本身一致
    Set-Content -Path $UvVerFile -Value $uvVer -Encoding ASCII -NoNewline
    $verOut = (& $UvExe --version) -join ""
    if ($verOut -notmatch [regex]::Escape($uvVer)) { Fail "uv 版本不符：期望 $uvVer，实际 $verOut" }
    Ok "uv $uvVer 就绪"
}

# ---------- 4. 汇总 ----------
Step "4/4 汇总"
$items = Get-ChildItem $Out -File | Sort-Object Name
foreach ($f in $items) {
    Write-Host ("  {0,-26} {1,10:N1} MB" -f $f.Name, ($f.Length / 1MB))
}
$total = ($items | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Ok ("随包素材完成：{0}（合计 {1:N1} MB）" -f $Out, $total)
Write-Host "下一步：build-release.ps1 出包（程序本体 + 安装器）"
