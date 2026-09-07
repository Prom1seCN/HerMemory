# ============================================================
# HerMemory installer (Windows native) — v0.1.0
# 基于 Hermes Agent v0.21.0 (tag v2026.8.31)，MIT。
# 上游官方 PowerShell 安装器负责内核（clone pin tag + uv + venv + CLI），
# 本脚本只做发行版的铺设：vault + 四文件 + 软链 + 皮肤 + 配置键 + docs。
# 对应 Linux 侧的 install.sh；上游怎么装，Windows 就怎么装。
#
# 运行：PowerShell 中  powershell -ExecutionPolicy Bypass -File install.ps1
# 前置：git（无则装 Git for Windows）。软链需要管理员权限或开发者模式。
# ============================================================
param(
    [string]$Tag = "v2026.8.31",
    [switch]$SkipUpstream
)

$ErrorActionPreference = "Stop"
# 境内服务商普遍要求 TLS 1.2+；Windows 自带 PS 5.1 默认协商老协议，不强制会连不上
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$HermesHome = $env:HERMES_HOME; if (-not $HermesHome) { $HermesHome = "$env:LOCALAPPDATA\hermes" }
$UpstreamRepo = "https://github.com/NousResearch/hermes-agent.git"
$WebDavPort = 5005
$WebDavUser = "hermemory"
$SRC = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log([string]$m)  { Write-Host "[hermemory] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[note] $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }

# ---------- 断点续装（状态文件记录已完成步骤；删除它 = 全部重来） ----------
$StateFile = Join-Path $HermesHome "hermemory-install.state"
New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null
function Test-Done([string]$step) { (Test-Path $StateFile) -and ((Get-Content $StateFile -ErrorAction SilentlyContinue) -contains $step) }
function Mark-Done([string]$step) { if (-not (Test-Done $step)) { Add-Content -Path $StateFile -Value $step } }
Log "断点状态：$StateFile（中断后重跑会跳过已完成步骤；删除此文件可全部重来）"

# ---------- 0. 环境检查 ----------
if ($env:OS -ne "Windows_NT") { Die "本脚本仅用于 Windows 原生路径；Linux/macOS 用 install.sh" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "缺 git：先安装 Git for Windows（https://git-scm.com）" }
Log "建议：另开一个窗口打开 docs\INSTALL.md，边装边看——每一步在做什么都在里面"

# ---------- 1. vault 位置（定名，不询问——路径被提示词与文档广泛引用，固定避免漂移） ----------
$VaultDir = "$HOME\vault"
Log "vault（同步根）：$VaultDir"

# ---------- 2. 上游内核（官方安装器，pin tag；本脚本不自研内核安装） ----------
if (Test-Done "upstream") {
    Log "上游内核：已完成（断点跳过）"
} elseif ((Test-Path (Join-Path $HermesHome "bin\hermes.cmd")) -or (Get-Command hermes -ErrorAction SilentlyContinue)) {
    Log "上游内核：检测到已安装，补记断点"
    Mark-Done "upstream"
} else {
    if ($SkipUpstream) { Die "hermes CLI 不可用，且指定了 -SkipUpstream" }
    try {
        Invoke-WebRequest -Uri "https://github.com" -Method Head -TimeoutSec 10 -UseBasicParsing | Out-Null
    } catch {
        Die "无法连上 GitHub（Windows 安装器需从 GitHub 获取内核与组件）。请开一次代理后再双击 install.bat——安装完成后日常使用不再需要。"
    }
    Log "运行上游官方 install.ps1（pin $Tag；uv + Python 3.11 + Node + PortableGit，首次约 5-10 分钟）..."
    $up = Join-Path $env:TEMP "hermes-install.ps1"
    Invoke-WebRequest "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1" -OutFile $up -UseBasicParsing
    & ([scriptblock]::Create((Get-Content $up -Raw))) -Tag $Tag -SkipSetup
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
Ok "使用文档已铺：HerMemory\docs\（随同步走；问 agent「怎么用」它自己会读）"

# ---------- 5. 软链四件（官方注入槽位）----------
# NTFS 符号链接需要管理员权限或开发者模式（Win10 1703+ 设置→更新→开发者选项）。
function LinkOne([string]$src, [string]$dst) {
    $dir = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ((Test-Path $dst) -and ((Get-Item $dst -Force).LinkType -eq "SymbolicLink") -and
        ((Get-Item $dst -Force).Target -eq $src)) { Log "软链已就位：$dst"; return }
    if (Test-Path $dst) {
        $bak = "$dst.pre-hermemory.$(Get-Date -Format yyyyMMddHHmmss)"
        Move-Item $dst $bak
        Warn "agent 侧已有真实文件 $dst —— 已备份为 $bak 再建软链"
    }
    try { New-Item -ItemType SymbolicLink -Path $dst -Target $src -Force | Out-Null; Ok "软链：$dst" }
    catch { Die "创建符号链接失败（需要管理员权限或开发者模式）。开启方法：设置 → 更新与安全 → 开发者选项 → 开发人员模式；或以管理员重跑本脚本。已完成的步骤不会丢失。" }
}
LinkOne "$VaultDir\HerMemory\memory\SOUL.md"   "$HermesHome\SOUL.md"
LinkOne "$VaultDir\HerMemory\memory\AGENTS.md" "$HermesHome\AGENTS.md"
LinkOne "$VaultDir\HerMemory\memory\MEMORY.md" "$HermesHome\memories\MEMORY.md"
LinkOne "$VaultDir\HerMemory\memory\USER.md"   "$HermesHome\memories\USER.md"

# ---------- 6. 品牌皮肤 ----------
New-Item -ItemType Directory -Force -Path "$HermesHome\skins" | Out-Null
Copy-Item "$SRC\skins\hermemory.yaml" "$HermesHome\skins\hermemory.yaml" -Force
& hermes config set display.skin hermemory 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "皮肤已激活：hermemory（/skin 可随时切换；改 yaml 约一秒热重绘）" }
else { Warn "display.skin 写入失败（不致命），运行时 /skin hermemory 手动切换" }

# ---------- 7. 时区 ----------
Log "Windows 使用本机时钟（时间注入取系统时间）——请在系统设置里确认时区为 (UTC+08:00) 北京"

# ---------- 8. 时间注入开关 + 界面显示偏好 ----------
& hermes config set gateway.message_timestamps.enabled true | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "时间注入已开启：每条用户消息头部自动拼本机真实时间" }
else { Die "gateway.message_timestamps.enabled 写入失败" }
& hermes config set display.language zh 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "界面语言：中文（静态 UI 消息，官方支持）" } else { Warn "display.language 写入失败（不致命）" }
& hermes config set display.timestamps true 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "对话时间标签 [HH:MM]：已开启" } else { Warn "display.timestamps 写入失败（不致命）" }

# ---------- 9. 记忆档位 ----------
if (Test-Done "memory-tier") {
    Log "记忆档位：已完成（断点跳过）"
} else {
Log "选择记忆容量档位（MEMORY.md / USER.md 字符上限，影响 agent 写记忆的预算）："
Write-Host "  1) 紧凑  2200 / 1375  （上游默认，≈1300 token）"
Write-Host "  2) 标准  8000 / 5000  （≈4700 token，日常推荐）"
Write-Host "  3) 宽敞 20000 / 12000 （≈11700 token，重度使用）"
Write-Host "  4) 自定义"
$choice = Read-Host "档位 [2]"
switch ($choice) {
    "1" { $memLimit = 2200;  $userLimit = 1375 }
    "3" { $memLimit = 20000; $userLimit = 12000 }
    "4" { $memLimit = [int](Read-Host "MEMORY.md 字符上限"); $userLimit = [int](Read-Host "USER.md 字符上限") }
    default { $memLimit = 8000; $userLimit = 5000 }
}
& hermes config set memory.memory_char_limit $memLimit | Out-Null
& hermes config set memory.user_char_limit $userLimit | Out-Null
Ok "记忆档位：MEMORY $memLimit / USER $userLimit 字符（随时改档：bash memory-size.sh）"
Mark-Done "memory-tier"
}

# ---------- 9.5/9.6 配置 AI（用户流程 2：填地址+key，失败可重输；验活通过才写配置，完成后 AI 上线） ----------
if (Test-Done "config-ai") {
    Log "配置 AI：已完成（断点跳过——要重配就删状态文件）"
} else {
Log "配置 AI（API 地址 + API key，输错可重输；不想装了直接关窗口）"
Write-Host "还没有 key？先去领免费额度（浏览器操作，详见 docs\INSTALL.md）："
Write-Host "  阿里云百炼 https://bailian.console.aliyun.com | 腾讯云混元 https://console.cloud.tencent.com/hunyuan | 硅基流动 https://cloud.siliconflow.cn"
while ($true) {
    $provBase = Read-Host "API 地址（服务商控制台提供，一般以 /v1 结尾）"
    if ($provBase -notmatch "^https?://") { Warn "API 地址要以 http(s):// 开头——重新输入"; continue }
    $provBase = $provBase.TrimEnd("/")
    $secKey = Read-Host -AsSecureString "API key（输入不会显示在屏幕上）"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secKey)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if (-not $apiKey) { Warn "key 不能为空——重新输入"; continue }

    $provName = "custom"
    $provModel = $null
    Log "获取可用模型列表……"
    try { $models = Invoke-RestMethod -Uri "$provBase/models" -Headers @{ Authorization = "Bearer $apiKey" } -TimeoutSec 15 } catch {}
    if ($models -and $models.data) {
        $ids = @($models.data | ForEach-Object { $_.id })
        if ($ids.Count -gt 0) {
            for ($i = 0; $i -lt $ids.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $ids[$i]) }
            $pick = Read-Host "选默认模型序号 [1]"
            if (-not $pick) { $pick = "1" }
            if ($pick -match "^\d+$" -and [int]$pick -ge 1 -and [int]$pick -le $ids.Count) { $provModel = $ids[[int]$pick - 1] }
            else { Warn "序号无效——重新输入"; continue }
        } else {
            $provModel = Read-Host "列表为空——手动输入模型名"
        }
    } else {
        $provModel = Read-Host "列表拉取失败（服务商可能不支持）——手动输入模型名"
    }
    if (-not $provModel) { Warn "模型名不能为空——重新输入"; continue }

    Log "正在测试连通……"
    $httpCode = 0
    $respBody = ""
    $body = '{"model":"' + $provModel + '","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
    try {
        $resp = Invoke-WebRequest -Uri "$provBase/chat/completions" -Method Post -Headers @{ Authorization = "Bearer $apiKey" } -ContentType "application/json" -Body $body -TimeoutSec 20 -UseBasicParsing
        $httpCode = [int]$resp.StatusCode; $respBody = $resp.Content
    } catch {
        if ($_.Exception.Response) { $httpCode = [int]$_.Exception.Response.StatusCode }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $respBody = $_.ErrorDetails.Message }
    }
    if ($httpCode -eq 200 -and $respBody -match "choices") {
        Ok "通了，额度可用（模型：$provModel）"
        break
    }
    switch ($httpCode) {
        401 { Warn "key 不对，检查有没有粘全" }
        404 { Warn "地址不对（检查是否以 /v1 结尾）" }
        { $_ -eq 429 -or $_ -eq 403 } { Warn "额度不可用（余额为零或未领取免费额度）" }
        0 { Warn "连不上服务商（网络问题）" }
        { $_ -eq 400 -or $_ -eq 500 } { if ($respBody -match "model") { Warn "所选模型不可用（换一个型号试试）" } else { Warn "验活失败（HTTP $httpCode）——检查 key 与地址" } }
        default { Warn "验活失败（HTTP $httpCode）——检查 key 与地址" }
    }
    Warn "——重新输入（不想装了直接关窗口）"
}

# 验活通过才写配置（上游原生机制：custom_providers 四件套 + 设为主模型）
& hermes config set custom_providers.$provName.base_url $provBase | Out-Null
& hermes config set custom_providers.$provName.api_mode chat_completions | Out-Null
& hermes config set custom_providers.$provName.model $provModel | Out-Null
& hermes config set custom_providers.$provName.api_key $apiKey | Out-Null
& hermes config set model $provModel | Out-Null
Mark-Done "config-ai"
}

# ---------- 10. gateway 服务（消息通道 + cron；上游在 Windows 用 schtasks 自启） ----------
& hermes gateway install 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "gateway 服务已安装（消息 + 定时任务，登录自启）" }
else { Warn "hermes gateway install 未成功——后补：hermes gateway install" }

# ---------- 11. 脚本下线 ----------
# 设计（用户流程 2）：key 配置完成后 AI 上线，脚本下线。
# WebDAV / 微信接入 / 同步引导 / 能力演示全部由 AI 完成（#13）——AI 读 AGENTS.md 指针（内容在 docs）。

# ---------- 12. 自检脚本（配置区写入实际路径） ----------
$chk = Get-Content "$SRC\sync_check.sh" -Raw
$chk = $chk -replace '^(HERMES_HOME=).*', ('$1"' + ($HermesHome -replace '\','/') + '"')
$chk = $chk -replace '^(SYNC_ROOT=).*', ('$1"' + ($VaultDir -replace '\','/') + '"')
Set-Content -Path "$HermesHome\sync_check.sh" -Value $chk -Encoding UTF8
Ok "自检脚本已就位：$HermesHome\sync_check.sh（agent 终端工具走 Git Bash，可直接执行）"

# ---------- 13. 完成提示 ----------
Write-Host ""
Log "HerMemory v0.1.0 安装完成。两件事必须知道（详解见 vault\HerMemory\docs\GUIDE.md）："
Write-Host "  (1) AGENTS.md 可自由编辑，但上游 Hermes 对它做威胁扫描——含触发词的内容会被整体拦截（规则静默失效）。"
Write-Host "      （MEMORY.md / USER.md 逐条扫描：命中条目在对话中显示为 [BLOCKED]，文件本身保留。）"
Write-Host "  (2) 自动化默认全关：写日记/总结由你说一声才写；周小结、定时任务等口述即建（agent 自建并登记进 AUTOMATION.md）。"
Write-Host ""
Log "接下来："
Write-Host "  1. hermes         —— 启动 AI：首次对话它主动采档案（怎么称呼/主要用途/说话方式），"
Write-Host "                      然后按 docs/ONBOARDING.md 引导你连接微信、配置同步"
Write-Host "  2. 改 $VaultDir\HerMemory\memory\ 下任何文件 → 开新对话即生效"
Write-Host ""
Log "最后一句话：启动 AI 后，把「部署待办」发给它——剩下的配置它来引导。"
Log "文档：docs\INSTALL.md（部署）｜docs\GUIDE.md（使用）｜docs\README_REBORN.md（导出包内给下一个 agent 的恢复指引）"
