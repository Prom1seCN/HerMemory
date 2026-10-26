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
    artifacts\<sha256>           运行时大件（git / python / node），按哈希命名；
                                 install.ps1 会把它们预置进 PM 下载缓存，安装时免下载
    python.json                  随包 CPython 的元数据（版本 / sha256 / uv 受管目录名）：
                                 install.ps1 靠它把 Python 解压成「已安装」布局，
                                 引导阶段因此不需要联网（2026-10-26 死代理事故的修复）

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
    [switch]$Force,
    # 缺运行时大件时默认**直接失败**：少一件就意味着安装时退回联网下载，
    # 而这正是国内首装失败的头号原因。开发机确实没有网络时才用它降级为警告。
    [switch]$AllowMissingArtifacts
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
function Warn([string]$m) { Write-Host "[注意] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "[错误] $m" -ForegroundColor Red; exit 1 }

$Bundle    = Join-Path $Out "hermes-agent.bundle"
$CommitTxt = Join-Path $Out "hermes-agent.commit"
$UpTxt     = Join-Path $Out "hermes-agent.upstream-commit"
$Src = Join-Path $Work "pin-src"

# ---------- 1. 取上游 pin 工作树 ----------
Step "1/6 获取上游 pin 工作树（$Tag）"
if ((Test-Path $Bundle) -and (Test-Path $CommitTxt) -and -not $Force) {
    Ok "已存在，跳过：$Bundle（要重建加 -Force）"
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail "需要 git（PATH 里没有）" }
    if (Test-Path $Src) { Remove-Item $Src -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host "[clone] $RepoUrl ($Tag)"
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    # 关掉行尾转换再 clone：Windows 上 core.autocrlf=true 会把文本文件检出成 CRLF，
    # 快照树就与上游 tag 不再逐字节一致（activate 这类无扩展名的脚本会带 CRLF）。
    try { & git -c core.autocrlf=false -c core.eol=lf clone --depth 1 --branch $Tag $RepoUrl $Src 2>&1 | Out-String | Write-Host } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Src ".git"))) { Fail "git clone 失败（网络/GitHub 限流？换时间或挂代理重试）" }

    $upstreamCommit = (& git -C $Src rev-parse HEAD).Trim()
    Write-Host "upstream pin: $upstreamCommit"
    if (-not (Test-Path (Join-Path $Src "pm\lock.json"))) { Fail "工作树里没有 pm\lock.json —— 这不是 v0.22+ 的树，检查 -Tag" }
    if (-not (Test-Path (Join-Path $Src "pyproject.toml"))) { Fail "工作树里没有 pyproject.toml" }

    # ---------- 2. 重做成快照仓库（单提交 + tag） ----------
    Step "2/6 重建为快照仓库"
    # 记下上游受控文件清单：重建后必须一个不少。有些文件上游仍在跟踪、却已写进自己的
    # .gitignore（web/public/fonts、website/src/data、hello-runtime 的 js），普通 `git add -A`
    # 会把它们当忽略项丢掉 —— 快照树就不再等于 pin 的树了。
    $trackedBefore = @(& git -C $Src ls-files)
    if ($trackedBefore.Count -lt 1000) { Fail "上游工作树文件数异常（$($trackedBefore.Count)），clone 可能不完整" }
    Remove-Item (Join-Path $Src ".git") -Recurse -Force
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        & git -C $Src init -q -b main 2>&1 | Out-String | Write-Host
        # 关掉一切行尾/编码转换：随包树必须与 pin 的 checkout 字节完全一致
        & git -C $Src config core.autocrlf false 2>&1 | Out-Null
        & git -C $Src config core.safecrlf false 2>&1 | Out-Null
        Set-Content -Path (Join-Path $Src ".git\info\attributes") -Value "* -text`n" -Encoding ASCII
        # -f：强制把「上游跟踪、但 upstream .gitignore 恰好命中」的文件也收进来
        & git -C $Src -c user.name="HerMemory Release" -c user.email="noreply@hermemory.local" add -A -f 2>&1 | Out-String | Write-Host
        if ($LASTEXITCODE -ne 0) { Fail "git add 失败" }
        & git -C $Src -c user.name="HerMemory Release" -c user.email="noreply@hermemory.local" `
            commit -q -m "Hermes Agent $Tag (source snapshot; tree identical to upstream $upstreamCommit)" 2>&1 | Out-String | Write-Host
        if ($LASTEXITCODE -ne 0) { Fail "git commit 失败" }
        & git -C $Src -c user.name="HerMemory Release" -c user.email="noreply@hermemory.local" `
            tag -a $Tag -m "Hermes Agent $Tag" 2>&1 | Out-String | Write-Host
        if ($LASTEXITCODE -ne 0) { Fail "git tag 失败" }
    } finally { $ErrorActionPreference = $prev }

    $trackedAfter = @(& git -C $Src ls-files)
    $missing = @($trackedBefore | Where-Object { $trackedAfter -notcontains $_ })
    if ($missing.Count -gt 0) {
        Fail ("快照比上游少 {0} 个受控文件，拒绝产出：`n  {1}" -f $missing.Count, (($missing | Select-Object -First 10) -join "`n  "))
    }
    Write-Host "快照文件数：$($trackedAfter.Count)（与上游受控文件一致）"

    $snapshotCommit = (& git -C $Src rev-parse HEAD).Trim()
    Write-Host "snapshot commit: $snapshotCommit"

    # ---------- 3. 打 bundle 并做克隆冒烟测试 ----------
    Step "3/6 打 bundle + 克隆冒烟测试"
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
Step "4/6 取 uv 引导器"
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

# ---------- 5. 运行时大件（git / python / node，按 sha256 命名） ----------
# 为什么随包：PM 装依赖时要下载这三个（合计约 149 MB）。境内直连 GitHub / 官方源
# 实测只有 200 KB/s，首装会长时间卡在 "installing git"，用户以为程序坏了。
# 把文件按 lock 里的 sha256 命名放进 artifacts\，install.ps1 会预置进 PM 缓存，
# PM 校验哈希后直接使用（缓存命中 0.12 秒，实测）。
Step "5/6 采集运行时大件（git / python / node）"
$UvLock = Join-Path $Src "pm\lock.json"
$ArtDir = Join-Path $Out "artifacts"
if (-not (Test-Path $UvLock)) {
    Warn "读不到 pm\lock.json，跳过运行时大件采集（安装时将联网下载）。"
} else {
    $lock = Get-Content $UvLock -Raw -Encoding UTF8 | ConvertFrom-Json
    $want = @()
    foreach ($name in @('git', 'python', 'node')) {
        $pkg = $lock.packages.$name
        if (-not $pkg) { continue }
        $art = $pkg.artifacts.'win32-x64'
        if (-not $art -or -not $art.url -or -not $art.sha256) { continue }
        $want += [pscustomobject]@{ Name = $name; Url = $art.url; Sha = "$($art.sha256)".ToLower() }
    }
    if ($want.Count -eq 0) {
        Warn "pm\lock.json 里没有 win32-x64 的 git/python/node 制品，跳过大件采集。"
    } else {
        New-Item -ItemType Directory -Force -Path $ArtDir | Out-Null
        foreach ($w in $want) {
            $dst = Join-Path $ArtDir $w.Sha
            if ((Test-Path $dst) -and -not $Force) {
                $have = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
                if ($have -eq $w.Sha) {
                    Write-Host ("  已有 {0}（{1:N1} MB）" -f $w.Name, ((Get-Item $dst).Length / 1MB)) -ForegroundColor Green
                    continue
                }
                Warn "$($w.Name) 的随包文件哈希不符，重新下载。"
                Remove-Item $dst -Force -ErrorAction SilentlyContinue
            }
            Write-Host "[download] $($w.Name)  $($w.Url)"
            $tmp = Join-Path $Work ($w.Name + ".download")
            try {
                Invoke-WebRequest -Uri $w.Url -OutFile $tmp -UseBasicParsing
            } catch {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                if ($AllowMissingArtifacts) {
                    Warn "$($w.Name) 下载失败（$($_.Exception.Message)）；安装时将联网下载。"
                    continue
                }
                Fail ("$($w.Name) 下载失败（$($_.Exception.Message)）。" +
                      [Environment]::NewLine + "随包缺这一件，安装时就退回联网下载——国内首装失败基本都是这一步。" +
                      [Environment]::NewLine + "确认网络/代理后重跑；确实要出「联网版」安装器才加 -AllowMissingArtifacts。")
            }
            $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $w.Sha) {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                Fail "$($w.Name) 下载内容哈希不符：期望 $($w.Sha)，实际 $actual（随包文件必须与 lock 一致）"
            }
            Move-Item -LiteralPath $tmp -Destination $dst -Force
            Write-Host ("  -> {0}（{1:N1} MB）" -f $w.Name, ((Get-Item $dst).Length / 1MB)) -ForegroundColor Green
        }

        # python.json：install.ps1 据此把随包 CPython 解压成 uv 的「已安装」布局
        # （<UV_PYTHON_INSTALL_DIR>\cpython-<ver>-windows-x86_64-none\python.exe），
        # 引导阶段因此零下载——这是 2026-10-26「死代理导致首装失败」事故的修复。
        # 顺手做归档自检：半截文件、被替换成 HTML 错误页的下载都能在这里被拦住。
        $pyPin = $lock.packages.python
        $pyEntry = $want | Where-Object { $_.Name -eq 'python' } | Select-Object -First 1
        if ($pyPin -and $pyEntry) {
            $pyDst = Join-Path $ArtDir $pyEntry.Sha
            if (-not (Test-Path -LiteralPath $pyDst)) { Fail "缺随包 CPython：$pyDst（引导阶段会退化为联网下载）" }
            $pyHave = (Get-FileHash -LiteralPath $pyDst -Algorithm SHA256).Hash.ToLower()
            if ($pyHave -ne $pyEntry.Sha) { Fail "随包 CPython 哈希不符：期望 $($pyEntry.Sha)，实际 $pyHave" }
            $pyBase = ("$($pyPin.version)" -split '\+')[0]
            if ($pyBase -notmatch '^\d+\.\d+\.\d+$') { Fail "pm\lock.json 的 python 版本号看不懂：$($pyPin.version)" }
            if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Fail "本机没有 tar.exe，无法自检 CPython 归档（Windows 10 1803+ 自带）" }
            $pyList = @(& tar.exe -tzf $pyDst 2>$null)
            if (-not ($pyList -match '^python[/\\]python\.exe$')) {
                Fail "随包 CPython 归档里没有 python/python.exe（文件可能损坏或被替换）"
            }
            $pyMeta = [ordered]@{
                version = $pyBase
                sha256  = $pyEntry.Sha
                dir     = "cpython-$pyBase-windows-x86_64-none"
                source  = "$($pyPin.version)"
                url     = "$($pyEntry.Url)"
            }
            $pyJsonPath = Join-Path $Out "python.json"
            [IO.File]::WriteAllText($pyJsonPath, ($pyMeta | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
            Ok "python.json 已写出（CPython $pyBase，uv 目录名 cpython-$pyBase-windows-x86_64-none）"
        } else {
            Warn "pm/lock.json 里没有 python 制品，无法生成 python.json（引导阶段会联网下载）。"
        }
    }
}

# ---------- 6. 汇总 ----------
Step "6/6 汇总"
$items = Get-ChildItem $Out -File | Sort-Object Name
foreach ($f in $items) {
    Write-Host ("  {0,-30} {1,10:N1} MB" -f $f.Name, ($f.Length / 1MB))
}
$artFiles = @(Get-ChildItem (Join-Path $Out "artifacts") -File -ErrorAction SilentlyContinue)
if ($artFiles.Count -gt 0) {
    $artMb = ($artFiles | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("  {0,-30} {1,10:N1} MB" -f ("artifacts\ (" + $artFiles.Count + " 件)"), $artMb)
}
$total = ($items | Measure-Object Length -Sum).Sum / 1MB
if ($artFiles.Count -gt 0) { $total += $artMb }
Write-Host ""
Ok ("随包素材完成：{0}（合计 {1:N1} MB）" -f $Out, $total)
Write-Host "下一步：build-release.ps1 出包（程序本体 + 安装器）"
