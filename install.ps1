# ============================================================
# HerMemory installer (Windows native) — v0.2.0
# 基于 Hermes Agent v0.22.2 (commit d923a5e)，MIT。
# 上游官方 PowerShell 安装器负责内核（git bundle → checkout → PM 装 Python/Node/依赖 →
# 构建 hermes 命令与 TUI/web），本脚本只做发行版的铺设：vault + 五文件 + 软链 + 皮肤 +
# 配置键 + docs。对应 Linux 侧的 install.sh；上游怎么装，Windows 就怎么装。
#
# 运行：PowerShell 中  powershell -ExecutionPolicy Bypass -File install.ps1
# 前置：无需预装任何工具（git/uv/Python/Node 由上游安装器从随包素材与镜像取得）。
#       软链需要管理员权限或开发者模式。
# ============================================================
param(
    [switch]$SkipUpstream,
    # 安装向导里的「浏览器与电脑操作」勾选框（默认装）。关掉时透传给上游
    # -SkipBrowser / -SkipComputerUse，上游会把选择记进 declined-packages.json，
    # 之后 `hermes update` / `hermes pm install` 也不会把它加回来。
    [switch]$SkipBrowser,
    [switch]$SkipComputerUse,
    # 记忆库位置（默认 %USERPROFILE%\vault）。安装向导的位置页可选，装完由程序写入 HKCU。
    [string]$VaultDir = "",
    # 安装源目录（含 scripts\upstream-install.ps1、memory\、docs\）。由向导显式传入：
    # 靠 $MyInvocation 猜路径在"从仓库 build 目录跑安装器"这类场景下会指错地方。
    [string]$SrcDir = "",
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
$HermesHome = $HermesHome.Trim().Trim('"').TrimEnd('\')
# 升级进行中的标记：中止/断电后重跑时，靠它知道"网关任务必须重建"（进程内变量活不过一次重跑）。
$HmUpgradeMarker = Join-Path $HermesHome ".hm-kernel-upgrade"
# 显式导出到本进程环境。上游 vendored 安装器（scripts\upstream-install.ps1）的 param() 默认值
# 取 $env:HERMES_HOME，其 $InstallDir 亦由其派生，且它会把该值**持久化**写入 User 环境变量。
# 不导出时 $HermesHome 只是本脚本的变量：上游会按自己的默认值落位，并把**错误路径**持久化下去
# ——比"自定义目录不生效"更糟。子进程（uv / git / hermes）同样依赖它定位同一份 home。
$env:HERMES_HOME = $HermesHome
$SrcRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($SrcDir) { $SrcRoot = $SrcDir.Trim().Trim('"').TrimEnd('\') }
# 兜底：$SrcRoot 下找不到随包素材时，依次退到脚本自身目录、payload 缓存里最新的一份。
# 少了 vendor 安装器/出厂文件，安装会在中途硬停——宁可在这里挑对，也不要让用户看到"发行包不完整"。
if (-not (Test-Path (Join-Path $SrcRoot "scripts\upstream-install.ps1"))) {
    $srcCands = @($PSScriptRoot)
    try {
        $srcCands += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA "HerMemory\payload") -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object { $_.FullName })
    } catch { }
    foreach ($c in $srcCands) {
        if ($c -and (Test-Path (Join-Path $c "scripts\upstream-install.ps1"))) { $SrcRoot = $c; break }
    }
}

function Log([string]$m)  { Write-Host "[HerMemory] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[完成] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[note] $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }
Log "安装源：$SrcRoot"
# PS 5.1 坑：EAP=Stop 时原生命令 2>$null 会把 stderr 变成终止性错误（NativeCommandError）。
# Run-Quiet 在函数作用域内降级 EAP，stderr 静默流出——专用于允许失败的原生调用。
# ⚠ **绝不能写 `& $args`**：PowerShell 会把数组隐式转成字符串（[string]@('a','b') = 'a b'），
# 于是「可执行文件路径 + 参数」被当成一个**含空格的命令名** → 每次调用都抛
# CommandNotFoundException（实测：直接 `& $cli --version` 退出码 0，`Run-Q $cli --version` 返回 1）。
# 2026-09-16 异机实录据此定位：同学机第 6/8 段报"皮肤写入失败""时间注入写入失败"，
# 而 hermes CLI 自身完全正常。三个封装共用这个写法 → **全部失效**，且失效是静默的：
# Run-Quiet 连命令都没执行（taskkill 杀 gateway、config unset 清 OPENAI_* 从未真正跑过）。
# 正确写法 = 显式取出 exe 与参数，用 splatting 传参（见 R2 对照）。
function Run-Quiet {
    $ErrorActionPreference = "Continue"
    $exe = [string]$args[0]
    $rest = @($args | Select-Object -Skip 1)
    if (-not $exe) { return }
    try { & $exe @rest 2>&1 | Out-Null } catch { }
}

# ---------- hermes CLI 的调用口径（2026-09-15 定） ----------
# **一律走显式路径，不依赖 PATH**。三处都会让 hermes 这个命令名落空：
#   ① 分阶段安装下「配置阶段」是**新进程** —— User 注册表 PATH 的更新对"已经启动的父进程"不可见
#      （exe 从资源管理器继承的是它启动那一刻的环境，它再 spawn 的 powershell 同样看不见）；
#   ② 上游每个 Stage 进 Invoke-Stage 都先跑 Sync-EnvPath()，把 $env:Path 整体覆盖为注册表值；
#   ③ upstream 那三个分支里，只有「全新装内核」那条会补 PATH；`Test-Done "upstream"` 命中的那条什么都不补。
# 2026-09-15 异机实录（HERMES_HOME 被改到非 %LOCALAPPDATA% 的自定义目录，如 D:\apps\HerMemory）：阶段 1 装完内核一切正常，
# 阶段 2 走到第 8 段调用 CLI 时直接 CommandNotFoundException → 退出码 1 →「配置未成功」。
# 同一次安装里阶段 1 能过、阶段 2 不能过，正是 ① + ③ 叠加的结果。
$HermesCli = Join-Path $HermesHome "bin\hermes.exe"
# 顺手补进**本进程** PATH：让既有的 Get-Command 判据、以及 hermes 自己 spawn 的子进程都能看到它。
# 注意这不等于写注册表：注册表 PATH 由上游安装器负责（Install-Dependencies / Set-LauncherUserPath）。
if (Test-Path $HermesCli) { $env:Path = "$HermesHome\bin;$env:Path" }

# 与 Run-Quiet 同样降 EAP，但**返回退出码**。凡是"要看结果"的调用都用它：
# 命令不存在时 & 抛 CommandNotFound（被 catch 吃掉），而 $LASTEXITCODE 会保留**上一条**原生命令的值，
# 于是「Run-Quiet ... ; if ($LASTEXITCODE -eq 0)」会报假成功 —— 同机实录：hermes 根本找不到，
# 却打印了「皮肤已激活」。（在**同一作用域**里读 $LASTEXITCODE，不依赖它的作用域语义。）
function Run-Q {
    $ErrorActionPreference = "Continue"
    $exe = [string]$args[0]
    $rest = @($args | Select-Object -Skip 1)
    if (-not $exe) { return 1 }
    try { & $exe @rest 2>&1 | Out-Null } catch { return 1 }
    return [int]$LASTEXITCODE
}

# 与 Run-Q 相同，但把子进程输出一并带回。只回退出码时用户看不到任何原因
# （2026-09-16 异机实录：config set 失败只留一句"写入失败"，排查全靠猜）。
function Run-QOut {
    $ErrorActionPreference = "Continue"
    $exe = [string]$args[0]
    $rest = @($args | Select-Object -Skip 1)
    $o = @()
    if (-not $exe) { return @{ Code = 1; Out = "(未给出可执行文件)" } }
    try { $o = & $exe @rest 2>&1 } catch { $o = @("$_") }
    return @{ Code = [int]$LASTEXITCODE; Out = (($o | Out-String).Trim()) }
}

# 取输出的末尾若干行，嵌进失败信息里。
function Show-Tail([string]$s, [int]$n = 8) {
    if (-not $s) { return "" }
    $ls = @($s -split "`r?`n" | Where-Object { $_ -ne "" })
    if ($ls.Count -eq 0) { return "" }
    if ($ls.Count -gt $n) { $ls = $ls[-$n..-1] }
    return [Environment]::NewLine + "输出末尾：" + [Environment]::NewLine + (($ls | ForEach-Object { "  " + $_ }) -join [Environment]::NewLine)
}

# 原子写文本（无 BOM）。.env / config.yaml 这类“别的进程可能正在读”的文件，
# 直接 WriteAllLines 会在写到一半时留下半截内容；先写同目录临时文件再换名。
function Write-LinesAtomicNoBom([string]$Path, [string[]]$Lines) {
    $dir = Split-Path -Parent $Path
    if (-not $dir) { throw "无效路径：$Path" }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = Join-Path $dir ("." + (Split-Path -Leaf $Path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllLines($tmp, $Lines, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { Move-Item -LiteralPath $tmp -Destination $Path -Force }
        else { Move-Item -LiteralPath $tmp -Destination $Path }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-TextAtomicNoBom([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not $dir) { throw "无效路径：$Path" }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = Join-Path $dir ("." + (Split-Path -Leaf $Path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { Move-Item -LiteralPath $tmp -Destination $Path -Force }
        else { Move-Item -LiteralPath $tmp -Destination $Path }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# 从 launcher 的 exe 里读出它内嵌的解释器绝对路径（诊断用；v0.22 的启动器可能是
# 运行时解析而非内嵌，读不到就由 Format-CliBroken 走「未读出」分支）。
function Get-EmbeddedPython([string]$exe) {
    $found = @()
    try {
        $txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
        foreach ($m in [regex]::Matches($txt, '[A-Za-z]:\\[^\x00"]{2,220}?python\.exe')) {
            if ($found -notcontains $m.Value) { $found += $m.Value }
        }
    } catch { }
    return $found
}

# CLI 跑不起来时的完整诊断：内嵌解释器在哪、在不在、该怎么办。
function Format-CliBroken([string]$exe) {
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("hermes CLI 无法运行：$exe")
    $emb = @(Get-EmbeddedPython $exe)
    if ($emb.Count -gt 0) {
        foreach ($t in $emb) {
            [void]$L.Add("  该 exe 里写死的解释器路径：$t")
            [void]$L.Add("    该解释器存在？ " + (Test-Path -LiteralPath $t))
        }
    } else {
        [void]$L.Add("  （未能从 exe 中读出内嵌解释器路径）")
    }
    # v0.22 起环境由 PM 托管：<HERMES_HOME>\installs\<key>\facts.json 的
    # packages.venv.environment 指向真正的 venv，不再有 hermes-agent\venv。
    $pmVenv = $null
    try {
        foreach ($f in @(Get-ChildItem (Join-Path $HermesHome "installs\*\facts.json") -ErrorAction SilentlyContinue)) {
            $d = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($d.packages.venv.environment) { $pmVenv = $d.packages.venv.environment; break }
        }
    } catch { }
    if ($pmVenv) {
        $py = Join-Path $pmVenv "Scripts\python.exe"
        [void]$L.Add("  PM 记录的解释器：$py")
        [void]$L.Add("    是否存在？ " + (Test-Path -LiteralPath $py))
    } else {
        [void]$L.Add("  未找到 PM 环境记录（$HermesHome\installs\*\facts.json）")
    }
    [void]$L.Add("  处置：删除 $HermesHome\hermemory-install.state 后重跑安装器 —— 它会重建内核与 venv，已完成的其他步骤会自动跳过。")
    return ($L -join [Environment]::NewLine)
}

# 「内核可用」的唯一判据：CLI 真的跑得起来。文件存在不算 —— 见文件头与第 2 段注释。
function Get-WorkingHermesCli {
    foreach ($c in @((Join-Path $HermesHome "bin\hermes.exe"), (Join-Path $HermesHome "bin\hermes.cmd"))) {
        if ((Test-Path -LiteralPath $c) -and ((Run-Q $c --version) -eq 0)) { return $c }
    }
    # PATH 兜底只接受**本 home 内**的 launcher。否则机器上别人的 Hermes 会被当成本机的内核：
    # 版本碰巧相同就 Mark-Done 跳过安装，后续 config/皮肤写进别人的 home，而 vault 建在新 home。
    $g = Get-Command hermes -ErrorAction SilentlyContinue
    if ($g -and $g.Source) {
        $inside = $g.Source.StartsWith($HermesHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        if ($inside -and ((Run-Q $g.Source --version) -eq 0)) { return $g.Source }
        if (-not $inside) { Warn "PATH 里的 hermes 属于另一处安装（$($g.Source)），本发行版不使用它。" }
    }
    return $null
}

# 已装内核的版本号（`Hermes Agent v0.22.2 ...` 里那个 0.22.2）。取不到返回空串。
# 用途只有一个：区分「装的是本发行版锁定的内核」与「装的是更早的 0.1.0 内核」。
function Get-HermesVersion([string]$exe) {
    if (-not $exe) { return "" }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $exe --version 2>&1 | Out-String
        $m = [regex]::Match($out, 'Hermes Agent v(\d+\.\d+\.\d+)')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { } finally { $ErrorActionPreference = $prev }
    return ""
}

# 粗略 semver 比较：返回 -1/0/1。只比较数字段，够用（版本号都是 x.y.z）。
function Compare-Version([string]$a, [string]$b) {
    $pa = @(($a -split '\.') | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    $pb = @(($b -split '\.') | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# ---------- 静默模式（exe 契约）：-AnswersFile 提供 JSON 答案，跳过全部交互 ----------
# **分两个阶段调用（2026-09-15 用户定的安装顺序：先选目录 → 安装 → 再填记忆与 API）**：
#   安装阶段：答案文件里**不带** AI 四项 → 只装内核与文件，memory-tier / config-ai / wechat / gateway 全跳过
#   配置阶段：答案文件里**带齐** memoryTier / baseUrl / apiKey / model → 靠断点续装跳过已完成的步骤，
#             只做记忆档位、AI 配置、微信接入与 gateway 注册
# 所以校验规则是「要么全给、要么全不给」——只给一部分属于调用方出错，宁可当场报错也不要装出半配置状态。
# JSON 其余字段：customMem/customUser（memoryTier=custom 时必需，各为 100-9999999 整数）/
# autoStart（"1"/"0"，缺省视为 1）/ heavyTools（"1"/"0"，缺省视为 1；0 表示不装浏览器与电脑操作）。
# 与交互路径共用同一套验证与落盘逻辑；区别仅在：验证失败即 Die（重试界面由 exe 负责），微信扫码由 exe 接管。
# 安全语义：key 明文经 JSON 短暂落盘，exe 在安装成功后负责删除。
$Answers = $null
if ($AnswersFile) {
    if (-not (Test-Path $AnswersFile)) { Die "AnswersFile 不存在：$AnswersFile" }
    try { $Answers = Get-Content $AnswersFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Die "AnswersFile 不是有效 JSON：$($_.Exception.Message)" }
    $aiKeys = @("memoryTier", "baseUrl", "apiKey", "model")
    $aiGiven = @($aiKeys | Where-Object { $Answers.$_ }).Count
    if ($aiGiven -ne 0 -and $aiGiven -ne 4) {
        Die "AnswersFile 的 AI 字段必须要么全给（memoryTier/baseUrl/apiKey/model），要么全不给（安装阶段）；当前只给了 $aiGiven 个。"
    }
    if ($aiGiven -eq 4) {
        # 与交互路径同款净化：只保留可见 ASCII
        $Answers.baseUrl = (($Answers.baseUrl -replace "[^\x21-\x7E]", "")).TrimEnd("/")
        $Answers.apiKey  = ($Answers.apiKey  -replace "[^\x21-\x7E]", "")
        $Answers.model   = ($Answers.model   -replace "[^\x21-\x7E]", "")
        if (-not $Answers.baseUrl -or -not $Answers.apiKey -or -not $Answers.model) { Die "AnswersFile 字段净化后为空（疑似混入非 ASCII 字符）" }
        Log "静默模式（配置阶段）：答案来自 $AnswersFile"
    } else {
        Log "静默模式（安装阶段）：答案来自 $AnswersFile，本次不配置 AI"
    }
}

# 「浏览器与电脑操作」由安装向导的勾选框决定（heavyTools=0 → 不装）。
# 这是唯一一个在**安装阶段**就要生效的答案：内核安装时就得决定装不装
# agent-browser/chromium 与 cua-driver，装完再改要重跑 PM。
if ($Answers -and ($Answers.PSObject.Properties.Name -contains "heavyTools") -and ("$($Answers.heavyTools)" -eq "0")) {
    $SkipBrowser = $true
    $SkipComputerUse = $true
}

# 本次是否要做「配置阶段」的那几段（记忆档位 / AI 配置 / 微信 / gateway）。
# **只在静默模式（exe 调用）下才分阶段**：交互模式（install.bat 双击、没有 -AnswersFile）
# 必须照常走完整流程——那几段会用 Read-Host 采参数，若在这里判成 false 就等于把交互安装废掉。
$HasAiConfig = $true
if ($AnswersFile) {
    $HasAiConfig = [bool]($Answers -and $Answers.memoryTier -and $Answers.baseUrl -and $Answers.apiKey -and $Answers.model)
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

# ---------- 0. 随包内核与运行期约定（Hermes v0.22 架构） ----------
# 上游 v0.22 把重依赖整体交给 PM（pm/lock.json 逐件 sha256 钉死），仓库只承担
# 「checkout + Python 环境 + 构建 hermes 命令与 TUI/web」。因此发行版随包只剩两件：
#   hermes-agent.bundle  内核源码包（refs/heads/main 指向 pin commit，含 pin tag）
#   uv.exe               PM 的引导器（上游 Get-Uv 会优先复用运行期目录里的同版本 uv）
# 其余（CPython 3.14 / Node 26 / Chromium / PyPI 依赖）安装时由 PM 从官方 sha256 镜像
# 与国内索引取——不再有 assets-offline 那一套 1.5 GB 的随包素材。
# 上游 v0.22 的安装器只认 commit（没有 -Tag 参数），且要求它是 origin/main 的祖先。
# 随包内核是「快照仓库」：pin 的工作树重做成单提交仓库（树字节与 pin 一致、带 pin tag，
# 见 build-offline.ps1 的说明），所以这里的 commit 指的是**那个快照提交**，由构建时写进
# hermes-agent.commit。真实上游 commit 另存 hermes-agent.upstream-commit（仅审计）。
$PinTag = "v0.22.2"
$PinCommit = ""
# 随包素材有两种布局，必须都能找到：
#   ① 内嵌 payload 解压目录（用户机器上的常态）：<src>\hermes-agent.bundle
#   ② 开发仓库（从 build\ 里直接跑 Setup.exe 时 <src> 是仓库根）：<src>\build\minimal\hermes-agent.bundle
# 只认 ① 会得到"缺内核包：…\hermes-agent.bundle"——一条只有开发者才会踩到、但很难自查的错误。
function Get-ShippedAsset([string]$name) {
    foreach ($base in @($SrcRoot, $PSScriptRoot)) {
        if (-not $base) { continue }
        $flat = Join-Path $base $name
        if (Test-Path -LiteralPath $flat) { return $flat }
        $nested = Join-Path (Join-Path $base "build\minimal") $name
        if (Test-Path -LiteralPath $nested) { return $nested }
        $nested2 = Join-Path (Join-Path $base "..\build\minimal") $name
        if (Test-Path -LiteralPath $nested2) { return ([IO.Path]::GetFullPath($nested2)) }
    }
    return (Join-Path $SrcRoot $name)
}

$commitStamp = Get-ShippedAsset "hermes-agent.commit"
if (Test-Path $commitStamp) {
    $c = (Get-Content $commitStamp -Raw -ErrorAction SilentlyContinue)
    if ($c) { $PinCommit = $c.Trim() }
}
$KernelBundle = Get-ShippedAsset "hermes-agent.bundle"
$ShippedUv    = Get-ShippedAsset "uv.exe"

# 国内索引：PM 只把 UV_* / PIP_* 的「索引类」设置转发给 uv（pm/index_config.py），
# 这是官方口子，不是改上游代码。用户已自设则尊重不覆盖。
if (-not $env:UV_DEFAULT_INDEX)    { $env:UV_DEFAULT_INDEX    = "https://pypi.tuna.tsinghua.edu.cn/simple" }
if (-not $env:PIP_INDEX_URL)       { $env:PIP_INDEX_URL       = "https://pypi.tuna.tsinghua.edu.cn/simple" }
if (-not $env:npm_config_registry) { $env:npm_config_registry = "https://registry.npmmirror.com" }
# 引导阶段的 CPython 由 uv 自己下载（不经过 PM），镜像变量只在这一段生效。
# 不设的话会直连 GitHub 的 python-build-standalone，境内经常几十 KB/s。
if (-not $env:UV_PYTHON_INSTALL_MIRROR) {
    $env:UV_PYTHON_INSTALL_MIRROR = "https://registry.npmmirror.com/-/binary/python-build-standalone"
}

# ---------- 0.15 代理自愈 ----------
# 装过 Clash / v2ray / sing-box 的机器常留着 HTTP(S)_PROXY 指向 127.0.0.1:7897，而代理进程
# 早就退了。uv / pip / node 走的是进程环境，于是每次连接都被内核直接拒绝（WSAECONNREFUSED
# 10061）；.NET 的联网预检读的是 WinHTTP 设置，看不到这类死代理，于是预检通过、安装半路才炸
# （2026-10-26 实录：uv 报 "tunnel error: failed to create underlying connection"）。
# 开跑前逐个探端口，连不上就摘掉变量——比让用户对着 uv 的英文栈猜要体面得多。
function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 800) {
    if (-not $HostName -or $Port -le 0) { return $true }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.Close(); return $false }
        $c.EndConnect($iar); $c.Close(); return $true
    } catch { return $false }
}
$deadProxies = @()
foreach ($pxName in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
    $pxVal = [Environment]::GetEnvironmentVariable($pxName)
    if (-not $pxVal) { continue }
    # 只处理带显式端口的写法（host:port / scheme://host:port）；没说端口的没法探，别乱摘
    if ($pxVal -notmatch ':\d{1,5}\s*$') { continue }
    $pxHost = ""; $pxPort = 0
    try {
        $pxProbe = $pxVal.Trim()
        if ($pxProbe -notmatch '://') { $pxProbe = "http://" + $pxProbe }
        $pxUri = [Uri]$pxProbe
        if ($pxUri.Host) { $pxHost = $pxUri.Host; $pxPort = $pxUri.Port }
    } catch { }
    if (-not $pxHost -or $pxPort -le 0) { continue }
    if (Test-TcpPort $pxHost $pxPort) { continue }
    Remove-Item ("Env:" + $pxName) -ErrorAction SilentlyContinue
    $deadProxies += ("$pxName=$pxVal")
}
if ($deadProxies.Count -gt 0) {
    Warn ("已忽略连不上的代理设置（端口没有在听）：" + ($deadProxies -join "，") + "；本次安装全程直连。")
}
# 国内镜像直连更快更稳：塞进 NO_PROXY，别让用户的外网代理绕一圈。
foreach ($npName in @('NO_PROXY', 'no_proxy')) {
    $npList = @()
    $npCur = [Environment]::GetEnvironmentVariable($npName)
    if ($npCur) { $npList += ($npCur -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    foreach ($d in @('registry.npmmirror.com', 'pypi.tuna.tsinghua.edu.cn', 'mirrors.aliyun.com', 'mirrors.ustc.edu.cn', 'localhost', '127.0.0.1')) {
        if ($npList -notcontains $d) { $npList += $d }
    }
    Set-Item -Path ("Env:" + $npName) -Value ($npList -join ",") -ErrorAction SilentlyContinue
}

# 运行期目录（PM store / 工具二进制）固定在数据目录内，不写用户主目录与系统盘别处。
# 上游默认就是 $HermesHome\tools；显式设一次是为了让「预置 uv」与上游取到同一个槽位。
if (-not $env:HERMES_RUNTIME_DIR) { $env:HERMES_RUNTIME_DIR = Join-Path $HermesHome "tools" }
New-Item -ItemType Directory -Force -Path $HermesHome, $env:HERMES_RUNTIME_DIR | Out-Null

function Test-Done([string]$step) { (Test-Path $StateFile) -and ((Get-Content $StateFile -ErrorAction SilentlyContinue) -contains $step) }
function Mark-Done([string]$step) { if (-not (Test-Done $step)) { Add-Content -Path $StateFile -Value $step } }
Log "安装状态文件：$StateFile"

# 预置 uv：上游 Get-Uv 先看 <运行期目录>\uv-<版本>-<target>\uv.exe，命中就不再下载。
# 两个硬条件：版本号必须等于 pm/lock.json 的 uv pin（否则判定「不是我要的」并重下）；
# target 按机器架构取（ARM64 机器上随包的 x64 uv 用不了，上游会自己下 arm64）。
$UvPinVersion = "0.12.3"
# 随包素材里的 uv.version 由 build-offline.ps1 从上游 pm/lock.json 抄出——有就以它为准，
# 免得 pin 升级时这里忘了改（槽位名对不上 → 上游判定「不是我要的」并重新下载）。
$uvVerFile = Get-ShippedAsset "uv.version"
if (Test-Path $uvVerFile) {
    $v = (Get-Content $uvVerFile -Raw -ErrorAction SilentlyContinue)
    if ($v) { $UvPinVersion = $v.Trim() }
}
$_uvArch = "x64"
try {
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE -eq 'ARM64') { $_uvArch = "arm64" }
} catch { }
if ($_uvArch -eq "x64" -and (Test-Path $ShippedUv)) {
    $uvSlot = Join-Path $env:HERMES_RUNTIME_DIR "uv-$UvPinVersion-win32-x64"
    if (-not (Test-Path (Join-Path $uvSlot "uv.exe"))) {
        New-Item -ItemType Directory -Force -Path $uvSlot | Out-Null
        Copy-Item $ShippedUv (Join-Path $uvSlot "uv.exe") -Force
        Ok "uv 已预置（$UvPinVersion，随包）"
    }
}

# PM 托管解释器的解析：<HERMES_HOME>\installs\<key>\facts.json 的 packages.venv.environment。
# 这是上游 pm/environments.py:_recorded_venv 的同一口径；再回落 v0.21 的旧布局。
# 微信依赖补齐、内核补丁、以及 GUI 侧的扫码脚本都靠它，别再写死 hermes-agent\venv。
function Get-HermesPython {
    $cands = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($f in @(Get-ChildItem (Join-Path $HermesHome "installs\*\facts.json") -ErrorAction SilentlyContinue)) {
            try {
                $d = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $venv = $d.packages.venv.environment
                if ($venv) { [void]$cands.Add((Join-Path $venv "Scripts\python.exe")) }
            } catch { }
        }
    } catch { }
    [void]$cands.Add((Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"))   # v0.21 遗留布局
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

# ---------- 0.1 环境检查 ----------
if ($env:OS -ne "Windows_NT") { Die "本脚本仅用于 Windows 原生路径；Linux/macOS 用 install.sh" }
# git 不预检：上游 Stage-Prerequisites 会从 pm/lock.json 的 pin 落位 PortableGit。
Log "安装说明见 docs\INSTALL.md"
Progress "precheck"

# ---------- 1. 记忆库位置 ----------
# 默认 %USERPROFILE%\vault；首次安装可在向导里改（例如放 D 盘，或指向已有的文档文件夹）。
# 一旦定下就不再变：五文件、注入槽位、程序端路径全都按它铺。
if (-not $VaultDir) { $VaultDir = "$HOME\vault" }
$VaultDir = $VaultDir.Trim().Trim('"').TrimEnd('\')
if (-not [IO.Path]::IsPathRooted($VaultDir)) { Die "记忆库位置必须是绝对路径（实际：$VaultDir）" }
$VaultDir = [IO.Path]::GetFullPath($VaultDir).TrimEnd('\')

# ---------- 1.9 联网预检（只在需要装内核/运行环境时执行） ----------
# 上游要用 PM 从 GitHub（失败时回退 hermes-assets 镜像）下载 Python / Node / PortableGit 等，
# 没网时会在内核段深处失败，报一串英文下载错误——提前用中文说清楚。
function Test-NetUrl([string]$url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = "HEAD"
        $req.Timeout = 8000
        $req.Proxy = [System.Net.WebRequest]::DefaultWebProxy
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch [System.Net.WebException] {
        # 能拿到 HTTP 响应（403/404 也算）说明网络是通的，只是这个路径不存在
        return ($_.Exception.Response -ne $null)
    } catch { return $false }
}

# 索引镜像自检：默认清华源偶尔抽风（维护窗口/被墙/DNS 污染），换阿里或官方，别让用户在
# 装到一半时收到一屏 pip 超时。用户自己设过索引就完全不动。
function Test-IndexUrl([string]$Url) {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return $true }  # 没 curl 就别乱判
    try {
        $probe = $Url.TrimEnd('/') + "/"
        $code = [string](& curl.exe -s -o NUL --noproxy "*" -m 8 -w "%{http_code}" $probe)
        return ($code -match '^[23]')
    } catch { return $false }
}
if ($env:UV_DEFAULT_INDEX -eq "https://pypi.tuna.tsinghua.edu.cn/simple") {
    if (-not (Test-IndexUrl $env:UV_DEFAULT_INDEX)) {
        $picked = ""
        foreach ($alt in @("https://mirrors.aliyun.com/pypi/simple", "https://pypi.org/simple")) {
            if (Test-IndexUrl $alt) { $picked = $alt; break }
        }
        if ($picked) {
            Warn "清华 PyPI 镜像连不上，本次改用 $picked"
            $env:UV_DEFAULT_INDEX = $picked
            $env:PIP_INDEX_URL = $picked
        } else {
            Warn "清华 / 阿里 / 官方 PyPI 都探不通：依赖安装大概率会失败，先查网络。"
        }
    }
}

# ---------- 2. 上游内核（vendored 官方安装器 + 随包 git bundle，pin commit） ----------
# 「已装」判据沿用 2026-09-16 的结论：CLI 真的跑得起来才算装上，文件在场不算。
# 但**跑得起来还不够**：0.1.0 装的是 Hermes v0.21.0，它的 CLI 也跑得起来；只判可用
# 会把 0.1.0 用户的升级悄悄跳过，装完显示 0.2.0、跑的还是旧内核。所以按版本号判定。
$WantHermesVersion = "0.22.2"
$workingCli = Get-WorkingHermesCli
$haveVer = if ($workingCli) { Get-HermesVersion $workingCli } else { "" }
if ($workingCli -and $haveVer -eq $WantHermesVersion) {
    Log "上游内核：已安装 v$haveVer，跳过"
    Mark-Done "upstream"
} else {
    if ($workingCli) {
        # 现有安装比本发行版还新：不降级。降级会动到用户正在用的内核与数据库 schema，
        # 而且没有任何回滚保证——宁可停在这里说清楚。
        if ($haveVer -and (Compare-Version $haveVer $WantHermesVersion) -gt 0) {
            Die ("检测到已有的 Hermes v$haveVer 比本发行版锁定的 v$WantHermesVersion 更新。" +
                 [Environment]::NewLine + "为避免降级损坏现有数据，安装已中止。" +
                 [Environment]::NewLine + "可选：① 换到更新的 HerMemory 发行版；② 先卸载现有 Hermes 再装；" +
                 [Environment]::NewLine + "③ 把数据目录改到别处（安装位置页可改「数据存储位置」）做并存安装。")
        }
        Warn ("检测到 Hermes v" + $(if ($haveVer) { $haveVer } else { "未知" }) + "（本发行版锁定 v$WantHermesVersion），将升级内核与运行环境。")
        # 接管已有安装：先停网关、备份配置与凭据。内核升级不会删它们，但用户值得有一个就地回滚点。
        $ts = Get-Date -Format "yyyyMMdd-HHmmss"
        # 旧网关不杀，新网关会与它抢同一份 state.db（schtasks /Delete 只删任务、不杀进程）
        if (Test-Path -LiteralPath $HermesCli) {
            Log "停止旧网关……"
            Run-Quiet $HermesCli gateway stop
            Start-Sleep -Seconds 1
        }
        $backupOk = $true
        # ⚠ 变量名不能叫 $src：PowerShell 大小写不敏感，会顶掉上面的 $SrcRoot
        # → 之后所有"随包素材在哪"的判断全错（2026-10-26 同学机器实录：升级 0.21→0.22 时
        # $SrcRoot 变成 <HERMES_HOME>\.env，报「缺 vendored 上游安装器 …\.env\scripts\…」）。
        foreach ($f in @("config.yaml", ".env")) {
            $srcFile = Join-Path $HermesHome $f
            if (Test-Path $srcFile) {
                $bak = Join-Path $HermesHome ("$f.pre-hermemory-" + $ts)
                try { Copy-Item $srcFile $bak -Force -ErrorAction Stop } catch { $backupOk = $false; Warn "备份 $f 失败：$($_.Exception.Message)" }
            }
        }
        if ($backupOk) { Log "已备份现有配置：config.yaml / .env（.pre-hermemory-$ts）" }
        else { Warn "配置备份未完全成功；升级仍会继续，但回滚点可能不完整。" }

        # 旧 checkout 必须整体挪开，不能在原地切分支。
        # 原因（2026-10-21 实测）：仓库 contributors/emails/ 下有两个**仅大小写不同**的文件
        # （agent@Agents-Mac-mini.local / agent@agents-Mac-mini.local），NTFS 上只能存在一个，
        # 于是 git 永远把其中一个报成 modified；stash 也消不掉，`git checkout` 必然被拒：
        #   "Please commit your changes or stash them before you switch branches."
        # 上游 installer 对此没有兜底（它假定 Windows 能 stash 干净），升级会硬停在内核段。
        # 挪开之后上游走「全新克隆」路径，从随包 bundle 拿到干净树；旧目录原样保留可回滚。
        $oldRepo = Join-Path $HermesHome "hermes-agent"
        if (Test-Path (Join-Path $oldRepo ".git")) {
            $aside = "$oldRepo.pre-$($WantHermesVersion)-$ts"
            try {
                Move-Item -LiteralPath $oldRepo -Destination $aside -ErrorAction Stop
                Log "旧内核目录已移到 $aside（确认新版可用后可删除）"
            } catch {
                Warn "旧内核目录挪不动（可能有进程占用）：$($_.Exception.Message)"
                Warn "升级可能在 git 切分支处失败；若失败，请先关闭网关与托盘程序后重试。"
            }
        }
        # 内核换了版本 → 旧的网关计划任务跑的仍是旧 venv 的启动脚本，必须让它重建
        $script:KernelUpgraded = $true
        try { Set-Content -LiteralPath $HmUpgradeMarker -Value "$haveVer -> $WantHermesVersion" -Encoding ASCII -Force } catch { }
    }
    if ($SkipUpstream) { Die "hermes CLI 不可用，且指定了 -SkipUpstream" }
    if ((Test-Done "upstream") -or (Test-Path (Join-Path $HermesHome "hermes-agent"))) {
        Warn "检测到内核痕迹，但 hermes CLI 无法运行（PM 环境可能已失效）→ 将重建内核与环境。"
    }

    if (-not ((Test-NetUrl "https://github.com") -or (Test-NetUrl "https://hermes-assets.nousresearch.com"))) {
        Die ("无法联网：安装需要下载 Python / Node / 依赖（GitHub，或镜像 hermes-assets.nousresearch.com）。" +
             [Environment]::NewLine + "请检查网络或代理后重试。" +
             [Environment]::NewLine + "Windows 沙盒请在 .wsb 配置里启用 <Networking>Enable</Networking>。" +
             [Environment]::NewLine + "（已装好的机器修复重跑不需要这一步；本机还没装好。）")
    }

    # ---------- 2.05 预置运行时大件（git / python / node） ----------
    # 随包的 payload\artifacts\<sha256> 直接塞进 PM 的下载缓存，PM 校验哈希后跳过下载。
    # 国内直连镜像只有 200 KB/s 左右，这三个合计 149 MB——预置后首装不再卡在"installing git"。
    # 两种布局都要认：① 内嵌 payload 解压目录 <src>\artifacts；
    # ② 开发仓库从 build\ 直跑时在 <src>\build\minimal\artifacts（与 Get-ShippedAsset 同口径）。
    $artRoot = ""
    foreach ($cand in @((Join-Path $SrcRoot "artifacts"), (Join-Path $SrcRoot "build\minimal\artifacts"))) {
        if (Test-Path -LiteralPath $cand) { $artRoot = $cand; break }
    }
    if ($artRoot) {
        $toolRoot = Join-Path $HermesHome "tools"
        New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
        # 缓存文件名必须保留原始后缀：PM 的 extract() 只看后缀决定解包方式
        # （.zip / .tar.gz），一律写成 artifact.bin 会让 node / python / ripgrep
        # 全部报 "unsupported archive"（2026-10-26 实测）。
        $artNames = @{}
        $rtManifest = Get-ShippedAsset "runtime.json"
        if (Test-Path -LiteralPath $rtManifest) {
            try {
                $rtData = Get-Content -LiteralPath $rtManifest -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($a in $rtData.artifacts) {
                    if ($a.sha256 -and $a.name) { $artNames["$($a.sha256)".ToLower()] = "$($a.name)" }
                }
            } catch { Warn "runtime.json 读不出来（$($_.Exception.Message)），改用文件头推断后缀" }
        }
        $seeded = 0
        foreach ($f in Get-ChildItem -LiteralPath $artRoot -File) {
            # 只预置 sha256 命名的归档：目录里可能混入 .txt/.sha 之类说明文件
            if ($f.Name -notmatch '^[0-9a-fA-F]{64}$') { continue }
            $sha = $f.Name.ToLower()
            $leaf = $artNames[$sha]
            if (-not $leaf) {
                # 没有清单时的兜底：按文件头猜（PM 只认 zip 与 tar.*，git 的 SFX 靠包名分发）
                $head = New-Object byte[] 4
                try { $fs = [IO.File]::OpenRead($f.FullName); [void]$fs.Read($head, 0, 4); $fs.Close() } catch { }
                if ($head[0] -eq 0x50 -and $head[1] -eq 0x4B) { $leaf = "package-$sha.zip" }
                elseif ($head[0] -eq 0x1F -and $head[1] -eq 0x8B) { $leaf = "package-$sha.tar.gz" }
                elseif ($head[0] -eq 0x4D -and $head[1] -eq 0x5A) { $leaf = "package-$sha.7z.exe" }
                else { $leaf = "package-$sha.bin" }
            }
            $dir = Join-Path $toolRoot ("fetch-" + $sha)
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            # 清掉旧版本留下的错误命名（artifact.bin），否则 PM 会一直用那个解不开的文件
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dir $leaf) -Force
            $seeded++
        }
        if ($seeded -gt 0) { Log "已预置 $seeded 个运行时产物（git / python / node），无需下载" }
        else { Warn "随包运行时产物目录里没有 sha256 命名的文件：$artRoot" }
    } else {
        Warn "未发现随包运行时产物目录（artifacts\），本次安装需要联网下载 git / python / node。"
    }

    # ---------- 2.055 PM 运行时 wheelhouse（离线装 pm 自己的 4 个依赖） ----------
    # PM 引导时会先给它自己建一个 runtime venv（packaging / ruamel.yaml / tomli-w / truststore）。
    # 上游这一步固定走 PyPI 官方源且 `--no-config`，**刻意不吃镜像**——实测把 UV_INDEX_URL 指向
    # 清华后 `uv sync --locked` 直接报 "lockfile needs to be updated"。于是国内 DNS 一旦解析不了
    # files.pythonhosted.org（os error 11002），安装就死在这里（2026-10-26 同学机器实录）。
    # 随包带这 4 个 wheel（合计约 250 KB），由 vendored 补丁在离线模式下安装。
    $pmWh = ""
    foreach ($pmWhCand in @((Join-Path $SrcRoot "pm-wheelhouse"), (Join-Path $SrcRoot "build\minimal\pm-wheelhouse"))) {
        if (Test-Path -LiteralPath $pmWhCand) { $pmWh = $pmWhCand; break }
    }
    if ($pmWh -and (Test-Path -LiteralPath $pmWh)) {
        $pmWhCount = @(Get-ChildItem -LiteralPath $pmWh -Filter *.whl -File -ErrorAction SilentlyContinue).Count
        if ($pmWhCount -gt 0) {
            $env:HERMEMORY_PM_WHEELHOUSE = $pmWh
            Log "PM 运行时 wheelhouse 已就位（$pmWhCount 个 wheel，离线安装）"
        }
    }

    # ---------- 2.06 引导 Python：随包解压，零下载 ----------
    # 上游 Get-BootstrapPython 用 `uv python install` 从镜像下 CPython。这一步是整条安装链上
    # 唯一「必须联网才能拿到解释器」的地方，也最容易死在别人的网络配置上（见 0.15 的死代理）。
    # 随包本来就带了与 pm/lock.json 完全一致的 CPython，这里按 uv 的受管解释器布局解压到位：
    # uv 的 find 会直接命中，引导阶段不需要任何网络。
    $PyPinVersion = "3.14.7"
    $PyPinSha     = "5d9242012dded591d723a3a572dda265173ad58d8a3e6fdbc6dac8f94f36c80a"
    $PyDirName    = "cpython-3.14.7-windows-x86_64-none"
    $pyMan = Get-ShippedAsset "python.json"
    if (Test-Path -LiteralPath $pyMan) {
        try {
            $pyMeta = Get-Content -LiteralPath $pyMan -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pyMeta.version) { $PyPinVersion = "$($pyMeta.version)" }
            if ($pyMeta.sha256) { $PyPinSha = "$($pyMeta.sha256)".ToLower() }
            if ($pyMeta.dir) { $PyDirName = "$($pyMeta.dir)" }
        } catch { Warn "python.json 读不出来（$($_.Exception.Message)），按内置 pin 处理" }
    }
    $pyArchArm = $false
    try {
        if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE -eq 'ARM64') { $pyArchArm = $true }
    } catch { }
    if ($pyArchArm) {
        Warn "本机是 ARM64：随包 CPython 只有 x64 版，引导阶段交给 uv 自行下载。"
    } else {
        $pyRoot = Join-Path $HermesHome "python"
        $pyDir = Join-Path $pyRoot $PyDirName
        $pyExe = Join-Path $pyDir "python.exe"
        if (-not (Test-Path -LiteralPath $pyExe)) {
            $pyArt = ""
            if ($artRoot) { $pyArt = Join-Path $artRoot $PyPinSha }
            if ($pyArt -and (Test-Path -LiteralPath $pyArt)) {
                $okHash = $true
                try {
                    $pyHash = (Get-FileHash -LiteralPath $pyArt -Algorithm SHA256).Hash.ToLower()
                    if ($pyHash -ne $PyPinSha) { $okHash = $false; Warn "随包 CPython 哈希不符（期望 $PyPinSha，实际 $pyHash），不使用" }
                } catch { $okHash = $false; Warn "随包 CPython 校验失败：$($_.Exception.Message)" }
                if ($okHash) {
                    $pyStage = Join-Path $HermesHome (".python-stage-" + [Guid]::NewGuid().ToString("N"))
                    try {
                        New-Item -ItemType Directory -Force -Path $pyStage | Out-Null
                        if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { throw "本机没有 tar.exe（Windows 10 1803 以前）" }
                        & tar.exe -xzf $pyArt -C $pyStage 2>$null
                        if ($LASTEXITCODE) { throw "tar 解压失败（退出码 $LASTEXITCODE）" }
                        $pyInner = @(Get-ChildItem -LiteralPath $pyStage -Directory)
                        if ($pyInner.Count -ne 1) { throw "归档顶层目录数量异常（$($pyInner.Count)）" }
                        if (-not (Test-Path -LiteralPath (Join-Path $pyInner[0].FullName "python.exe"))) { throw "归档里没有 python.exe" }
                        New-Item -ItemType Directory -Force -Path $pyRoot | Out-Null
                        if (Test-Path -LiteralPath $pyDir) { Remove-Item -LiteralPath $pyDir -Recurse -Force -ErrorAction SilentlyContinue }
                        Move-Item -LiteralPath $pyInner[0].FullName -Destination $pyDir -ErrorAction Stop
                        Log "已解压随包 CPython $PyPinVersion → $pyDir"
                    } catch {
                        Warn "随包 CPython 解压失败：$($_.Exception.Message)（引导阶段改为联网下载）"
                    } finally {
                        Remove-Item -LiteralPath $pyStage -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            } else {
                Warn "随包目录里没有 CPython（$PyPinSha）：引导阶段需要联网下载 Python。"
            }
        }
        $pyReady = $false
        if (Test-Path -LiteralPath $pyExe) {
            try {
                $pyVer = (& $pyExe -c "import sys;print('%d.%d.%d'%sys.version_info[:3])" 2>$null) -join ""
                if ($LASTEXITCODE -eq 0 -and "$pyVer".Trim() -eq $PyPinVersion) { $pyReady = $true }
                else { Warn "随包 CPython 版本不符：期望 $PyPinVersion，实际 $pyVer" }
            } catch { Warn "随包 CPython 跑不起来：$($_.Exception.Message)" }
        }
        if ($pyReady) {
            # uv 按 UV_PYTHON_INSTALL_DIR 找受管解释器；固定在数据目录内，不写用户主目录。
            $env:UV_PYTHON_INSTALL_DIR = $pyRoot
            # 上游 Get-BootstrapPython 优先用这个（vendored 补丁），连 uv 都不用问。
            $env:HERMEMORY_BOOTSTRAP_PYTHON = $pyExe
            Ok "引导 Python 就绪（$PyPinVersion，随包，零下载）"
        }
    }


    $up = Get-ShippedAsset "scripts\upstream-install.ps1"
    if (-not (Test-Path $up)) { Die "缺 vendored 上游安装器：$up（发行包不完整，请重新获取 HerMemory）" }
    if (-not (Test-Path $KernelBundle)) { Die "缺内核包：$KernelBundle（发行包不完整，请重新获取 HerMemory）" }

    # 让上游 repository 阶段从随包 bundle 取源：零网络、原子落位、pin 可验证。
    # 已存在的 checkout 也会被先 remote set-url 再 fetch（上游 Stage-Repository 行为），
    # 所以重装/修复同样会被拉回随包的 pin，而不是漂到 main。
    $env:HERMES_REPO_URL = $KernelBundle

    $upArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $up,
        '-Branch', 'main',
        '-NonInteractive',
        '-HermesHome', $HermesHome,
        '-InstallDir', (Join-Path $HermesHome 'hermes-agent')
    )
    # 快照 commit 在场才做 -Commit 钉住；缺戳时退回「按 main 落位」——宁可少验一层，
    # 也好过把错 sha 传进去让上游在 merge-base 处硬失败。
    if ($PinCommit) { $upArgs += @('-Commit', $PinCommit) }
    if ($SkipBrowser)     { $upArgs += '-SkipBrowser' }
    if ($SkipComputerUse) { $upArgs += '-SkipComputerUse' }

    if ($PinCommit) { Log "运行上游安装器（pin $PinTag / $($PinCommit.Substring(0,12))）……" }
    else { Log "运行上游安装器（pin $PinTag，按 main 落位）……" }
    if ($SkipBrowser)     { Log "按安装选项：不安装浏览器工具（agent-browser + Chromium）" }
    if ($SkipComputerUse) { Log "按安装选项：不安装电脑操作驱动（cua-driver）" }

    # 独立子进程跑：上游以 exit 码表达成败（-File 形态 RunAsFile=true）。
    # 直接 `& $up` 不行——它正常结束时**不 exit 0**，$LASTEXITCODE 会留着最后一条
    # 原生命令的残值，失败也可能被读成 0。子进程退出码是唯一可靠的判据。
    # 输出实时转发（exe 逐行解析显示），同时留尾部用于失败诊断。
    $upTail = New-Object System.Collections.Generic.List[string]
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"   # 原生命令的 stderr 在 Stop 下会变成终止性错误
    $upExit = -1
    try {
        & powershell.exe @upArgs 2>&1 | ForEach-Object {
            $ln = "$_"
            [void]$upTail.Add($ln)
            if ($upTail.Count -gt 300) { $upTail.RemoveAt(0) }
            Write-Host $ln
        }
        $upExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap }

    if ($upExit -ne 0) {
        $tailText = (($upTail | Select-Object -Last 12) -join [Environment]::NewLine)
        # 常见失败给可执行的下一步，别让用户对着 uv 的英文栈猜。
        $allTail = (($upTail | Select-Object -Last 16) -join "`n")
        $hint = ""
        if ($allTail -match "bootstrap Python installation failed|python_install_failed") {
            $hint += [Environment]::NewLine + "提示：卡在「引导 Python」。本发行版随包带了 CPython，正常情况下这里不联网；" +
                     [Environment]::NewLine + "出现这句说明随包素材没用上（或本机是 ARM64）。可依次尝试：" +
                     [Environment]::NewLine + "  ① 退出 Clash / v2ray / sing-box 等代理软件后重装；" +
                     [Environment]::NewLine + "  ② 重新下载 Setup.exe（安装包可能不完整）；" +
                     [Environment]::NewLine + "  ③ 换一个网络环境重试。"
        }
        if ($allTail -match "dns error|11001|11002|WSAHOST|Name or service not known") {
            $hint += [Environment]::NewLine + "提示：域名解析失败（DNS）。多数是代理软件/系统 DNS 抽风：" +
                     [Environment]::NewLine + "  ① 把网卡 DNS 改成 223.5.5.5 或 119.29.29.29 后点「重新安装」；" +
                     [Environment]::NewLine + "  ② 或先退出代理软件再重试。已完成步骤会自动跳过。"
        }
        if ($allTail -match "tunnel error|10061|\bproxy\b|Proxy") {
            $hint += [Environment]::NewLine + "提示：日志里出现代理或「连接被拒」。多为代理软件已退出但系统里还留着代理设置；" +
                     [Environment]::NewLine + "关闭代理软件（或让它开机运行）后重装即可。"
        }
        Die ("上游内核安装失败（退出码 $upExit）。" + [Environment]::NewLine + $tailText + $hint +
             [Environment]::NewLine + "已完成步骤会自动跳过；排除问题后点「重新安装」继续。")
    }

    # ---------- 目录继承权限（2026-10-23 事故修复）----------
    # 上游以管理员身份解包 uv / python-build-standalone 时，部分文件会带上
    # 「所有者=Administrators、只授 SYSTEM/Administrators」且**切断继承**的 ACL。
    # 后果：普通用户（非提权）执行 tools\python.exe 直接「拒绝访问」——
    # 登录自启的计划任务与应用内「启动」全部静默失败，只有提权进程能拉起网关。
    # 这里把继承恢复成用户目录的默认值（不删任何显式 ACE，只重新接上继承）。
    try {
        # 只扫 PM 落地的两棵大树（uv / python-build-standalone / venv）；hermes-agent 是 git 检出，
        # 继承本来就是对的。整棵 hermes 扫一遍要好几分钟，用户会以为卡死。
        foreach ($sub in @('tools', 'installs')) {
            $p = Join-Path $HermesHome $sub
            if (Test-Path $p) { & icacls $p /inheritance:e /T /C *> $null }
        }
        Ok "已恢复目录继承权限（非提权进程可执行 tools\python.exe）"
    } catch {
        Warn "恢复目录继承权限失败：$($_.Exception.Message)（网关可能无法随登录自启）"
    }

    $workingCli = Get-WorkingHermesCli
    if (-not $workingCli) { Die (Format-CliBroken $HermesCli) }
    Ok "hermes CLI 就绪"
    Mark-Done "upstream"
}

$HermesCli = Get-WorkingHermesCli
if (-not $HermesCli) { Die "找不到可运行的 hermes CLI（期望 $HermesHome\bin\hermes.exe）。内核没装好就删掉 $StateFile 后重跑。" }

# ---------- 2.45 微信通道依赖（PM 的 messaging extra） ----------
# v0.22 政策：平台 SDK 不进 [all]，缺了只给一句「hermes pm install --extra messaging」
# 的提示（pm/extras.py install_hint）。这里替用户执行那条提示——否则「扫码即用」不成立。
# 早期版本是往 venv 里 uv pip install aiohttp/qrcode，v0.22 的 venv 由 PM 托管，
# 只能走 extra 这一条受支持的口子。
$prevEapWx = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $wxDepOut = & $HermesCli pm install --extra messaging 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "微信通道依赖已就位（messaging extra）" }
    else {
        Warn "messaging extra 安装失败：扫码可能不可用。uv/pm 输出末尾："
        ($wxDepOut | Select-Object -Last 3) | ForEach-Object { Warn "  $_" }
    }
} catch {
    Warn "messaging extra 安装异常：$($_.Exception.Message)"
} finally { $ErrorActionPreference = $prevEapWx }

# 「浏览器与电脑操作」的勾选如果与既有安装不同（修复安装时改了勾选），这里补一次：
# 内核已经装好时上游那一步不会重跑，declined 记录也不会更新——不补就等于勾选无效。
# 只在「确实还没记录」时才调 pm（那是几十秒的 sync），常规安装走不到。
function Get-DeclinedPackages {
    $names = @()
    try {
        foreach ($f in @(Get-ChildItem (Join-Path $HermesHome "installs\*\declined-packages.json") -ErrorAction SilentlyContinue)) {
            try {
                $d = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($d.declined) { $names += @($d.declined) }
            } catch { }
        }
    } catch { }
    return @($names | Select-Object -Unique)
}
if ($SkipBrowser -or $SkipComputerUse) {
    $declined = Get-DeclinedPackages
    $need = @()
    if ($SkipBrowser -and ($declined -notcontains 'agent-browser')) { $need += 'agent-browser' }
    if ($SkipComputerUse -and ($declined -notcontains 'cua-driver')) { $need += 'cua-driver' }
    if ($need.Count -gt 0) {
        $withoutArgs = @('pm', 'install')
        foreach ($n in $need) { $withoutArgs += '--without'; $withoutArgs += $n }
        $prevEapDecl = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $HermesCli @withoutArgs 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Ok ("已记录不安装：" + ($need -join '、')) }
            else { Warn ("记录不安装失败（" + ($need -join '、') + "）：可稍后手动执行 hermes pm install --without <name>") }
        } catch {
            Warn "记录不安装异常：$($_.Exception.Message)"
        } finally { $ErrorActionPreference = $prevEapDecl }
    }
}

# ---------- 2.5 内核 UX 补丁（发行版自有，幂等）：微信二维码改为链接+浏览器提示 ----------
$wxPy = Join-Path $HermesHome "hermes-agent\gateway\platforms\weixin.py"
$wxPatch = Join-Path $SrcRoot "scripts\patch_weixin_qr.py"
$wxPython = Get-HermesPython
if ((Test-Path $wxPy) -and (Test-Path $wxPatch) -and $wxPython) {
    & $wxPython $wxPatch $wxPy
}
# ---------- 2.6 每日新对话脚本 ----------
# 设置页「每日新对话」用 cron 的 `--script X --no-agent` 执行它；cron 只认
# $HERMES_HOME\scripts\ 下的文件，所以这里放一份。默认不创建定时任务（自动化默认关闭，
# 由用户在设置页自己开）。
$dailyDir = Join-Path $HermesHome "scripts"
$dailySrc = Join-Path $SrcRoot "scripts\hermemory_daily_new.py"
if (Test-Path $dailySrc) {
    New-Item -ItemType Directory -Force -Path $dailyDir | Out-Null
    Copy-Item $dailySrc (Join-Path $dailyDir "hermemory_daily_new.py") -Force
    Ok "每日新对话脚本已就位：$dailyDir"
}
Progress "upstream"

# ---------- 3. vault 结构 ----------
New-Item -ItemType Directory -Force -Path "$VaultDir\HerMemory\memory" | Out-Null
Ok "记忆库结构：$VaultDir\{用户文档, HerMemory\memory\}"

# ---------- 4. 出厂五文件（已存在绝不覆盖——那是记忆） ----------
foreach ($f in @("MEMORY.md","USER.md","SOUL.md","AGENTS.md","AUTOMATION.md")) {
    $dst = "$VaultDir\HerMemory\memory\$f"
    if (Test-Path $dst) { Log "已存在，跳过：$dst（不覆盖既有文件）" }
    else { Copy-Item "$SrcRoot\memory\$f" $dst; Ok "铺设出厂文件：HerMemory\memory\$f" }
}

# ---------- 4.5 使用文档进记忆库 ----------
New-Item -ItemType Directory -Force -Path "$VaultDir\HerMemory\docs" | Out-Null
Copy-Item "$SrcRoot\docs\*" "$VaultDir\HerMemory\docs\" -Recurse -Force
Ok "使用文档已就位：HerMemory\docs\"
Progress "files"

# ---------- 4.6 接管既有身份：先把对方的 SOUL/AGENTS 收进记忆库 ----------
# 否则下面 LinkOne 会把 Hermes 原有的 SOUL.md / .hermes.md 挪成备份，再用**出厂**人格建链，
# 用户的 AI 性格与规则就被悄悄换掉了（文件还在备份里，但 AI 读不到）。
function AdoptExistingIdentity([string]$srcFile, [string]$vaultFile) {
    try {
        if (-not (Test-Path -LiteralPath $srcFile)) { return }
        $it = Get-Item -LiteralPath $srcFile -Force
        if ($it.LinkType -eq "SymbolicLink" -or $it.Length -eq 0) { return }
        $existing = Get-Content -LiteralPath $srcFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($existing)) { return }
        $factoryPath = Join-Path $SrcRoot ("memory\" + (Split-Path -Leaf $vaultFile))
        $factory = if (Test-Path -LiteralPath $factoryPath) { Get-Content -LiteralPath $factoryPath -Raw } else { "" }
        $target = if (Test-Path -LiteralPath $vaultFile) { Get-Content -LiteralPath $vaultFile -Raw } else { "" }
        if ([string]::IsNullOrWhiteSpace($target) -or $target.Trim() -eq $factory.Trim()) {
            Copy-Item -LiteralPath $srcFile -Destination $vaultFile -Force
            Ok "保留既有身份文件：$vaultFile（来自 $srcFile）"
        }
    } catch { Warn "读取既有身份文件失败：$srcFile" }
}
AdoptExistingIdentity (Join-Path $HermesHome "SOUL.md")   "$VaultDir\HerMemory\memory\SOUL.md"
AdoptExistingIdentity (Join-Path $HOME ".hermes.md")      "$VaultDir\HerMemory\memory\AGENTS.md"

# ---------- 4.7 非默认记忆库：把文档与提示词里的 ~/vault 换成真实路径 ----------
# AGENTS.md 与 docs/ 里的路径是写给 AI 看的（它据此找 ONBOARDING、记忆文件）。记忆库一旦挪到
# D 盘，`~/vault/...` 就是错路径 —— 不替换的话，初次部署会去读一个不存在的文件。
$DefaultVault = [IO.Path]::GetFullPath("$HOME\vault").TrimEnd('\')
if (-not [string]::Equals($VaultDir, $DefaultVault, [StringComparison]::OrdinalIgnoreCase)) {
    $targets = @(Join-Path "$VaultDir\HerMemory\memory" "AGENTS.md")
    $targets += @(Get-ChildItem "$VaultDir\HerMemory\docs" -Filter *.md -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $nk = (New-Object Text.UTF8Encoding($false))
    foreach ($t in $targets) {
        try {
            if (-not (Test-Path -LiteralPath $t)) { continue }
            $text = [IO.File]::ReadAllText($t)
            if ($text -notmatch '~/vault') { continue }
            [IO.File]::WriteAllText($t, $text.Replace('~/vault', $VaultDir), $nk)
        } catch { Warn "改写路径失败：$t" }
    }
    Ok "记忆库位置：$VaultDir（文档与提示词已改用该路径）"
} else {
    Log "记忆库位置：$VaultDir（默认）"
}

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
        Warn "已有文件 $dst，已备份为 $bak，随后建立链接"
    }
    # 坑（2026-09-10 00:13 实测）：New-Item 符号链接失败抛的是【非终止错误】，
    # 不加 -ErrorAction Stop 时 catch 接不住 → 静默假成功 → HERMES_HOME 无 SOUL.md
    # → hermes 首次 load_config 播种默认身份，用户所见即"注入失效"。
    # 故：-ErrorAction Stop + 事后 LinkType 双验证。
    # **不降级 HardLink**（2026-09-10 16:30 实测否决）：硬链接绑定的是 inode，而 Obsidian /
    # VS Code 等编辑器保存一律走"写临时文件 + rename 覆盖"的原子替换 → vault 侧目录项换成
    # 新 inode，硬链接仍指旧 inode → 读到**陈旧内容且静默无报错**。那比此处一个响亮的 Die 更糟
    #（用户改了 SOUL/AGENTS 却不生效，无从排查）。目录级重定向同理必须用 junction——junction
    # 绑定"路径"而非 inode，不受原子替换影响（见 5.5 段 memories）。
    try { New-Item -ItemType SymbolicLink -Path $dst -Target $src -Force -ErrorAction Stop | Out-Null } catch { }
    $ex = if (Test-Path $dst) { Get-Item $dst -Force } else { $null }
    if (-not $ex -or $ex.LinkType -ne "SymbolicLink") {
        if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
        Die "符号链接创建失败。请以管理员身份重新运行 HerMemory 完成安装，或开启开发者模式（设置 → 更新与安全 → 开发者选项）。已完成步骤不会丢失，重新安装时自动跳过。"
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
        # **先整目录改名备份，再合并**。旧逻辑按"目标已存在就跳过"处理，而 §4 刚往 vault 铺了
        # 出厂空白 MEMORY.md/USER.md —— 接管别人的 Hermes 时，用户真记忆会被空模板顶掉，随后
        # 旧目录被 -Recurse 删除。这里改成：一个字节都不删，冲突的文件在 vault 里并存一份。
        $memStamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $memBak = "$memDir.pre-hermemory-$memStamp"
        Move-Item -LiteralPath $memDir -Destination $memBak -ErrorAction Stop
        Get-ChildItem $memBak -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($memBak.Length).TrimStart('\')
            $d = Join-Path $jTarget $rel
            if (-not (Test-Path $d)) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $d) | Out-Null
                Copy-Item $_.FullName $d -Force
                Warn "迁移既有记忆：$rel"
            } elseif ((Get-Item -LiteralPath $d).Length -eq 0) {
                Copy-Item $_.FullName $d -Force
                Warn "填补空文件：$rel"
            } else {
                # 冲突：vault 里已有内容。但如果那内容只是**出厂模板**（刚装好的新库），
                # 用户真记忆必须顶掉模板；否则 AI 读到的还是空模板，接管等于没发生。
                $factoryFile = Join-Path $SrcRoot ("memory\" + $rel)
                $isFactory = $false
                if (Test-Path -LiteralPath $factoryFile) {
                    try {
                        $a = Get-Content -LiteralPath $d -Raw -ErrorAction Stop
                        $b = Get-Content -LiteralPath $factoryFile -Raw -ErrorAction Stop
                        $isFactory = ($null -ne $a) -and ($a.Trim() -eq $b.Trim())
                    } catch { }
                }
                if ($isFactory) {
                    Copy-Item $_.FullName $d -Force
                    Warn "接管既有记忆（覆盖出厂模板）：$rel"
                } else {
                    $side = "$d.from-hermes-$memStamp"
                    Copy-Item $_.FullName $side -Force
                    Warn "同名记忆并存：$side（vault 原文件保留）"
                }
            }
        }
        Ok "旧 memories 已备份到 $memBak，并按上面清单合并"
    }
    New-Item -ItemType Junction -Path $memDir -Target $jTarget -ErrorAction Stop | Out-Null
    Ok "memories 已以 junction 挂载至 vault：$memDir -> $jTarget"
}

# ---------- 5.5 命令别名 hermemory ----------
# 用户装的是 HerMemory，终端里却要敲 hermes——补一个等价别名，纯转发，不带任何逻辑。
try {
    $aliasPath = Join-Path (Split-Path $HermesCli -Parent) "hermemory.cmd"
    $aliasBody = @"
@echo off
"%~dp0hermes.exe" %*
exit /b %errorlevel%
"@
    Set-Content -LiteralPath $aliasPath -Value $aliasBody -Encoding ASCII
    Ok "命令别名：hermemory（等价于 hermes）"
} catch { Warn "hermemory 别名写入失败：$($_.Exception.Message)" }

# ---------- 6. 品牌皮肤 ----------
# 先把"CLI 到底在不在"问清楚。不查的话，后面每一步都只是一句含糊的 CommandNotFoundException，
# 而按 `Test-Done "upstream"` 跳过内核安装的那条路径**不做任何 PATH / CLI 校验**（见文件头注释）。
if (-not (Test-Path $HermesCli)) {
    Die "hermes CLI 不存在：$HermesCli。内核未装好，或 HERMES_HOME 指向了别的目录（当前 $HermesHome）。"
}
# 文件在 ≠ 跑得起来：CLI 是 uv 造的启动器，内嵌解释器绝对路径，venv 失效后它就再也起不来。
if ((Run-Q $HermesCli --version) -ne 0) { Die (Format-CliBroken $HermesCli) }
New-Item -ItemType Directory -Force -Path "$HermesHome\skins" | Out-Null
Copy-Item "$SrcRoot\skins\hermemory.yaml" "$HermesHome\skins\hermemory.yaml" -Force
$_r = Run-QOut $HermesCli config set display.skin hermemory
if ($_r.Code -eq 0) { Ok "皮肤已配置：HerMemory（/skin 可切换）" }
else { Warn ("display.skin 写入失败（非致命）。可在运行时执行 /skin hermemory 手动切换。" + (Show-Tail $_r.Out)) }
# 配了不等于生效：皮肤 YAML 缺顶层 name 字段会被加载器静默丢弃（0.1.0 的旧文件就是这样，
# 回复前缀仍是默认的「⚕ Hermes」）。这里以 skin list 的实际结果为准。
$_skin = Run-QOut $HermesCli skin list
if ($_skin.Out -match "(?m)^\s*\*?\s*hermemory\s+user\b") { Ok "皮肤已生效：hermemory" }
else { Warn "皮肤未生效：hermemory.yaml 未被识别（检查文件顶层是否有 name: hermemory）" }

# ---------- 7. 时区 ----------
Log "时间注入取本机系统时钟。请在系统设置中确认时区为 (UTC+08:00) 北京。"

# ---------- 8. 时间注入开关 + 界面显示偏好 ----------
$_r = Run-QOut $HermesCli config set gateway.message_timestamps.enabled true
if ($_r.Code -eq 0) { Ok "时间注入已开启：每条用户消息头部自动附加本机时间" }
else { Die ("gateway.message_timestamps.enabled 写入失败。" + (Show-Tail $_r.Out)) }
$_r = Run-QOut $HermesCli config set display.language zh
if ($_r.Code -eq 0) { Ok "界面语言：中文" } else { Warn ("display.language 写入失败（非致命）" + (Show-Tail $_r.Out)) }
$_r = Run-QOut $HermesCli config set display.timestamps true
if ($_r.Code -eq 0) { Ok "对话时间标签 [HH:MM]：已开启" } else { Warn ("display.timestamps 写入失败（非致命）" + (Show-Tail $_r.Out)) }

# ---------- 9~11. 配置阶段：记忆档位 / AI 配置 / 微信接入 / gateway 服务 ----------
# 分阶段安装（2026-09-15 用户定：先选目录 → 安装 → 再填记忆与 API）：安装阶段整段跳过，
# 只装内核与文件；用户填完参数后向导再跑一次本脚本，靠断点续装只做这一段。
if (-not $HasAiConfig) {
    Log "安装阶段：跳过记忆档位、AI 配置、微信接入与 gateway 注册（向导收集完参数后会再运行一次）。"
} else {

# ---------- 9. 记忆档位 ----------
if (Test-Done "memory-tier") {
    Log "记忆档位：已完成，自动跳过"
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
Log "MEMORY / USER 容量设置"
Write-Host ""
Write-Host "  容量提升增强记忆能力，同时降低专注度。建议选择 1-2 档。"
Write-Host ""
Write-Host "  1. 紧凑：2200 / 1375（默认）"
Write-Host "  2. 标准：5000 / 3000"
Write-Host "  3. 详细：10000 / 5000"
Write-Host ""
$choice = Read-Host "请选择记忆档位（1/2/3）"
switch ($choice) {
    "2" { $memLimit = 5000;  $userLimit = 3000 }
    "3" { $memLimit = 10000; $userLimit = 5000 }
    default { $memLimit = 2200; $userLimit = 1375 }
}
}
$_r = Run-QOut $HermesCli config set memory.memory_char_limit $memLimit
if ($_r.Code -ne 0) { Die ("memory.memory_char_limit 写入失败" + (Show-Tail $_r.Out)) }
$_r = Run-QOut $HermesCli config set memory.user_char_limit $userLimit
if ($_r.Code -ne 0) { Die ("memory.user_char_limit 写入失败" + (Show-Tail $_r.Out)) }
Ok "记忆档位：MEMORY $memLimit / USER $userLimit 字符（调整：memory-size.sh）"
Mark-Done "memory-tier"
}
Progress "memory-tier"

# ---------- 9.5/9.6 配置 AI（用户流程 2：地址先验证，Key 后验证；Key 阶段输 1 可返回地址；完成后 AI 上线） ----------
if (Test-Done "config-ai") {
    Log "配置 AI：已完成，自动跳过"
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
    if ($httpCode -eq "401" -or $httpCode -eq "403") { Die "[$httpCode] 认证未通过。请检查 API Key 是否正确且已启用。" }
    if ($httpCode -eq "000" -or $httpCode -eq "" -or $null -eq $httpCode) { Die "[连接超时] 无法连接 $provBase。请检查网络或代理设置。" }
    $ids = @()
    if ($models -and $models.data) { $ids = @($models.data | ForEach-Object { $_.id }) }
    if ($ids.Count -eq 0) { Die "验证未通过（HTTP $httpCode）。请核对地址与 Key。" }
    if ($ids -notcontains $provModel) { Die "模型 $provModel 不在该地址的模型列表中。请重新获取模型列表并选择。" }
    Ok "静默验证通过（HTTP $httpCode，$($ids.Count) 个可用模型）"
} else {
Write-Host ""
Write-Host "HerMemory 永久免费。AI 每次回答消耗服务商算力，需自备接口凭据。"
Write-Host ""
Write-Host "  需要准备两项"
Write-Host ""
Write-Host "  1. Base URL"
Write-Host "     以 https 开头、/v1 结尾。控制台中可能标注为：API 地址 / OpenAI 兼容地址。"
Write-Host ""
Write-Host "  2. API Key"
Write-Host "     一长串字符，通常以 sk- 开头。控制台中可能标注为：API key / API 密钥。"
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
                Warn "[连接超时] 无法连接该地址。请检查：地址是否为服务商的 OpenAI 兼容接口（通常以 /v1 结尾）；本机能否访问互联网；若已开启代理，可关闭或更换节点后重试"
                continue
            }
            if ($urlCode -eq "404") {
                Warn "[404] 接口路径不存在。请核对是否为服务商标注的 OpenAI 兼容地址"
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
    if (-not $apiKey) { Warn "API Key 不能为空，请重新输入"; continue }

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
        Warn "[连接超时] 网络异常。重新输入，或输 1 返回上一步"
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
    Warn "序号无效，重新选择"
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
function Set-ConfigOrDie([string]$k, [string]$v) {
    $r = Run-QOut $HermesCli config set $k $v
    if ($r.Code -ne 0) { Die ("写入配置失败：config set " + $k + "`n" + (Show-Tail $r.Out)) }
}
Set-ConfigOrDie $keyEnv $apiKey
$envFile = Join-Path $HermesHome ".env"
if (-not (Test-Path -LiteralPath $envFile)) { New-Item -ItemType File -Path $envFile -Force | Out-Null }
if (-not (Select-String -Path $envFile -Pattern ("^" + $keyEnv + "=") -Quiet)) { Add-Content -Path $envFile -Value "$keyEnv=$apiKey" }
# 清除会劫持路由的 OPENAI_*（上游 auxiliary_client 明确告警的 env 污染场景）
Run-Quiet $HermesCli config unset OPENAI_API_KEY
Run-Quiet $HermesCli config unset OPENAI_BASE_URL
# 存在性保护：.env 可能因上游未落盘而缺失，EAP=Stop 下直接 Get-Content 会中断安装
$envClean = @()
if (Test-Path "$HermesHome\.env") {
    $envClean = @(Get-Content "$HermesHome\.env" -ErrorAction SilentlyContinue) | Where-Object { $_ -notmatch "^(export )?OPENAI_API_KEY=" -and $_ -notmatch "^(export )?OPENAI_BASE_URL=" }
}
if (-not $envClean -or $envClean.Count -eq 0) { $envClean = @("$keyEnv=$apiKey") }
# PS5.1 的 Set-Content -Encoding UTF8 会写 BOM——.env 首行键名会被 BOM 污染，必须无 BOM 落盘
Write-LinesAtomicNoBom "$HermesHome\.env" ([string[]]@($envClean))
Set-ConfigOrDie "model.default" $provModel
Set-ConfigOrDie "model.provider" "custom"
Set-ConfigOrDie "model.base_url" $provBase
Set-ConfigOrDie "model.api_key" ('${' + $keyEnv + '}')
Set-ConfigOrDie "model.api_mode" "chat_completions"
# 落盘验证：provider/custom 与 key 引用缺一不可，缺则直改文件
$cfgPath = Join-Path $HermesHome "config.yaml"
if ((Test-Path $cfgPath) -and -not (Select-String -Path $cfgPath -Pattern "provider: custom" -Quiet)) {
    $cfgText = Get-Content $cfgPath -Raw
    $cfgText = $cfgText -replace "(?m)^(  provider:).*$", "  provider: custom"
    Write-TextAtomicNoBom $cfgPath $cfgText
}
if ((Test-Path $cfgPath) -and -not (Select-String -Path $cfgPath -Pattern ([regex]::Escape("api_key: `${$keyEnv}")) -Quiet)) {
    $cfgText = Get-Content $cfgPath -Raw
    if ($cfgText -match "(?m)^  base_url: .*$") {
        $cfgText = $cfgText -replace "(?m)^(  base_url: .*)$", ("`$1`n  api_key: `${" + $keyEnv + "}`n  api_mode: chat_completions")
        Write-TextAtomicNoBom $cfgPath $cfgText
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
    Log "静默模式：微信扫码由 exe 在安装完成后接管，此步跳过"
} elseif ((Test-Path $envFile) -and (Select-String -Path $envFile -Pattern "WEIXIN_ACCOUNT_ID" -Quiet)) {
    $wxConfigured = $true
    Ok "微信通道：已配置，跳过扫码"
} else {
    Log "微信接入"
    Write-Host "上游将启动英文配置向导。对照下表作答："
    Write-Host ""
    Write-Host "  向导提问                                          应答"
    Write-Host "  ────────────────────────────────────────────────────────"
    Write-Host "  Select platform                                   Weixin / WeChat 对应序号"
    Write-Host "  Start QR login now?                               回车"
    Write-Host "  输出二维码链接                                     复制到浏览器打开，"
    Write-Host "                                                    微信扫码并确认"
    Write-Host "  How should direct messages be authorized?         输入 3"
    Write-Host "  Allowed Weixin user IDs                           回车（已预填）"
    Write-Host "  How should group chats be handled?                输入 1"
    Write-Host "  其余提问                                           回车取默认"
    Write-Host ""
    Write-Host "  向导完成后自动关闭。暂不接入可关闭向导窗口。"
    while ($true) {
        $wxNow = Read-Host "现在扫码连接微信？[y/n]"
        if (-not $wxNow) { $wxNow = "Y" }
        if ($wxNow -match "^[Nn]") { break }
        & chcp.com 65001 | Out-Null
        & $HermesCli gateway setup
        & chcp.com 936 | Out-Null
        if ((Test-Path $envFile) -and (Select-String -Path $envFile -Pattern "WEIXIN_ACCOUNT_ID" -Quiet)) {
            $wxConfigured = $true
            Ok "微信通道已配置"
            break
        }
        Warn "微信未配置成功（二维码可能已超时）"
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
            if ($envLines -match "^(export )?WEIXIN_DM_POLICY=") {
                $envLines = $envLines -replace "^(export )?WEIXIN_DM_POLICY=.*", "WEIXIN_DM_POLICY=allowlist"
            } else {
                $envLines += "WEIXIN_DM_POLICY=allowlist"
            }
            if ($envLines -match "^(export )?WEIXIN_ALLOWED_USERS=") {
                $envLines = $envLines -replace "^(export )?WEIXIN_ALLOWED_USERS=.*", "WEIXIN_ALLOWED_USERS=$wxUserId"
            } else {
                $envLines += "WEIXIN_ALLOWED_USERS=$wxUserId"
            }
            # 无 BOM UTF-8（@() 包裹防单行 .env 退化成字符串拼接）
            Write-LinesAtomicNoBom $envFile ([string[]]$envLines)
            Ok "消息授权：仅允许本人微信 ID"
        }
    }
}
Progress "wechat"

# ---------- 11. gateway 服务（消息通道 + cron；上游在 Windows 用 schtasks 自启） ----------
# 「开机自动启动」由答案文件的 autoStart 决定（exe 安装位置页的勾选项，默认开）。
# 注意这**不是"装不装 gateway"的开关**，而是"要不要随登录自启"的开关：
# 服务本身照装（否则扫码之后的 gateway restart 起不来，微信直接接不上），只是不挂登录触发器。
$AutoStartGw = $true
if ($Answers -and ($Answers.PSObject.Properties.Name -contains "autoStart")) {
    $AutoStartGw = ("$($Answers.autoStart)" -ne "0")
}
if (-not $AutoStartGw) { Log "按安装选项：gateway 服务照装，但不随登录自动启动。" }
# 判重必须同时满足两点，缺一即重装：
#   ① 计划任务存在——用**精确任务名**（上游 get_task_name()：默认 profile 即 Hermes_Gateway）
#   ② 任务实际要跑的启动脚本存在——上游 _write_task_script() 落 gateway-service\<name>.vbs
# 旧实现 `schtasks /Query /FO LIST | Select-String "hermes"` 有两类坑：命中名字含 hermes 的
# 无关任务；以及**断链任务**（脚本已被卸载/清理工具删掉）让本步错误地"跳过重装"，
# 最终 gateway 根本不工作且全程无任何提示。
$gwTaskName = "Hermes_Gateway"
$gwLauncher = Join-Path $HermesHome "gateway-service\$gwTaskName.vbs"
# 内核换过版本：旧任务里的启动脚本指向旧 venv 的 python，留着它网关就再也起不来。
# 先删任务与启动脚本，让下面那段老老实实重装一次（重装会把新解释器写进 .vbs）。
if ($script:KernelUpgraded -or (Test-Path -LiteralPath $HmUpgradeMarker)) {
    Log "内核已升级：重建网关计划任务（旧任务指向旧运行时）"
    Run-Quiet schtasks /Delete /TN $gwTaskName /F
    if (Test-Path $gwLauncher) { Remove-Item $gwLauncher -Force -ErrorAction SilentlyContinue }
}
$gwEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$null = schtasks /Query /TN $gwTaskName /FO LIST 2>&1
$gwExists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $gwEap
if ($gwExists -and (Test-Path $gwLauncher)) {
    Ok "gateway 服务已注册，跳过重复安装"
} else {
    if ($gwExists) { Warn "gateway 计划任务存在但启动脚本缺失，重新安装。" }
    # 上游 install() 在写任何东西之前先交互提问（gateway_windows.py `_prompt_install_choices`）。
    # 其非交互守卫 is_noninteractive() 只认 HERMES_NONINTERACTIVE，**不检查 stdin**
    #（hermes_cli/setup.py 该函数文档声称"或 stdin 被重定向"，实现里没有）——静默安装下不设值
    # 就会走 input()，而 GUI 进程无控制台 → 永久阻塞（本机 + 沙盒双复现，2026-09-10）。
    #   START_ON_LOGIN：按安装选项决定是否挂登录自启触发器。不挂时服务仍完整可用，
    #                    只是开机不会自动拉起，需在主界面点「启动」。
    #   START_NOW=0：不在安装期派生常驻进程——安装常以管理员身份运行，避免留下提权 gateway。
    #   需要启动时由 exe 的微信流程或用户自行 gateway start。
    $env:HERMES_NONINTERACTIVE = "1"
    # 上游 install(start_on_login=False) 会**直接 return，连任务都不建** —— 那样用户关掉
    # "开机自启"就连网关都没有了。所以一律按登录自启装，装完再按用户选择禁用任务
    # （gateway start 是直接拉起进程，不依赖计划任务，手动启动照常可用）。
    $env:HERMES_GATEWAY_INSTALL_START_ON_LOGIN = "1"
    $env:HERMES_GATEWAY_INSTALL_START_NOW = "0"
    Log "安装 gateway 服务……"
    $gwExe = Join-Path $HermesHome "bin\hermes.exe"
    if (-not (Test-Path $gwExe)) { $gwExe = "hermes" }
    $gwOut = Join-Path $env:TEMP "hm-gateway-install.log"
    $gwErr = Join-Path $env:TEMP "hm-gateway-install.err.log"
    $gwCode = -1
    # 硬超时兜底：上游注释自陈 schtasks /Create 在锁定账户上会"停在超时前"才返回 Access Denied
    #（gateway_windows.py install() 注释），故此处 240 秒强制终止，绝不无限等。
    try {
        $gwProc = Start-Process -FilePath $gwExe -ArgumentList @("gateway", "install") -NoNewWindow -PassThru `
            -RedirectStandardOutput $gwOut -RedirectStandardError $gwErr -ErrorAction Stop
        if ($gwProc.WaitForExit(240000)) { $gwCode = $gwProc.ExitCode }
        else { Run-Quiet taskkill /PID $gwProc.Id /T /F; $gwCode = -2 }
    } catch {
        Warn "gateway 服务安装启动失败：$($_.Exception.Message)"
    }
    if ($gwCode -eq 0) {
        Ok "gateway 服务已安装"
        if (-not $AutoStartGw) {
            Run-Quiet schtasks /Change /TN $gwTaskName /DISABLE
            Log "按安装选项：登录自启已关闭（任务保留，可在主界面手动启动）"
        }
    } elseif ($gwCode -eq -2) {
        Warn "gateway 服务安装超时（240 秒），已终止。可稍后手动执行：hermes gateway install"
    } else {
        Warn "gateway 服务安装未成功。可稍后手动执行：hermes gateway install"
        try { Get-Content $gwErr -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Warn "  $_" } } catch { }
        try { Get-Content $gwOut -Tail 3 -ErrorAction SilentlyContinue | ForEach-Object { Warn "  $_" } } catch { }
    }
}
# 启动脚本已就位 = 这次重建成功（或本来就可用）；清掉标记，下一次安装不再无谓重装任务。
if (Test-Path -LiteralPath $gwLauncher) { Remove-Item -LiteralPath $HmUpgradeMarker -Force -ErrorAction SilentlyContinue }
Progress "gateway"

}   # end of 配置阶段（9~11 段）

# ---------- 12~13. 收尾：完成提示 ----------
# **只在最终阶段执行**（与 9~11 段同一条件）。分阶段安装下，阶段 1 跑完时 AI 还没配置，
# 完成提示应留到用户填完参数、微信接好之后再说。
# v0.22 起随包素材只剩内核 bundle 与 uv（都不需要安装后清理），所以这里不再有素材清理段。
# 交互模式（无 -AnswersFile）$HasAiConfig 恒为 true，行为与从前完全一致。
if (-not $HasAiConfig) {
    Log "安装阶段：跳过完成提示与素材清理（向导收集完参数后会再运行一次本脚本执行）。"
} else {

# ---------- 12. 脚本下线 ----------
# 设计（用户流程 2）：key 配置完成后 AI 上线，脚本下线。
# 微信接入 / 初次部署 / 能力演示全部由 AI 完成（#13）——AI 读 AGENTS.md 指针（内容在 docs）。

# ---------- 13. 完成提示 ----------
Write-Host ""
Log "HerMemory v0.2.0 安装完成。使用说明见 $VaultDir\HerMemory\docs\GUIDE.md。"
Write-Host ""
Write-Host "  注意事项"
Write-Host "  1. AGENTS.md 可自由编辑。上游 Hermes 对其执行威胁扫描，含触发词的内容会被整体拦截。"
Write-Host "     MEMORY.md 与 USER.md 逐条扫描，命中条目在对话中显示为 [BLOCKED]，文件本身保留。"
Write-Host "  2. 自动化默认关闭。日记与总结需明确指令后写入；定时任务由对话建立并登记至 AUTOMATION.md。"
Write-Host ""
if ($wxConfigured) {
    Log "微信已接入。打开微信发送消息即可开始。"
} else {
    Log "启动方式：命令行输入 hermes，按 docs\ONBOARDING.md 的指引完成剩余配置。"
}
Log "文档修改：编辑 $VaultDir\HerMemory\memory\ 内文件，开启新对话后生效。"
Log "文档：docs\INSTALL.md 部署｜docs\GUIDE.md 使用｜docs\README_REBORN.md 恢复指引"
Progress "done"

}   # end of 收尾（12~13 段）

# ---------- 进度契约：两个阶段都必须报 done ----------
# `Progress "done"` 原本由 §13 发出；§13 移进"最终阶段"后，阶段 1 就没人发了 → 进度条停在上一格。
# 放在包裹外，两阶段都发。它只决定进度条百分比，**不参与成功判定**（向导看的是退出码）。
Progress "done"
