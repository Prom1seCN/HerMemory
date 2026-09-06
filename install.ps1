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
    [string]$VaultDir = "",
    [string]$Tag = "v2026.8.31",
    [switch]$SkipUpstream
)

$ErrorActionPreference = "Stop"
$HermesHome = $env:HERMES_HOME; if (-not $HermesHome) { $HermesHome = "$env:LOCALAPPDATA\hermes" }
$UpstreamRepo = "https://github.com/NousResearch/hermes-agent.git"
$WebDavPort = 5005
$WebDavUser = "hermemory"
$SRC = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log([string]$m)  { Write-Host "[hermemory] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[note] $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }

# ---------- 0. 环境检查 ----------
if ($env:OS -ne "Windows_NT") { Die "本脚本仅用于 Windows 原生路径；Linux/macOS 用 install.sh" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "缺 git：先安装 Git for Windows（https://git-scm.com）" }
Log "建议：另开一个窗口打开 docs\INSTALL.md，边装边看——每一步在做什么都在里面"

# ---------- 1. vault 位置 ----------
if (-not $VaultDir) {
    $VaultDir = Read-Host "vault（同步根）路径 [默认 $HOME\HerMemory-vault]"
    if (-not $VaultDir) { $VaultDir = "$HOME\HerMemory-vault" }
}
Log "vault（同步根）：$VaultDir"

# ---------- 2. 上游内核（官方安装器，pin tag；本脚本不自研内核安装） ----------
if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
    if ($SkipUpstream) { Die "hermes CLI 不可用，且指定了 -SkipUpstream" }
    Log "运行上游官方 install.ps1（pin $Tag；uv + Python 3.11 + Node + PortableGit，首次约 5-10 分钟）..."
    $up = Join-Path $env:TEMP "hermes-install.ps1"
    Invoke-WebRequest "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1" -OutFile $up -UseBasicParsing
    & ([scriptblock]::Create((Get-Content $up -Raw))) -Tag $Tag -SkipSetup
    if (-not (Get-Command hermes -ErrorAction SilentlyContinue)) {
        Warn "hermes 未进当前会话 PATH；刷新后重试或手动确认 %LOCALAPPDATA%\hermes\bin"
        $env:Path += ";$HermesHome\bin"
    }
    Ok "hermes CLI 就绪"
} else {
    Log "hermes 已安装，跳过上游安装器（版本以现有 venv 为准）"
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

# ---------- 10. gateway 服务（消息通道 + cron；上游在 Windows 用 schtasks 自启） ----------
& hermes gateway install 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "gateway 服务已安装（消息 + 定时任务，登录自启）" }
else { Warn "hermes gateway install 未成功——后补：hermes gateway install" }

# ---------- 11. WebDAV 一键同步 ----------
$rclone = Get-Command rclone -ErrorAction SilentlyContinue
if (-not $rclone) {
    Warn "未检测到 rclone（一键 WebDAV 的实现）。安装：winget install Rclone.Rclone，装好后重跑本脚本补上"
} else {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $webDavPass = -join ($bytes | ForEach-Object { [char](48 + ($_ % 74)) }) -replace "[^a-zA-Z0-9]",""
    if ($webDavPass.Length -lt 12) { $webDavPass = $webDavPass + "hm" + (Get-Random -Maximum 99999) }
    $task = "HerMemory WebDAV"
    schtasks /Create /F /TN $task /SC ONLOGON /TR "rclone serve webdav `"$VaultDir`" --addr 0.0.0.0:$WebDavPort --user $WebDavUser --pass $webDavPass" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Ok "WebDAV 已注册（登录自启）：端口 $WebDavPort / 用户 $WebDavUser / 密码 $webDavPass（请立即记录，明文仅出现这一次）"
    } else { Warn "WebDAV 计划任务注册失败——手动排查：schtasks /Query /TN `"$task`"" }
    Log "设备端三条路：① Obsidian+RemotelySave（http://本机IP:$WebDavPort）② filebrowser 网页 ③ 映射网络驱动器"
}

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
Write-Host "  1. hermes setup   —— 官方向导配 API key（唯一官方流程，本脚本不代配）"
Write-Host "  2. hermes         —— 首次对话它会主动采档案（怎么称呼/主要用途/说话方式）"
Write-Host "  3. 改 $VaultDir\HerMemory\memory\ 下任何文件 → 开新对话即生效"
Write-Host ""
Log "文档：docs\INSTALL.md（部署）｜docs\GUIDE.md（使用）｜docs\README_REBORN.md（导出包内给下一个 agent 的恢复指引）"
