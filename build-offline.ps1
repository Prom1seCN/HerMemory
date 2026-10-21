#requires -Version 5.1
<#
  HerMemory 随包素材构建（v0.22 架构：只产两件 + 两个戳）

  用法（打包机 = 有网络的 Windows；GitHub 走系统代理）：
    powershell -ExecutionPolicy Bypass -File build-offline.ps1 [-Tag v0.22.2] [-OutDir build\minimal]

  产出（默认 build\minimal\）：
    hermes-agent.bundle          上游 pin 工作树的 git bundle（快照仓库，约 83 MB）
    hermes-agent.commit          该 bundle 里 main 指向的 commit（install.ps1 用它做 -Commit 钉住）
    hermes-agent.upstream-commit 上游真实的 pin commit（审计用，不参与安装）
    uv.exe                       PM 的引导器（版本/哈希直接取自上游 pm/lock.json）
    uv.version                   uv 版本（install.ps1 用它算 PM store 槽位名）

  为什么是「快照仓库」而不是上游真仓库：
    上游 v0.22 的 Stage-Repository 只认真正的 git 仓库（clone --filter=blob:none --branch main，
    并用 merge-base 校验 -Commit 属于 origin/main）。而：
      · 浅克隆（--depth 1）打出的 bundle **无法被克隆**（父提交不在包里，git 报
        "Failed to traverse parents"）——bundle 不携带 shallow 信息；
      · 完整历史实测 1.1 GB（54,454 个提交），随包不现实。
    所以把 pin 的工作树重新做成一个**单提交仓库**（树字节与 pin 完全一致、带 vX.Y.Z tag），
    用 `* -text` 关掉行尾转换以保证字节不变，再打包。安装时 -Commit 指向这个合成提交，
    `git describe --tags` 仍是 v0.22.2，版本号显示正确；代价是 commit sha 与上游不同
    （安装戳与 `hermes --version` 末尾会显示合成 sha，属已知取舍）。

  其余重依赖（CPython 3.14 / Node 26 / Chromium / PyPI 依赖）安装时由 PM 从官方 sha256
  镜像（hermes-assets.nousresearch.com）与国内索引取。
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

$Bundle    = Join-Path $Out "hermes-agent.bundle"
$CommitTxt = Join-Path $Out "hermes-agent.commit"
$UpTxt     = Join-Path $Out "hermes-agent.upstream-commit"
$Src = Join-Path $Work "pin-src"

# ---------- 1. 取上游 pin 工作树 ----------
Step "1/5 获取上游 pin 工作树（$Tag）"
if ((Test-Path $Bundle) -and (Test-Path $CommitTxt) -and -not $Force) {
    Ok "已存在，跳过：$Bundle（要重建加 -Force）"
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail "需要 git（PATH 里没有）" }
    if (Test-Path $Src) { Remove-Item $Src -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "[clone] $RepoUrl ($Tag)"
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & git clone --depth 1 --branch $Tag $RepoUrl $Src 2>&1 | Out-String | Write-Host } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Src ".git"))) { Fail "git clone 失败（网络/GitHub 限流？换时间或挂代理重试）" }

    $upstreamCommit = (& git -C $Src rev-parse HEAD).Trim()
    Write-Host "upstream pin: $upstreamCommit"
    if (-not (Test-Path (Join-Path $Src "pm\lock.json"))) { Fail "工作树里没有 pm\lock.json —— 这不是 v0.22+ 的树，检查 -Tag" }
    if (-not (Test-Path (Join-Path $Src "pyproject.toml"))) { Fail "工作树里没有 pyproject.toml" }

    # ---------- 2. 重做成快照仓库（单提交 + tag） ----------
    Step "2/5 重建为快照仓库"
    Remove-Item (Join-Path $Src ".git") -Recurse -Force
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        & git -C $Src init -q -b main 2>&1 | Out-String | Write-Host
        # 关掉一切行尾/编码转换：随包树必须与 pin 的 checkout 字节完全一致
        & git -C $Src config core.autocrlf false 2>&1 | Out-Null
        & git -C $Src config core.safecrlf false 2>&1 | Out-Null
        Set-Content -Path (Join-Path $Src ".git\info\attributes") -Value "* -text`n" -Encoding ASCII
        & git -C $Src -c user.name="HerMemory Release" -c user.email="noreply@hermemory.local" add -A 2>&1 | Out-String | Write-Host
        if ($LASTEXITCODE -ne 0) { Fail "git add 失败" }
        & git -C $Src -c user.name="HerMemory Release" -c user.email="noreply@hermemory.local" `
            commit -q -m "Hermes Agent $Tag (source snapshot; tree identical to upstream $upstreamCommit)" 2>&1 | Out-String | Write-Host
        if ($LASTEXITCODE -ne 0) { Fail "git commit 失败" }
        & git -C $Src -c user.name="HerMemory Release" -c user.email="noreply@hermemory.local" `
            tag -a $Tag -m "Hermes Agent $Tag" 2>&1 | Out-String | Write-Host
        if ($LASTEXITCODE -ne 0) { Fail "git tag 失败" }
    } finally { $ErrorActionPreference = $prev }

    $snapshotCommit = (& git -C $Src rev-parse HEAD).Trim()
    Write-Host "snapshot commit: $snapshotCommit"

    # ---------- 3. 打 bundle 并做克隆冒烟测试 ----------
    Step "3/5 打 bundle + 克隆冒烟测试"
    if (Test-Path $Bundle) { Remove-Item $Bundle -Force }
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & git -C $Src bundle create $Bundle main "refs/tags/$Tag" 2>&1 | Out-String | Write-Host } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Bundle)) { Fail "git bundle create 失败" }

    $heads = (& git bundle list-heads $Bundle) -join "`n"
    if ($heads -notmatch "refs/heads/main") { Fail "bundle 缺 refs/heads/main —— 上游 clone --branch main 会直接失败" }
    if ($heads -notmatch [regex]::Escape("refs/tags/$Tag")) { Fail "bundle 缺 refs/tags/$Tag" }

    # 冒烟：用上游完全相同的参数真实克隆一次。浅克隆打包 / 缺对象等问题都在这里暴露，
    # 而不是等到用户装到一半。
    $smoke = Join-Path $Work "smoke-clone"
    if (Test-Path $smoke) { Remove-Item $smoke -Recurse -Force -ErrorAction SilentlyContinue }
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { & git clone --filter=blob:none --branch main $Bundle $smoke 2>&1 | Out-String | Write-Host } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $smoke ".git"))) {
        Fail "bundle 无法用上游参数克隆（这一定会让安装失败）——检查是否又用了浅克隆"
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & git -C $smoke merge-base --is-ancestor $snapshotCommit origin/main 2>&1 | Out-Null
    $ancestorOk = ($LASTEXITCODE -eq 0)
    $describe = (& git -C $smoke describe --tags 2>$null) -join ""
    $ErrorActionPreference = $prev
    if (-not $ancestorOk) { Fail "快照 commit 不是 origin/main 的祖先 —— 上游的 pin 校验会失败" }
    if ($describe -notmatch [regex]::Escape($Tag)) { Fail "克隆后 git describe 不是 $Tag（实际：$describe）" }
    Remove-Item $smoke -Recurse -Force -ErrorAction SilentlyContinue
    Ok "bundle 校验通过（main = $($snapshotCommit.Substring(0,12))，describe=$describe）"

    Set-Content -Path $CommitTxt -Value $snapshotCommit -Encoding ASCII -NoNewline
    Set-Content -Path $UpTxt -Value $upstreamCommit -Encoding ASCII -NoNewline
}

# ---------- 4. uv（版本与哈希取上游 pm/lock.json，不手抄） ----------
Step "4/5 取 uv 引导器"
$UvExe = Join-Path $Out "uv.exe"
$UvVerFile = Join-Path $Out "uv.version"
if ((Test-Path $UvExe) -and -not (Test-Path $UvVerFile)) {
    # 旧产物没有版本戳：删掉重取，避免槽位名与 exe 不一致
    Remove-Item $UvExe -Force -ErrorAction SilentlyContinue
}
if ((Test-Path $UvExe) -and -not $Force) {
    Ok "已存在，跳过 uv 获取：$UvExe（要重建加 -Force）"
} else {
    $lockPath = Join-Path $Src "pm\lock.json"
    if (-not (Test-Path $lockPath)) { Fail "读不到上游 pm\lock.json（源码没取到？用 -Force 重跑）" }
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

    Set-Content -Path $UvVerFile -Value $uvVer -Encoding ASCII -NoNewline
    $verOut = (& $UvExe --version) -join ""
    if ($verOut -notmatch [regex]::Escape($uvVer)) { Fail "uv 版本不符：期望 $uvVer，实际 $verOut" }
    Ok "uv $uvVer 就绪"
}

# ---------- 5. 汇总 ----------
Step "5/5 汇总"
$items = Get-ChildItem $Out -File | Sort-Object Name
foreach ($f in $items) {
    Write-Host ("  {0,-30} {1,10:N1} MB" -f $f.Name, ($f.Length / 1MB))
}
$total = ($items | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Ok ("随包素材完成：{0}（合计 {1:N1} MB）" -f $Out, $total)
Write-Host "下一步：build-release.ps1 出包（程序本体 + 安装器）"
