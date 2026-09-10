# ============================================================
# HerMemory installer (Windows native) — v0.1.0
# 基于 Hermes Agent v0.21.0 (tag v2026.8.31)，MIT。
# 上游官方 PowerShell 安装器负责内核（自取 pin tag + uv + Python + Node + PortableGit + venv + CLI），
# 本脚本只做发行版的铺设：vault + 四文件 + 软链 + 皮肤 + 配置键 + docs。
# 对应 Linux 侧的 install.sh；上游怎么装，Windows 就怎么装。
#
# 运行：PowerShell 中  powershell -ExecutionPolicy Bypass -File install.ps1
# 前置：无需预装任何工具（git/Python/Node 由上游官方安装器自动便携化安装）。软链需要管理员权限或开发者模式。
# ============================================================
param(
    [string]$Tag = "v2026.8.31",
    [switch]$SkipUpstream,
    [string]$AnswersFile
)

# 控制台代码页自愈：系统全局 UTF-8（CP65001）下 PS5.1 会双写中文——无论从 bat 还是直接跑本脚本，先归位 GBK
try { & chcp.com 936 2>$null | Out-Null } catch {}

# ANSI 自愈（真解）：VT 控制台模式按句柄生效、子进程不继承，hermes 的彩色码在老 conhost 上必裸奔。
# hermes 原生支持 no-color.org 标准——直接关掉它的颜色输出，任何控制台都干净（仅本安装进程内生效，不影响装好的系统）。
$env:NO_COLOR = "1"

$ErrorActionPreference = "Stop"
# 境内服务商普遍要求 TLS 1.2+；Windows 自带 PS 5.1 默认协商老协议，不强制会连不上
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$HermesHome = $env:HERMES_HOME; if (-not $HermesHome) { $HermesHome = "$env:LOCALAPPDATA\hermes" }
$UpstreamRepo = "https://github.com/NousResearch/hermes-agent.git"
$WebDavPort = 5005
$WebDavUser = "hermemory"
$SRC = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log([string]$m)  { Write-Host "[HerMemory] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[完成] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[note] $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }
# PS 5.1 坑：EAP=Stop 时原生命令 2>$null 会把 stderr 变成终止性错误（NativeCommandError）。
# Run-Quiet 在函数作用域内降级 EAP，stderr 静默流出——专用于允许失败的原生调用。
function Run-Quiet { $ErrorActionPreference = "Continue"; try { & $args 2>&1 | Out-Null } catch {} }

# ---------- 静默模式（exe 契约）：-AnswersFile 提供 JSON 答案，跳过全部交互 ----------
# JSON 字段：memoryTier(1/2/3/custom；custom 须伴随 customMem/customUser，各为 100-9999999 整数) / baseUrl / apiKey / model——均为必填。
# 与交互路径共用同一套验证与落盘逻辑；区别仅在：验证失败即 Die（重试界面由 exe 负责），微信扫码由 exe 接管。
# 安全语义：key 明文经 JSON 短暂落盘，exe 在安装成功后负责删除。
$Answers = $null
if ($AnswersFile) {
    if (-not (Test-Path $AnswersFile)) { Die "AnswersFile 不存在：$AnswersFile" }
    try { $Answers = Get-Content $AnswersFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Die "AnswersFile 不是有效 JSON：$($_.Exception.Message)" }
    foreach ($k in @("memoryTier", "baseUrl", "apiKey", "model")) {
        if (-not $Answers.$k) { Die "AnswersFile 缺少必填字段：$k" }
    }
    # 与交互路径同款净化：只保留可见 ASCII
    $Answers.baseUrl = (($Answers.baseUrl -replace "[^\x21-\x7E]", "")).TrimEnd("/")
    $Answers.apiKey  = ($Answers.apiKey  -replace "[^\x21-\x7E]", "")
    $Answers.model   = ($Answers.model   -replace "[^\x21-\x7E]", "")
    if (-not $Answers.baseUrl -or -not $Answers.apiKey -or -not $Answers.model) { Die "AnswersFile 字段净化后为空（含非 ASCII 污染？）" }
    Log "静默模式：答案来自 $AnswersFile"
}
# exe 进度契约：机器可读标记行（exe 逐行解析画进度条；交互模式下不输出）
function Progress([string]$step) { if ($Answers) { Write-Host "##HM-PROGRESS## $step" } }

# 启用终端 VT 序列（上游向导用 ANSI 着色；老式控制台默认关闭会显示成 [2m 原文）
try {
    $vt = Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);' -Name Win32VT -Namespace HerMemory -PassThru
    $h = $vt::GetStdHandle(-11)
    $m = [uint32]0
    if ($vt::GetConsoleMode($h, [ref]$m)) { $vt::SetConsoleMode($h, $m -bor 0x0004) | Out-Null }
} catch {}

# ---------- 断点续装（状态文件记录已完成步骤；删除它 = 全部重来） ----------
$StateFile = Join-Path $HermesHome "hermemory-install.state"

# ---------- 0. 离线模式检测（assets-offline.zip 由离线发行版 exe 内嵌，ExtractPayload 自动解出到本目录） ----------
$OfflineZip = Join-Path $PSScriptRoot "assets-offline.zip"
$OfflineDir = Join-Path $PSScriptRoot "assets-offline"
# zip 内布局历史包袱：早期 build-offline.ps1 用 `tar -acf` 打的是 `assets-offline/…`（带顶层目录），
# 后期改用 ZipFile::CreateFromDirectory 打平。两种布局都吃——解压后按 manifest.json 实际所在层确定根，不搬文件。
function Get-OfflineRoot([string]$dir) {
    if (Test-Path (Join-Path $dir "manifest.json")) { return $dir }
    $nested = Join-Path $dir "assets-offline"
    if (Test-Path (Join-Path $nested "manifest.json")) { return $nested }
    return $null
}
if (-not (Test-Path $OfflineZip) -and $PSScriptRoot -match '^(.*)\\[^\\]+$') {
    # 仓库模式直跑 install.sh 同级的 install.ps1 时，资源包在 build\offline\ 下
    $repoOffline = Join-Path ($Matches[1] + "\build\offline") "assets-offline.zip"
    if (Test-Path $repoOffline) { $OfflineZip = $repoOffline }
}
if ((Test-Path $OfflineZip) -and -not (Get-OfflineRoot $OfflineDir)) {
    Log "解压内嵌离线资源包（一次性，约 1GB，视磁盘速度需一两分钟）……"
    $drive = Get-PSDrive -Name ($OfflineDir.Substring(0, 1)) -ErrorAction SilentlyContinue
    if ($drive -and $drive.Free -lt 3GB) { Warn "磁盘剩余空间不足 3GB——解压可能失败（当前剩余 $([Math]::Round($drive.Free/1GB,1))GB）" }
    Remove-Item $OfflineDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $OfflineDir | Out-Null
    # 主路径：标准 zip 解压器（.NET，带 central directory 校验，任何 zip 都能解）。
    # 不用 tar：2026-09-10 实测 GNU tar 对 zip 直接 "This does not look like a tar archive" 且退出码为 0，
    # 静默解出空目录——正是"离线包在场却 manifest 缺失"的根因。
    # 重载选择：只用两参基础重载 ExtractToDirectory($zip, $dir)——.NET Framework 4.5 起即有，PS5.1/PS7 通吃。
    # 三参重载的第三参在 .NET Framework 是 entryNameEncoding(Encoding)、在 .NET Core 才是 OverwriteFiles 枚举，
    # 跨版本语义不一致（2026-09-10 VM 实录：传 $true 报 InvalidCast）。目标目录调用前已清空，无需覆盖语义。
    $ZIP_OK = $false
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($OfflineZip, $OfflineDir)
        $ZIP_OK = $true
    } catch {
        $zipErr = $_.Exception.Message
        if ($_.Exception.InnerException) { $zipErr += " <- $($_.Exception.InnerException.Message)" }
        Warn "标准 zip 解压失败（$zipErr）——尝试 tar 兜底……"
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        tar -xf $OfflineZip -C $OfflineDir 2>&1 | Out-Null
        $ErrorActionPreference = $prev
    }
    if (-not (Get-OfflineRoot $OfflineDir)) {
        Die "离线资源包解压失败（标准 zip 解压器与 tar 均未产出 manifest.json）——请检查磁盘剩余空间与杀软拦截后点击「重新安装」"
    }
    Ok "离线资源包就绪"
}
# 确定离线根目录：manifest 落在哪层，哪层就是根（嵌套布局自动适配，后续一律引用 $OfflineDir）
$_offRoot = Get-OfflineRoot $OfflineDir
if ($_offRoot) { $OfflineDir = $_offRoot }
$IsOffline = [bool]$_offRoot
# 离线性断言：exe 发行版把 assets-offline.zip 与 install.ps1 同目录投放，二者是一体的。
# zip 在场却解不出 manifest（解压失败/被杀软删文件/磁盘满）绝不能回落在线——那会让"无需联网"的承诺静默失效，
# 表现为 20 分钟后才在 Python 下载处报错（2026-09-10 沙盒实录）。此处即刻致命失败，让用户重新解压而不是等超时。
if (-not $IsOffline -and (Test-Path $OfflineZip)) {
    Die "离线资源包在场但未能就绪（$OfflineZip 未解出 manifest.json）——离线安装不能降级为在线。请确认磁盘剩余 ≥3GB 后点击「重新安装」重试解压。"
}
Log $(if ($IsOffline) { "模式：离线安装（全部资源内嵌，全程无需网络）" } else { "模式：在线安装（未检测到离线资源包，将走镜像下载）" })
New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null
function Test-Done([string]$step) { (Test-Path $StateFile) -and ((Get-Content $StateFile -ErrorAction SilentlyContinue) -contains $step) }
function Mark-Done([string]$step) { if (-not (Test-Done $step)) { Add-Content -Path $StateFile -Value $step } }
Log "安装状态文件：$StateFile（已完成的步骤在重新安装时自动跳过）"

# ---------- 0. 环境检查 ----------
if ($env:OS -ne "Windows_NT") { Die "本脚本仅用于 Windows 原生路径；Linux/macOS 用 install.sh" }
# git 不预检：上游官方安装器自带 Stage-Git 自动装 PortableGit（pin 版上游源码实证），装后 Git Bash 即就位
Log "可在 docs\INSTALL.md 查看安装说明"
Progress "precheck"

# ---------- 1. vault 位置（定名，不询问——路径被提示词与文档广泛引用，固定避免漂移） ----------
$VaultDir = "$HOME\vault"

# ---------- 2. 上游内核（官方安装器，pin tag；本脚本不自研内核安装） ----------
if (Test-Done "upstream") {
    Log "上游内核：已完成（自动跳过）"
# 判据必须含 hermes.exe：Windows 上官方安装器只产出 bin\hermes.exe，从不产出 hermes.cmd（本机实证）。
# 旧判据只看 .cmd，新 PowerShell 会话 PATH 尚未刷新时 Get-Command 也落空 → 会误判"未装"而重装一遍上游内核。
} elseif ((Test-Path (Join-Path $HermesHome "bin\hermes.exe")) -or (Test-Path (Join-Path $HermesHome "bin\hermes.cmd")) -or (Get-Command hermes -ErrorAction SilentlyContinue)) {
    Log "上游内核：检测到已安装，跳过"
    Mark-Done "upstream"
} else {
    if ($SkipUpstream) { Die "hermes CLI 不可用，且指定了 -SkipUpstream" }
    # GitHub 探活：多主机 GET + 重试；任何 HTTP 应答（含 403/404）即视为可达——单主机单次 HEAD 在代理/沙盒环境误报多。
    # PS5.1 的 Invoke-WebRequest 对非 2xx 也抛错，故 catch 里有 Response 对象 = 网络通。
    $ghOk = $false
    foreach ($probeUrl in @("https://github.com", "https://codeload.github.com", "https://objects.githubusercontent.com")) {
        foreach ($probeTry in 1..2) {
            try { Invoke-WebRequest -Uri $probeUrl -Method Get -TimeoutSec 12 -UseBasicParsing | Out-Null; $ghOk = $true }
            catch { if ($_.Exception.Response) { $ghOk = $true } }
            if ($ghOk) { break }
            Start-Sleep -Seconds 2
        }
        if ($ghOk) { break }
    }

    # PBS Python 运行时镜像——**无条件**首选 npmmirror，不依赖 GitHub 探测结果：
    # github.com 可通 ≠ objects.githubusercontent.com 可通（PBS 资产实际托管在后者、境内更易被断；
    # 沙盒实测：直连探测全过但 uv 拉 Python 3.11 死于此）。本机实证：uv 0.12.10 + npmmirror 装 cpython-3.11.16（24MB，5.4s）。
    # npmmirror 不可达时镜像链模式内再退加速器；两者皆不成立（海外/有代理）留空 = uv 默认 GitHub。
    $pbsSource = "default"
    if ($env:UV_PYTHON_INSTALL_MIRROR) {
        $pbsSource = "preset"
    } else {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try {
            Invoke-WebRequest -Uri "https://registry.npmmirror.com/-/binary/python-build-standalone/" -Method Get -TimeoutSec 10 -UseBasicParsing | Out-Null
            $env:UV_PYTHON_INSTALL_MIRROR = "https://registry.npmmirror.com/-/binary/python-build-standalone"
            $pbsSource = "npmmirror"
        } catch { }
        $ErrorActionPreference = $prevEAP
    }

    if (-not $ghOk) {
        # ---------- 境内镜像链模式 ----------
        # GitHub 裸 TLS 直连不通（境内常态：浏览器走 ECH/HTTP3 能进，原始客户端被 SNI-RST）。
        # 三个 GitHub 承载工件全部改走国内通道，预置后上游官方安装器按其幂等探测自动跳过对应下载
        #（上游 pin 版源码实证）：
        #   git   —— Install-Git：PATH 里有 git 即快速通道，不下载 PortableGit（L1432）
        #   内核  —— Install-Repository：已有有效仓库走 fetch+checkout，且 fetch 失败即 throw（L2201），
        #            所以 origin 必须保留加速器前缀；后续 hermes update 同通道，加速器失效可 remote set-url 改回直连
        #   Python—— uv 官方旋钮 UV_PYTHON_INSTALL_MIRROR（PBS 发行包也在 GitHub）
        #   uv    —— 预置到 %HERMES_HOME%\bin\uv.exe（上游对已存在的可用 uv 容忍断网，L800 注释实证）；失败不致命（astral.sh 境内通常可达）
        Log "GitHub 直连不通，切换境内镜像链模式……"

        # ①：PortableGit 预置（三源顺试：npmmirror → ghproxy.net → gh-proxy.com；版本随上游 pin v2.54.0.windows.1，上游升级 git pin 时同步此处）。
        # 沙盒四轮实证：npmmirror 会偶发不可达（上轮同一源可用），单源=单点；加速器直链下载不依赖 git，无鸡生蛋问题。
        # 下载失败透出内层 SocketException——DNS 解析失败与 TCP 拒连在红字里一眼可分。
        $gitDir = Join-Path $HermesHome "git"
        $gitExe = Join-Path $gitDir "cmd\git.exe"
        if (-not (Test-Path $gitExe)) {
            if (Get-Command git -ErrorAction SilentlyContinue) {
                Log "镜像链①：系统已有 git，跳过 PortableGit 预置"
            } else {
                $pgAsset = "PortableGit-2.54.0-64-bit.7z.exe"
                $pgRel = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/$pgAsset"
                $pgSources = @(
                    "https://registry.npmmirror.com/-/binary/git-for-windows/v2.54.0.windows.1/$pgAsset",
                    "https://ghproxy.net/$pgRel",
                    "https://gh-proxy.com/$pgRel"
                )
                $pgTmp = Join-Path $env:TEMP "hm-PortableGit.7z.exe"
                $pgOk = $false
                foreach ($pgSrc in $pgSources) {
                    Log "镜像链①：下载 PortableGit 2.54.0（约 65MB，源：$(([uri]$pgSrc).Host)）……"
                    try {
                        Invoke-WebRequest -Uri $pgSrc -OutFile $pgTmp -UseBasicParsing
                        $pgOk = $true; break
                    } catch {
                        $why = $_.Exception.Message
                        if ($_.Exception.InnerException) { $why += " <- $($_.Exception.InnerException.Message)" }
                        Warn "镜像链①：该源失败（$(([uri]$pgSrc).Host)）：$why"
                        Remove-Item $pgTmp -Force -ErrorAction SilentlyContinue
                    }
                }
                if (-not $pgOk) { Die "PortableGit 三源均不可达（npmmirror / ghproxy.net / gh-proxy.com）。若为 DNS 解析失败，请检查网络设置；或开一次代理后重跑（已完成步骤自动跳过）。" }
                New-Item -ItemType Directory -Force -Path $gitDir | Out-Null
                $sp = Start-Process -FilePath $pgTmp -ArgumentList "-o`"$gitDir`"", "-y" -NoNewWindow -Wait -PassThru
                Remove-Item $pgTmp -Force -ErrorAction SilentlyContinue
                if ($sp.ExitCode -ne 0 -or -not (Test-Path $gitExe)) { Die "PortableGit 解压失败（退出码 $($sp.ExitCode)）——重跑可续装" }
            }
        }
        if (Test-Path $gitExe) {
            $env:Path = "$gitDir\cmd;$env:Path"
            # 持久化用户 PATH：上游 Install-Git 的下载路径会做这件事（快速通道默认已持久）；装后 agent 端也要 git
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            if ($userPath -notlike "*$gitDir\cmd*") {
                [Environment]::SetEnvironmentVariable("Path", ($userPath.TrimEnd(';') + ";$gitDir\cmd"), "User")
            }
        }

        # ②：选可用 git 加速器（ls-remote 轻探针；PS5.1 原生调用需降级 EAP 防 2>$null 炸 NativeCommandError）
        $GhProxy = ""
        foreach ($cand in @("https://ghproxy.net/", "https://gh-proxy.com/", "https://ghfast.top/")) {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) { break }
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            $null = git ls-remote ($cand + $UpstreamRepo) "refs/tags/$Tag" 2>&1
            $lsOk = ($LASTEXITCODE -eq 0)
            $ErrorActionPreference = $prevEAP
            if ($lsOk) { $GhProxy = $cand; break }
        }
        if (-not $GhProxy) {
            Die "GitHub 与全部加速器（ghproxy.net / gh-proxy.com / ghfast.top）均不可达。请开一次代理后重跑（已完成步骤自动跳过）——安装完成后日常使用不再需要。"
        }
        Ok "镜像链加速器：$GhProxy"

        # ③：内核源码预置（浅克隆 pin tag；origin 保留加速器前缀——上游 fetch origin 失败即 throw）
        $kernelDir = Join-Path $HermesHome "hermes-agent"
        if (Test-Path "$kernelDir\.git") {
            Log "镜像链③：内核源码已在（跳过预克隆）"
        } else {
            Log "镜像链③：经加速器预置内核源码（$Tag，浅克隆）……"
            if (Test-Path $kernelDir) { Remove-Item -Recurse -Force $kernelDir -ErrorAction SilentlyContinue }
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            $null = git clone --depth 1 --branch $Tag ($GhProxy + $UpstreamRepo) $kernelDir 2>&1
            $cloneOk = ($LASTEXITCODE -eq 0)
            $ErrorActionPreference = $prevEAP
            if (-not $cloneOk -or -not (Test-Path "$kernelDir\.git")) { Die "内核预克隆失败——加速器波动，重跑可续装" }
        }

        # ④：uv 预置（非致命：astral.sh 走 Fastly CDN 境内通常可达，失败则上游自装）
        $uvExe = Join-Path $HermesHome "bin\uv.exe"
        if (-not (Test-Path $uvExe)) {
            Log "镜像链④：预置 uv（加速器，官方 release）……"
            $uvZip = Join-Path $env:TEMP "hm-uv.zip"
            try {
                Invoke-WebRequest -Uri ($GhProxy + "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip") -OutFile $uvZip -UseBasicParsing
                $uvTmp = Join-Path $env:TEMP "hm-uv-x"
                Expand-Archive -Path $uvZip -DestinationPath $uvTmp -Force
                $found = Get-ChildItem $uvTmp -Recurse -Filter uv.exe | Select-Object -First 1
                if ($found) {
                    New-Item -ItemType Directory -Force -Path (Join-Path $HermesHome "bin") | Out-Null
                    Copy-Item $found.FullName $uvExe -Force
                    Ok "uv 已就位（镜像链）"
                } else { Warn "uv 预置未找到 uv.exe（非致命，上游将自行安装）" }
                Remove-Item $uvTmp -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                $whyUv = $_.Exception.Message
                if ($_.Exception.InnerException) { $whyUv += " <- $($_.Exception.InnerException.Message)" }
                Warn "uv 预置失败（非致命）：$whyUv"
            }
            Remove-Item $uvZip -Force -ErrorAction SilentlyContinue
        }

        # ⑤：PBS 兜底（npmmirror 已在前面无条件探测首选；仅当其不可达时镜像链内退加速器——ghproxy 大文件不稳，最后手段）
        if (-not $env:UV_PYTHON_INSTALL_MIRROR) {
            $env:UV_PYTHON_INSTALL_MIRROR = $GhProxy + "https://github.com/astral-sh/python-build-standalone/releases/download"
            $pbsSource = "ghproxy"
        }

        Ok "镜像链就绪：git/内核/Python/uv→国内通道，PyPI/npm/Playwright→国内源（Node 走 nodejs.org 官方）"
        # 机器标记行：exe 捕获后随失败红字展示，用于远程定位走了哪条链路（交互模式不输出）
        if ($Answers) { Write-Host "##HM-MIRROR## mode=on proxy=$GhProxy pbs=$pbsSource" }
    }
    else {
        if ($Answers) { Write-Host "##HM-MIRROR## mode=off pbs=$pbsSource" }
    }
    # ---------- 内核仓库预清理（无条件 stash） ----------
    # 七轮实证：既有 %HERMES_HOME%\hermes-agent 存在运行时 churn（uv.lock / website docs），上游更新路径的
    # 自动 stash 偶发静默失败（失败不中止流程），git checkout tag 当场 abort 整个安装。本脚本先行 stash——
    # 改动保留进 stash list 可随时恢复，与上游"保留本地修改"语义完全一致，只是提前且无条件。
    $existingRepo = Join-Path $HermesHome "hermes-agent"
    if ((Test-Path "$existingRepo\.git") -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        $dirty = git -C $existingRepo status --porcelain 2>&1
        if (-not [string]::IsNullOrWhiteSpace(($dirty -join ""))) {
            Log "内核仓库有本地改动，先行 stash（在 $existingRepo 用 git stash list 可恢复）……"
            $null = git -C $existingRepo stash push --include-untracked -m ("hermemory-install-prestash-" + (Get-Date -Format "yyyyMMddHHmmss")) 2>&1
            $still = git -C $existingRepo status --porcelain 2>&1
            if ([string]::IsNullOrWhiteSpace(($still -join ""))) { Ok "内核仓库已清洁（改动在 stash，未丢失）" }
            else { Warn "stash 后仍不清洁——交由上游自行处理（其自带 stash/reset 兜底逻辑）" }
        }
        $ErrorActionPreference = $prevEAP
    }

    Log "运行上游官方 install.ps1（pin $Tag；uv + Python 3.11 + Node + PortableGit，首次约 5-10 分钟）..."
    # 上游安装器已 vendored：scripts\upstream-install.ps1 = 上游 pin tag v2026.8.31 的 scripts/install.ps1 逐字节副本（SHA256 核对过，纯 ASCII 无编码风险）。
    # 不再运行时从 raw.githubusercontent/main 拉取——该域境内最常被墙，且 main 会与内核 pin 漂移；MIT 许可允许随发行版分发。
    # pin 更新时：从上游本地仓库切到对应 tag 重新复制覆盖本文件，并重跑验收线。
    $up = Join-Path $SRC "scripts\upstream-install.ps1"
    if (-not (Test-Path $up)) { Die "缺 vendored 上游安装器：$up（发行包不完整，请重新获取 HerMemory）" }
    # 境内镜像注入：三个都是对应工具的官方环境变量旋钮，上游脚本零修改；用户/代理环境已自设时尊重不覆盖。
    # 覆盖安装期大头流量：PyPI 依赖（uv）、npm 包（Node 依赖与浏览器组件）、Playwright 内核；Electron 上游已自带 npmmirror 兜底。
    if ($IsOffline) {
        # 离线模式：全部流量改走内嵌 assets-offline（uv/npm 的内容寻址缓存 + 预置二进制），零网络
        $env:UV_OFFLINE = "1"
        $env:UV_CACHE_DIR = Join-Path $OfflineDir "uv-cache"
        $env:npm_config_cache = Join-Path $OfflineDir "npm-cache"
        $env:npm_config_offline = "true"
        $env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1"
        Log "离线模式：全部资源取自内嵌 assets-offline，零网络依赖"
        if ($Answers) { Write-Host "##HM-MIRROR## mode=offline pbs=assets" }
    } else {
        if (-not $env:UV_DEFAULT_INDEX)          { $env:UV_DEFAULT_INDEX = "https://pypi.tuna.tsinghua.edu.cn/simple" }
        if (-not $env:npm_config_registry)       { $env:npm_config_registry = "https://registry.npmmirror.com" }
        if (-not $env:PLAYWRIGHT_DOWNLOAD_HOST)  { $env:PLAYWRIGHT_DOWNLOAD_HOST = "https://cdn.npmmirror.com/binaries/playwright" }
        Log "镜像加速：PyPI→清华 / npm→npmmirror / Playwright→npmmirror / Python 运行时→$pbsSource（GitHub 直连残留项上游自带重试与兜底）"
    }

    # ---------- 2.4 Python 3.11 预置（把 PBS 下载从 uv 关键路径上摘掉） ----------
    # 沙盒六轮实证：探测全过（mode=off、pbs 探针 OK）不等于 20 分钟后那次 24MB 下载能过——波动网络里探测不承诺任何事。
    # 对策：把真的 Python 3.11 直接放进 PATH——上游 Install-Python 第一步 `uv python find 3.11` 即命中"search path"，
    # 完全跳过 uv 托管下载（错误 "No interpreter found ... search path" 反证了该搜索路径的存在）。
    # 仅镜像场景执行（pbs=npmmirror/ghproxy）；海外直连场景（pbs=default）维持 uv 默认，避免跨洋 CDN 反而拖慢。
    if ($IsOffline) {
        # 离线：Python 运行时直接取自内嵌 assets
        $pyDir = Join-Path $HermesHome "python-3.11"
        $pyExe = Join-Path $pyDir "python\python.exe"
        if (Test-Path $pyExe) {
            Log "Python 预置：已在（离线，跳过）"
        } else {
            Log "Python 预置：解压内嵌 CPython 3.11 运行时……"
            New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
            tar -xzf (Join-Path $OfflineDir "python-pbs.tar.gz") -C $pyDir
            if (Test-Path $pyExe) { Ok "Python 3.11 已预置（离线，上游将直接命中）" }
            else { Die "离线 Python 解压异常（缺 python\python.exe）——内嵌资源包不完整，请重新获取 HerMemory 离线版" }
        }
        if (Test-Path $pyExe) { $env:Path = (Split-Path $pyExe) + ";$env:Path" }
    } elseif ($pbsSource -in @("npmmirror", "ghproxy")) {
        $pyDir = Join-Path $HermesHome "python-3.11"
        $pyExe = Join-Path $pyDir "python\python.exe"
        $pyAsset = "cpython-3.11.16+20260901-x86_64-pc-windows-msvc-install_only.tar.gz"
        $pyBase1 = "https://registry.npmmirror.com/-/binary/python-build-standalone/20260901/$pyAsset"
        $pyBase2 = "https://ghproxy.net/https://github.com/astral-sh/python-build-standalone/releases/download/20260901/$pyAsset"
        if (Test-Path $pyExe) {
            Log "Python 预置：已在（跳过下载）"
        } else {
            $pySources = if ($pbsSource -eq "npmmirror") { @($pyBase1, $pyBase2) } else { @($pyBase2, $pyBase1) }
            $pyTmp = Join-Path $env:TEMP "hm-py311.tar.gz"
            $pyOk = $false
            foreach ($pySrc in $pySources) {
                Log "Python 预置：下载 cpython-3.11.16（约 24MB，源：$(([uri]$pySrc).Host)）……"
                try {
                    Invoke-WebRequest -Uri $pySrc -OutFile $pyTmp -UseBasicParsing
                    $pyOk = $true; break
                } catch {
                    $whyPy = $_.Exception.Message
                    if ($_.Exception.InnerException) { $whyPy += " <- $($_.Exception.InnerException.Message)" }
                    Warn "Python 预置：该源失败（$(([uri]$pySrc).Host)）：$whyPy"
                    Remove-Item $pyTmp -Force -ErrorAction SilentlyContinue
                }
            }
            if ($pyOk) {
                New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
                tar -xzf $pyTmp -C $pyDir
                Remove-Item $pyTmp -Force -ErrorAction SilentlyContinue
                if (Test-Path $pyExe) { Ok "Python 3.11.16 已预置（上游将直接命中，跳过 uv 托管下载）" }
                else { Warn "Python 预置解压异常——回落 uv 默认流程（镜像已配）" }
            } else {
                Warn "Python 预置双源均失败——回落 uv 默认流程（镜像已配）"
            }
        }
        if (Test-Path $pyExe) { $env:Path = (Split-Path $pyExe) + ";$env:Path" }
    }

    # ---------- 2.45 Node.js 22 预置（境内实测：上游 Stage-Node 直连 nodejs.org/dist 且 Invoke-WebRequest 无超时，常无限挂起） ----------
    # 与 Python 预置同思路：把真的 Node 22 提前放进上游探测位 $HermesHome\node\node.exe——
    # 上游 Test-Node 见位即用（自带 npm 满足其版本下限），整体跳过 nodejs.org 下载，钉死在 npmmirror。
    # 仅镜像场景执行（pbs=npmmirror/ghproxy）；海外直连场景维持上游默认（nodejs.org 本就快）。
    # x64 写死与 Python 预置同取舍；ARM 上游会自行下载正确架构（探测失败回落上游流程）。
    if ($IsOffline) {
        # 离线：Node 直接取自内嵌 assets（版本以离线包为准）
        $ndDir = Join-Path $HermesHome "node"
        $ndExe = Join-Path $ndDir "node.exe"
        if (Test-Path $ndExe) {
            Log "Node 预置：已在（离线，跳过）"
        } else {
            Log "Node 预置：解压内嵌 Node.js 22……"
            New-Item -ItemType Directory -Force -Path $ndDir | Out-Null
            # 文件名含版本号（node-v22.23.0-win-x64.zip）——通配定位，勿硬编码 "node.zip"（2026-09-10 实录：硬编码致 FileNotFound）
            $ndZip = Get-ChildItem $OfflineDir -File -Filter "node-v*.zip" | Select-Object -First 1
            if (-not $ndZip) { Die "离线包内未找到 node-v*.zip——内嵌资源包不完整，请重新获取 HerMemory 离线版" }
            # 标准 zip 解压器（tar 不解 zip，见段 0 注释）
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $ndTmp = Join-Path $env:TEMP "hm-node-unzip"
            Remove-Item $ndTmp -Recurse -Force -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ndZip.FullName, $ndTmp)
            $ndInner = Get-ChildItem $ndTmp -Directory -Filter "node-v*" | Select-Object -First 1
            if ($ndInner) {
                Copy-Item -Path (Join-Path $ndInner.FullName "*") -Destination $ndDir -Recurse -Force
            }
            Remove-Item $ndTmp -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $ndExe) { Ok "Node.js $(((& $ndExe --version) | Out-String).Trim()) 已预置（离线）" }
            else { Die "离线 Node 解压异常——内嵌资源包不完整，请重新获取 HerMemory 离线版" }
        }
    } elseif ($pbsSource -in @("npmmirror", "ghproxy")) {
        $ndDir = Join-Path $HermesHome "node"
        $ndExe = Join-Path $ndDir "node.exe"
        if (Test-Path $ndExe) {
            Log "Node 预置：已在（跳过下载）"
        } else {
            # 版本实测钉死（2026-09-10 npmmirror HTTP 200 验证），不做任何列表解析——PS5.1 下列表 API 行为不可靠。
            # 版本须满足上游 engines ^22.22.0（npm ci EBADENGINE 教训）
            $ndVer = "22.23.0"
            $ndTmp = Join-Path $env:TEMP "hm-node22"
            try {
                Log "Node 预置：下载 v$ndVer（约 34MB，源 npmmirror）……"
                Invoke-WebRequest -Uri "https://registry.npmmirror.com/-/binary/node/v$ndVer/node-v$ndVer-win-x64.zip" -OutFile "$ndTmp.zip" -UseBasicParsing -TimeoutSec 600
                if (Test-Path $ndTmp) { Remove-Item -Recurse -Force $ndTmp }
                Expand-Archive -Path "$ndTmp.zip" -DestinationPath $ndTmp -Force
                $ndInner = Get-ChildItem $ndTmp -Directory | Select-Object -First 1
                if ($ndInner) {
                    New-Item -ItemType Directory -Force -Path $ndDir | Out-Null
                    Copy-Item -Path (Join-Path $ndInner.FullName "*") -Destination $ndDir -Recurse -Force
                }
                if (Test-Path $ndExe) { Ok "Node.js $(((& $ndExe --version) | Out-String).Trim()) 已预置（上游将直接命中，跳过 nodejs.org 下载）" }
                else { Warn "Node 预置解压异常——回落上游默认流程（nodejs.org 直连，境内可能很慢或挂起）" }
            } catch {
                $whyNd = $_.Exception.Message
                if ($_.Exception.InnerException) { $whyNd += " <- $($_.Exception.InnerException.Message)" }
                Warn "Node 预置失败（$whyNd）——回落上游默认流程；若再卡住：开代理后重跑，或手动装 Node 22 后重跑"
            } finally {
                Remove-Item "$ndTmp.zip" -Force -ErrorAction SilentlyContinue
                Remove-Item $ndTmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($IsOffline) {
        # 离线：系统件预置（PortableGit / uv / rg / ffmpeg）——放在仓库落位之前，后续 git 操作直接可用。
        # 上游各 Stage 全是 PATH 探测（Get-Command git/rg/ffmpeg；uv 看 $HermesHome\bin\uv.exe），预置即命中。
        if (-not (Test-Path (Join-Path $HermesHome "git\bin\git.exe"))) {
            Log "离线：解压 PortableGit（约半分钟）……"
            New-Item -ItemType Directory -Force -Path (Join-Path $HermesHome "git") | Out-Null
            & (Join-Path $OfflineDir "portable-git.7z.exe") "-o$(Join-Path $HermesHome 'git')" -y | Out-Null
        }
        $env:Path = "$(Join-Path $HermesHome 'git\bin');$(Join-Path $HermesHome 'bin');$env:Path"
        New-Item -ItemType Directory -Force -Path (Join-Path $HermesHome "bin") | Out-Null
        foreach ($f in @("uv.exe", "rg.exe", "ffmpeg.exe", "ffprobe.exe")) {
            $srcF = Join-Path $OfflineDir $f
            $dstF = Join-Path $HermesHome "bin\$f"
            if ((Test-Path $srcF) -and -not (Test-Path $dstF)) { Copy-Item $srcF $dstF -Force }
        }
        Copy-Item (Join-Path $OfflineDir "THIRD-PARTY-NOTICES.txt") (Join-Path $HermesHome "THIRD-PARTY-NOTICES.txt") -Force -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $HermesHome "git\bin\git.exe")) { Ok "离线系统件就位：PortableGit / uv / rg / ffmpeg（上游探测将直接命中）" }
        else { Die "离线 PortableGit 解压异常——内嵌资源包不完整，请重新获取 HerMemory 离线版" }
    }

    # ---------- 2.46 内核仓库预 clone（原子落位；境内 clone 慢且易被 AV 打断，半成品会让上游 heal 撞锁死循环） ----------
    # 上游对"存在但非 valid git repo"的目录是挪 broken 后重 clone——AV 锁住半成品时挪失败直接 throw，
    # 用户重试再撞锁（2026-09-10 00:05 实测两连败）。这里把 clone 重活自己做：临时目录 + 重试 3 次 +
    # 完成后同盘原子 Move，上游见完好仓库走增量路径（fetch 小流量）。残缺半成品直接删——无保留价值。
    $repoDir = Join-Path $HermesHome "hermes-agent"
    $repoOk = $false
    if (Test-Path $repoDir) {
        $inTree  = (& git -c windows.appendAtomically=false -C $repoDir rev-parse --is-inside-work-tree 2>$null)
        $hasHead = (& git -c windows.appendAtomically=false -C $repoDir rev-parse --verify HEAD 2>$null)
        if ("$inTree" -eq "true" -and $hasHead) {
            $repoOk = $true
            Log "内核仓库已在且完好（上游将走增量校验，跳过 clone）"
        } else {
            Log "发现残缺的 hermes-agent（clone 半成品）——清除后重新 clone……"
            Remove-Item -Recurse -Force $repoDir -ErrorAction SilentlyContinue
            if (Test-Path $repoDir) { Die "残缺目录被占用清不掉：$repoDir——关闭正在使用它的程序（含后台 git 进程）后点「重新安装」" }
        }
    }
    if ($IsOffline) {
        # 离线：仓库从内嵌 zip 落位；origin 指向内嵌 bundle——上游 update 的 fetch 命中本地，零网络
        if (-not (Test-Path $repoDir)) {
            Log "离线：落位内嵌 hermes-agent 源码树（pin $Tag）……"
            $tmpOff = Join-Path $env:TEMP "hm-hermes-agent-off"
            if (Test-Path $tmpOff) { Remove-Item -Recurse -Force $tmpOff }
            New-Item -ItemType Directory -Force -Path $tmpOff | Out-Null
            # 标准 zip 解压器（tar 不解 zip，见段 0 注释）
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $OfflineDir "hermes-agent.zip"), $tmpOff)
            # zip 内可能带 hermes-agent/ 顶层目录——找到含 .git 的那层作为仓库根
            $repoSrc = $tmpOff
            if (-not (Test-Path (Join-Path $tmpOff ".git"))) {
                $inner = Get-ChildItem $tmpOff -Directory | Where-Object { Test-Path (Join-Path $_.FullName ".git") } | Select-Object -First 1
                if ($inner) { $repoSrc = $inner.FullName }
            }
            Move-Item $repoSrc $repoDir
        }
        & git -C $repoDir remote set-url origin (Join-Path $OfflineDir "hermes-agent.bundle") 2>$null
        $inTree  = (& git -C $repoDir rev-parse --is-inside-work-tree 2>$null)
        $hasHead = (& git -C $repoDir rev-parse --verify HEAD 2>$null)
        if ("$inTree" -eq "true" -and $hasHead) {
            $repoOk = $true
            Ok "内核仓库已离线落位（pin $Tag；origin 指向内嵌 bundle，上游 fetch 零网络）"
        } else { Die "离线仓库落位异常（非有效 git repo）——内嵌资源包不完整，请重新获取 HerMemory 离线版" }
    } elseif (-not $repoOk -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $repoUrl = "https://github.com/NousResearch/hermes-agent.git"
        if ($GhProxy) { $repoUrl = $GhProxy + $repoUrl }
        $tmpRepo = Join-Path $env:TEMP "hm-hermes-agent"
        $prevEapRepo = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        for ($i = 1; $i -le 3 -and -not $repoOk; $i++) {
            Log "预 clone 内核仓库（第 $i/3 次，pin $Tag，源 $(([uri]$repoUrl).Host)）……"
            try {
                if (Test-Path $tmpRepo) { Remove-Item -Recurse -Force $tmpRepo -ErrorAction SilentlyContinue }
                & git -c windows.appendAtomically=false clone --depth 1 --branch $Tag $repoUrl $tmpRepo 2>&1 | ForEach-Object { "$_" }
                if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $tmpRepo ".git"))) {
                    Move-Item -LiteralPath $tmpRepo -Destination $repoDir -ErrorAction Stop
                    $repoOk = $true
                    Ok "内核仓库已预 clone（pin $Tag）——上游将跳过下载直接增量校验"
                } else {
                    Warn "预 clone 第 $i 次未成功（git 退出码 $LASTEXITCODE）"
                }
            } catch {
                Warn "预 clone 第 $i 次失败：$($_.Exception.Message)"
            }
            if (-not $repoOk -and (Test-Path $tmpRepo)) { Remove-Item -Recurse -Force $tmpRepo -ErrorAction SilentlyContinue }
        }
        $ErrorActionPreference = $prevEapRepo
        if (-not $repoOk) { Warn "预 clone 未成功——回落上游默认流程（SSH/HTTPS/ZIP 逐级尝试，境内可能很慢或被占）" }
    }

    & ([scriptblock]::Create((Get-Content $up -Raw))) -Tag $Tag -SkipSetup
    # 编码归位：上游安装脚本开头执行 [Console]::OutputEncoding=UTF8（scriptblock 同会话运行，会“传染”本脚本后续输出）。
    # exe 端已按行自适应解码（UTF-8 严格优先、失败退 GBK），流内切换不再乱码；此处归位主要惠及 install.bat 交互用户的肉眼输出
    #（重定向场景下该 setter 实测不回退、无害保留；交互控制台场景有效）。
    try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch { Run-Quiet chcp.com 936 }
    if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
        Warn "hermes 未进当前会话 PATH；刷新后重试或手动确认 %LOCALAPPDATA%\hermes\bin"
        $env:Path += ";$HermesHome\bin"
    }
    if (Get-Command hermes -ErrorAction SilentlyContinue) {
        Ok "hermes CLI 就绪"
        Mark-Done "upstream"
    } else {
        Die "hermes CLI 安装未成功——排除后重跑（已完成步骤会自动跳过）"
    }
}

# ---------- 2.5 内核 UX 补丁（发行版自有，幂等）：微信二维码改为链接+浏览器提示 ----------
$wxPy = Join-Path $HermesHome "hermes-agent\gateway\platforms\weixin.py"
$wxPatch = Join-Path $PSScriptRoot "scripts\patch_weixin_qr.py"
$wxBin = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"
if ((Test-Path $wxPy) -and (Test-Path $wxPatch) -and (Test-Path $wxBin)) {
    & $wxBin $wxPatch $wxPy
}
Progress "upstream"

# ---------- 3. vault 结构 ----------
New-Item -ItemType Directory -Force -Path "$VaultDir\HerMemory\memory" | Out-Null
Ok "同步根结构：$VaultDir\{用户文档, HerMemory\memory\}"

# ---------- 4. 出厂五文件（已存在绝不覆盖——那是记忆） ----------
foreach ($f in @("MEMORY.md","USER.md","SOUL.md","AGENTS.md","AUTOMATION.md")) {
    $dst = "$VaultDir\HerMemory\memory\$f"
    if (Test-Path $dst) { Log "已存在，跳过：$dst（不覆盖既有记忆）" }
    else { Copy-Item "$SRC\memory\$f" $dst; Ok "铺设出厂文件：HerMemory\memory\$f" }
}

# ---------- 4.5 使用文档进同步范围 ----------
New-Item -ItemType Directory -Force -Path "$VaultDir\HerMemory\docs" | Out-Null
Copy-Item "$SRC\docs\*" "$VaultDir\HerMemory\docs\" -Recurse -Force
Ok "使用文档已铺：HerMemory\docs/"
Progress "files"

# ---------- 5. 软链四件（官方注入槽位）----------
# NTFS 符号链接需要管理员权限或开发者模式（Win10 1703+ 设置→更新→开发者选项）。
function LinkOne([string]$src, [string]$dst) {
    # 幂等：符号链接已就位即跳过
    if (Test-Path $dst) {
        $ex = Get-Item $dst -Force
        if ($ex.LinkType -eq "SymbolicLink" -and $ex.Target -eq $src) { Log "符号链接已就位：$dst"; return }
    }
    $dir = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (Test-Path $dst) {
        $bak = "$dst.pre-hermemory.$(Get-Date -Format yyyyMMddHHmmss)"
        Move-Item $dst $bak
        Warn "检测到已有文件 $dst，已备份为 $bak 后建立链接"
    }
    # 坑（2026-09-10 00:13 实测）：New-Item 符号链接失败抛的是【非终止错误】，
    # 不加 -ErrorAction Stop 时 catch 接不住 → 静默假成功 → HERMES_HOME 无 SOUL.md
    # → hermes 首次 load_config 播种默认身份，用户所见即"注入失效"。
    # 故：-ErrorAction Stop + 事后 LinkType 双验证；再降级 HardLink（同卷免特权，
    # 同一文件两个目录项，改 vault 即改 AI 所读，语义与软链一致）。
    try { New-Item -ItemType SymbolicLink -Path $dst -Target $src -Force -ErrorAction Stop | Out-Null } catch { }
    $ex = if (Test-Path $dst) { Get-Item $dst -Force } else { $null }
    if (-not $ex -or $ex.LinkType -ne "SymbolicLink") {
        if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
        Die "符号链接创建失败：请右键「以管理员身份运行」重新打开 HerMemory 完成安装；或开启开发者模式（设置 → 更新与安全 → 开发者选项）。已完成的步骤不会丢失，重新安装时自动跳过。"
    }
    Ok "符号链接：$dst -> $src"
}
LinkOne "$VaultDir\HerMemory\memory\SOUL.md"   "$HermesHome\SOUL.md"
# AGENTS.md 的注入槽位是"会话工作目录链"（git 根→cwd），不是 HERMES_HOME。
# 槽位用 .hermes.md（Hermes 专属、优先级最前）：用户可见文件仍是 vault 里的 AGENTS.md，
# 且不会污染机器上其他遵循 AGENTS 约定的工具（Codex CLI 等不读 .hermes.md）。
LinkOne "$VaultDir\HerMemory\memory\AGENTS.md" "$HOME\.hermes.md"

# ---------- 5.5 memories 整目录 junction（免特权）----------
# hermes 的 memories 路径硬编码为 $HermesHome\memories（agent/learning_mutations.py），不可配置。
# 用 junction 做路径级重定向：hermes 对 memories\ 的任何写入方式——含 atomic_replace 的
# tmp+rename 原子替换（实测 2026-09-10 01:55）——都天然落在 vault 目标目录内，结构上无断链概念。
# 优于文件级硬链接（会被 os.replace 静默断链）与文件级符号链接（同需特权且依赖上游保护）。
$memDir = Join-Path $HermesHome "memories"
$jTarget = "$VaultDir\HerMemory\memory"
New-Item -ItemType Directory -Force -Path $jTarget | Out-Null
$exJ = Get-Item $memDir -Force -ErrorAction SilentlyContinue
if ($exJ -and $exJ.LinkType -eq "Junction" -and "$($exJ.Target)" -eq $jTarget) {
    Log "memories junction 已就位：$memDir -> $jTarget"
} else {
    if (Test-Path $memDir) {
        # 迁移既有记忆到 vault（仅拷 vault 缺失的文件，绝不覆盖）
        Get-ChildItem $memDir -File -Force | ForEach-Object {
            $d = Join-Path $jTarget $_.Name
            if (-not (Test-Path $d)) { Copy-Item $_.FullName $d -Force; Warn "迁移既有记忆：$($_.Name)" }
        }
        Remove-Item $memDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Junction -Path $memDir -Target $jTarget -ErrorAction Stop | Out-Null
    Ok "memories 已以 junction 挂到 vault：$memDir -> $jTarget（AI 写记忆 = Obsidian 立刻可见）"
}

# ---------- 6. 品牌皮肤 ----------
New-Item -ItemType Directory -Force -Path "$HermesHome\skins" | Out-Null
Copy-Item "$SRC\skins\hermemory.yaml" "$HermesHome\skins\hermemory.yaml" -Force
Run-Quiet hermes config set display.skin hermemory
if ($LASTEXITCODE -eq 0) { Ok "皮肤已激活：HerMemory（/skin 可随时切换；改 yaml 约一秒热重绘）" }
else { Warn "display.skin 写入失败（不致命），运行时 /skin hermemory 手动切换" }

# ---------- 7. 时区 ----------
Log "Windows 使用本机时钟（时间注入取系统时间）——请在系统设置里确认时区为 (UTC+08:00) 北京"

# ---------- 8. 时间注入开关 + 界面显示偏好 ----------
& hermes config set gateway.message_timestamps.enabled true | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "时间注入已开启：每条用户消息头部自动拼本机真实时间" }
else { Die "gateway.message_timestamps.enabled 写入失败" }
Run-Quiet hermes config set display.language zh
if ($LASTEXITCODE -eq 0) { Ok "界面语言：中文" } else { Warn "display.language 写入失败（不致命）" }
Run-Quiet hermes config set display.timestamps true
if ($LASTEXITCODE -eq 0) { Ok "对话时间标签 [HH:MM]：已开启" } else { Warn "display.timestamps 写入失败（不致命）" }

# ---------- 9. 记忆档位 ----------
if (Test-Done "memory-tier") {
    Log "记忆档位：已完成（自动跳过）"
} else {
if ($Answers) {
    switch ("$($Answers.memoryTier)") {
        "1" { $memLimit = 2200;  $userLimit = 1375 }
        "2" { $memLimit = 5000;  $userLimit = 3000 }
        "3" { $memLimit = 10000; $userLimit = 5000 }
        "custom" {
            # exe 端已校验同款规则；此处独立复核（契约防御：AnswersFile 可能被手工构造）
            if ("$($Answers.customMem)" -notmatch '^[1-9]\d{2,6}$' -or "$($Answers.customUser)" -notmatch '^[1-9]\d{2,6}$') {
                Die "memoryTier=custom 需要 customMem/customUser 为 100-9999999 的整数（实际：$($Answers.customMem) / $($Answers.customUser)）"
            }
            $memLimit = [int]"$($Answers.customMem)"; $userLimit = [int]"$($Answers.customUser)"
        }
        default { Die "AnswersFile.memoryTier 必须是 1/2/3/custom（实际：$($Answers.memoryTier)）" }
    }
} else {
Log "MEMORY/USER容量设置"

Write-Host "提升容量会增强AI记忆力，但可能降低专注度，建议选择1-2档"

Write-Host "  1.紧凑：2200/1375 [默认]"
Write-Host "  2.标准：5000/3000"
Write-Host "  3.详细：10000/5000"

$choice = Read-Host "请选择记忆档位（1/2/3）"
switch ($choice) {
    "2" { $memLimit = 5000;  $userLimit = 3000 }
    "3" { $memLimit = 10000; $userLimit = 5000 }
    default { $memLimit = 2200; $userLimit = 1375 }
}
}
& hermes config set memory.memory_char_limit $memLimit | Out-Null
& hermes config set memory.user_char_limit $userLimit | Out-Null
Ok "记忆档位：MEMORY $memLimit / USER $userLimit 字符（随时改档：bash memory-size.sh）"
Mark-Done "memory-tier"
}
Progress "memory-tier"

# ---------- 9.5/9.6 配置 AI（用户流程 2：地址先验证，Key 后验证；Key 阶段输 1 可返回地址；完成后 AI 上线） ----------
if (Test-Done "config-ai") {
    Log "配置 AI：已完成（自动跳过）"
} else {
if ($Answers) {
    # 静默模式：exe 已收集答案，这里一次性验证，失败即 Die（重试界面由 exe 负责）
    $provBase = $Answers.baseUrl
    $apiKey = $Answers.apiKey
    $provModel = $Answers.model
    Log "静默模式：验证 API 地址与 Key……"
    $modelsFile = Join-Path $env:TEMP "hm-models.json"
    $httpCode = [string](& curl.exe -sL --noproxy "*" --max-time 20 -o $modelsFile -w "%{http_code}" "$provBase/models" -H "Authorization: Bearer $apiKey")
    if ($httpCode -eq "000") {
        $httpCode = [string](& curl.exe -sL --max-time 20 -o $modelsFile -w "%{http_code}" "$provBase/models" -H "Authorization: Bearer $apiKey")
    }
    $models = $null
    try { $models = Get-Content $modelsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if ($httpCode -eq "401" -or $httpCode -eq "403") { Die "[$httpCode] 认证未通过——请检查 API Key 是否正确且已启用" }
    if ($httpCode -eq "000" -or $httpCode -eq "" -or $null -eq $httpCode) { Die "[连接超时] 无法连接 $provBase——请检查网络或代理设置" }
    $ids = @()
    if ($models -and $models.data) { $ids = @($models.data | ForEach-Object { $_.id }) }
    if ($ids.Count -eq 0) { Die "验证未通过（HTTP $httpCode）——请核对地址与 Key" }
    if ($ids -notcontains $provModel) { Die "模型 $provModel 不在该地址的模型列表中——请重新获取模型列表并选择" }
    Ok "静默验证通过（HTTP $httpCode，$($ids.Count) 个可用模型）"
} else {
Write-Host ""
Write-Host "HerMemory本身永久免费"
Write-Host "但AI每次回答都会消耗服务商的算力"
Write-Host ""
Write-Host ""

Write-Host "需要你获取："
Write-Host ""
Write-Host ""

Write-Host "1.Base URL"
Write-Host "通常以https开头，v1结尾"
Write-Host "控制台里可能叫：API地址 / OpenAI兼容地址"
Write-Host ""
Write-Host ""

Write-Host "2.APIkey"
Write-Host "一长串字符，常以sk-开头，也可能没有规律"
Write-Host "控制台里可能叫：API key / API密钥"
Write-Host ""


$atUrl = $true
while ($true) {
    if ($atUrl) {
        Log "第一步：验证 API 地址"
        while ($true) {
            Write-Host ""
            $provBase = (Read-Host "请输入 API 地址").Trim()
            Write-Host ""
            # 只保留可见 ASCII——剔除复制粘贴混入的零宽/全角/控制字符
            $provBase = ($provBase -replace "[^\x21-\x7E]", "").TrimEnd("/")
            Log "正在验证 API 地址……"
            # 用系统自带 curl.exe（不走 .NET 代理/TLS 栈，行为与 Linux 一致）
            # 直连优先（绕过代理环境变量）；不通再回退系统代理
            $urlCode = [string](& curl.exe -sL --noproxy "*" --max-time 20 -o "$env:TEMP\hm-url-test.json" -w "%{http_code}" "$provBase/models")
            if ($urlCode -eq "000") {
                $urlCode = [string](& curl.exe -sL --max-time 20 -o "$env:TEMP\hm-url-test.json" -w "%{http_code}" "$provBase/models")
            }
            if ($urlCode -eq "000") {
                Warn "[连接超时] 无法连接至该 API 地址。请确认：① 地址为服务商提供的接口地址（通常以 /v1 结尾）；② 本机当前可以访问互联网；③ 若开启了代理软件，尝试关闭代理或更换节点后重试"
                continue
            }
            if ($urlCode -eq "404") {
                Warn "[404] 该接口路径不存在。请核对是否使用了服务商标注的 OpenAI 兼容接口地址"
                continue
            }
            Ok "API 地址可达（HTTP $urlCode）"
            break
        }
        $atUrl = $false
    }

    Log "第二步：验证 API Key（输入 1 返回上一步）"
    Write-Host ""
    $apiKey = (Read-Host "请输入 API Key").Trim()
    Write-Host ""
    $apiKey = ($apiKey -replace "[^\x21-\x7E]", "")
    if ($apiKey -eq "1") { $atUrl = $true; continue }
    if (-not $apiKey) { Warn "key 不能为空——重新输入"; continue }

    Log "正在验证 API Key……"
    $modelsFile = Join-Path $env:TEMP "hm-models.json"
    $httpCode = [string](& curl.exe -sL --noproxy "*" --max-time 20 -o $modelsFile -w "%{http_code}" "$provBase/models" -H "Authorization: Bearer $apiKey")
    if ($httpCode -eq "000") {
        $httpCode = [string](& curl.exe -sL --max-time 20 -o $modelsFile -w "%{http_code}" "$provBase/models" -H "Authorization: Bearer $apiKey")
    }
    $models = $null
    try { $models = Get-Content $modelsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $snippet = ""
    try { $snippet = (Get-Content $modelsFile -Raw -Encoding UTF8 -ErrorAction Stop).Substring(0, [Math]::Min(150, (Get-Item $modelsFile -ErrorAction Stop).Length)) } catch {}
    if ($httpCode -eq "401" -or $httpCode -eq "403") {
        Warn "[$httpCode] 认证未通过（服务返回：$snippet）。请确认 API Key 复制完整（注意首尾空格与截断），且该 Key 在服务商控制台处于启用状态"
        continue
    }
    if ($httpCode -eq "000" -or $httpCode -eq "" -or $null -eq $httpCode) {
        Warn "[连接超时] 网络异常——重新输入，或输 1 返回上一步"
        continue
    }
    $ids = @()
    if ($models -and $models.data) { $ids = @($models.data | ForEach-Object { $_.id }) }
    if ($ids.Count -eq 0) {
        if ($models -and $models.data -ne $null) { Warn "[错误] 连接正常，但该 Key 名下无可用模型。请在服务商控制台确认已开通模型调用权限" }
        else { Warn "验证未通过（HTTP $httpCode，服务返回：$snippet）。请核对地址与 Key，或稍后重试" }
        continue
    }
    Ok "连接正常，检测到 $($ids.Count) 个可用模型。"
    break
}

for ($i = 0; $i -lt $ids.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $ids[$i]) }
while ($true) {
    $pick = Read-Host "请选择模型序号"
    if ($pick -match "^\d+$" -and [int]$pick -ge 1 -and [int]$pick -le $ids.Count) { $provModel = $ids[[int]$pick - 1]; break }
    Warn "序号无效——重新选择"
}
}

# 上游机制（model_setup_flows._model_flow_custom，逐条对应）：
#   key 存 .env 的 HERMES_CUSTOM_<主机>_API_KEY；config model 段 = provider custom +
#   base_url + api_key ${ENV引用} + api_mode。绝不能写 OPENAI_API_KEY——
#   auto 路由见到它会劫持到 OpenRouter（auth.py resolve_provider）。
$u = [uri]$provBase
$hostId = $u.Host
if ($u.Port -gt 0) { $hostId = "${hostId}_$($u.Port)" }
$keyEnv = "HERMES_CUSTOM_" + (($hostId.ToUpper()) -replace "[^A-Z0-9]+", "_").Trim("_") + "_API_KEY"
& hermes config set $keyEnv $apiKey | Out-Null
if (-not (Select-String -Path "$HermesHome\.env" -Pattern ("^" + $keyEnv + "=") -Quiet)) { Add-Content -Path "$HermesHome\.env" -Value "$keyEnv=$apiKey" }
# 清除会劫持路由的 OPENAI_*（上游 auxiliary_client 明确告警的 env 污染场景）
Run-Quiet hermes config unset OPENAI_API_KEY
Run-Quiet hermes config unset OPENAI_BASE_URL
# 存在性保护：.env 可能因上游未落盘而缺失，EAP=Stop 下直接 Get-Content 会中断安装
$envClean = @()
if (Test-Path "$HermesHome\.env") {
    $envClean = @(Get-Content "$HermesHome\.env" -ErrorAction SilentlyContinue) | Where-Object { $_ -notmatch "^OPENAI_API_KEY=" -and $_ -notmatch "^OPENAI_BASE_URL=" }
}
if (-not $envClean -or $envClean.Count -eq 0) { $envClean = @("$keyEnv=$apiKey") }
# PS5.1 的 Set-Content -Encoding UTF8 会写 BOM——.env 首行键名会被 BOM 污染，必须无 BOM 落盘
[IO.File]::WriteAllLines("$HermesHome\.env", [string[]]@($envClean), (New-Object Text.UTF8Encoding($false)))
& hermes config set model.default $provModel | Out-Null
& hermes config set model.provider custom | Out-Null
& hermes config set model.base_url $provBase | Out-Null
& hermes config set model.api_key ('${' + $keyEnv + '}') | Out-Null
& hermes config set model.api_mode chat_completions | Out-Null
# 落盘验证：provider/custom 与 key 引用缺一不可，缺则直改文件
$cfgPath = Join-Path $HermesHome "config.yaml"
if ((Test-Path $cfgPath) -and -not (Select-String -Path $cfgPath -Pattern "provider: custom" -Quiet)) {
    $cfgText = Get-Content $cfgPath -Raw
    $cfgText = $cfgText -replace "(?m)^(  provider:).*$", "  provider: custom"
    [IO.File]::WriteAllText($cfgPath, $cfgText, (New-Object Text.UTF8Encoding($false)))
}
if ((Test-Path $cfgPath) -and -not (Select-String -Path $cfgPath -Pattern ([regex]::Escape("api_key: `${$keyEnv}")) -Quiet)) {
    $cfgText = Get-Content $cfgPath -Raw
    if ($cfgText -match "(?m)^  base_url: .*$") {
        $cfgText = $cfgText -replace "(?m)^(  base_url: .*)$", ("`$1`n  api_key: `${" + $keyEnv + "}`n  api_mode: chat_completions")
        [IO.File]::WriteAllText($cfgPath, $cfgText, (New-Object Text.UTF8Encoding($false)))
    }
}
Ok "配置完成（模型：$provModel）"
Mark-Done "config-ai"
}
Progress "config-ai"
# ---------- 10. 微信扫码接入（可选；完成后 AI 直接出现在用户微信） ----------
$wxConfigured = $false
$envFile = Join-Path $HermesHome ".env"
if ($Answers) {
    Log "静默模式：微信扫码由 exe 在安装完成后接管（此步跳过）"
} elseif ((Test-Path $envFile) -and (Select-String -Path $envFile -Pattern "WEIXIN_ACCOUNT_ID" -Quiet)) {
    $wxConfigured = $true
    Ok "微信通道：已配置（跳过扫码）"
} else {
    Log "微信接入（推荐现在完成——完成后 AI 直接出现在你的微信里）"
    Write-Host "即将打开英文配置向导，请对照下面的中文答题卡操作："
    Write-Host ""
    Write-Host "  向导问题（英文原文）                              → 你该输入"
    Write-Host "  ─────────────────────────────────────────────"
    Write-Host "  Select platform（选择平台）                        → Weixin / WeChat 对应的数字"
    Write-Host "  Start QR login now?                               → 直接回车（开始扫码）"
    Write-Host "  向导给出二维码链接                                 → 复制链接到浏览器打开，页面出现"
    Write-Host "                                                       二维码后用微信扫码并确认"
    Write-Host "  How should direct messages be authorized?         → 输入 3（不要选默认的 1）"
    Write-Host "  Allowed Weixin user IDs                           → 直接回车（已预填你的微信 ID）"
    Write-Host "  How should group chats be handled?                → 输入 1（禁用群聊，推荐）"
    Write-Host "  其余提示                                           → 直接回车保持默认"
    Write-Host ""
    Write-Host "  完成后向导自动结束；不想现在配置可关闭向导窗口跳过"
    while ($true) {
        $wxNow = Read-Host "现在扫码连接微信？[y/n]"
        if (-not $wxNow) { $wxNow = "Y" }
        if ($wxNow -match "^[Nn]") { break }
        & chcp.com 65001 | Out-Null
        & hermes gateway setup
        & chcp.com 936 | Out-Null
        if ((Test-Path $envFile) -and (Select-String -Path $envFile -Pattern "WEIXIN_ACCOUNT_ID" -Quiet)) {
            $wxConfigured = $true
            Ok "微信通道已配置"
            break
        }
        Warn "微信尚未配置成功（二维码可能已超时）"
        $retry = Read-Host "重新打开向导扫码？[y/n]"
        if ($retry -match "^[Nn]") { break }
    }
    if ($wxConfigured) {
        # 兜底：统一消息授权为 allowlist（防止向导默认的 pairing 拦截首条微信消息）
        $wxUserId = ""
        $acctDir = Join-Path $HermesHome "weixin\accounts"
        $latest = Get-ChildItem -Path $acctDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($latest) {
            try { $wxUserId = (Get-Content $latest.FullName -Raw | ConvertFrom-Json).user_id } catch {}
        }
        if ($wxUserId) {
            $envLines = @(Get-Content $envFile -ErrorAction SilentlyContinue)
            if ($envLines -match "WEIXIN_DM_POLICY") {
                $envLines = $envLines -replace "^WEIXIN_DM_POLICY=.*", "WEIXIN_DM_POLICY=allowlist"
            } else {
                $envLines += "WEIXIN_DM_POLICY=allowlist"
            }
            if ($envLines -match "WEIXIN_ALLOWED_USERS") {
                $envLines = $envLines -replace "^WEIXIN_ALLOWED_USERS=.*", "WEIXIN_ALLOWED_USERS=$wxUserId"
            } else {
                $envLines += "WEIXIN_ALLOWED_USERS=$wxUserId"
            }
            # 无 BOM UTF-8（@() 包裹防单行 .env 退化成字符串拼接）
            [IO.File]::WriteAllLines($envFile, [string[]]$envLines, (New-Object Text.UTF8Encoding($false)))
            Ok "消息授权：仅允许你的微信 ID（首条消息直达）"
        }
    }
}
Progress "wechat"

# ---------- 11. gateway 服务（消息通道 + cron；上游在 Windows 用 schtasks 自启） ----------
# 向导里答过"开机自启（计划任务）"的话已经注册好了——先检测，避免重复安装卡在隐藏的授权/输入上
$gwEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$gwTask = schtasks /Query /FO LIST 2>&1 | Select-String -Pattern "hermes" -Quiet
$ErrorActionPreference = $gwEap
if ($gwTask) {
    Ok "gateway 服务已注册（向导完成）——跳过重复安装"
} else {
    Log "安装 gateway 服务（消息通道 + 定时任务，可能需要一两分钟）……"
    & hermes gateway install
    if ($LASTEXITCODE -eq 0) { Ok "gateway 服务已安装（消息 + 定时任务，登录自启）" }
    else { Warn "hermes gateway install 未成功。可稍后手动执行：hermes gateway install" }
}
Progress "gateway"

# ---------- 11. 脚本下线 ----------
# 设计（用户流程 2）：key 配置完成后 AI 上线，脚本下线。
# WebDAV / 微信接入 / 同步引导 / 能力演示全部由 AI 完成（#13）——AI 读 AGENTS.md 指针（内容在 docs）。

# ---------- 13. 完成提示 ----------
Write-Host ""
Log "HerMemory v0.1.0 安装完成。两件事必须知道（详解见 vault\HerMemory\docs\GUIDE.md）："
Write-Host "  (1) AGENTS.md 可自由编辑，但上游 Hermes 对它做威胁扫描——含触发词的内容会被整体拦截（规则静默失效）。"
Write-Host "      （MEMORY.md / USER.md 逐条扫描：命中条目在对话中显示为 [BLOCKED]，文件本身保留。）"
Write-Host "  (2) 自动化默认全关：写日记/总结由你说一声才写；周小结、定时任务等口述即建（agent 自建并登记进 AUTOMATION.md）。"
Write-Host ""
Log "接下来："
if ($wxConfigured) {
    Log "你的 HerMemory 已在微信里——打开微信，给它发第一句话，它会向你自我介绍并引导完成剩余部署。"
} else {
    Write-Host "  1. hermes         —— 启动 AI：首次对话它主动采档案（怎么称呼/主要用途/说话方式），"
    Write-Host "                      然后按 docs/ONBOARDING.md 引导你配置同步与微信接入"
    Log "启动 AI 后直接对话即可——它会按 AGENTS.md 的「初次部署」自动引导你完成剩余配置。"
}
Write-Host "  2. 改 $VaultDir\HerMemory\memory\ 下任何文件 → 开新对话即生效"
Log "文档：docs\INSTALL.md（部署）｜docs\GUIDE.md（使用）｜docs\README_REBORN.md（导出包内给下一个 agent 的恢复指引）"
Progress "done"
