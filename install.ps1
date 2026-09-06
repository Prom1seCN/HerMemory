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

# ---------- 1. vault 位置（定名，不询问——路径被提示词与文档广泛引用，固定避免漂移） ----------
$VaultDir = "$HOME\vault"
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

# ---------- 9.5 配置 AI（用户流程 2：key 引导两路；完成后 AI 上线，脚本下线） ----------
Log "配置 AI（API key）"
Write-Host "你的 API key 是从哪里拿的？"
Write-Host "  [1] 阿里云百炼（推荐——新用户每模型免费额度 100 万 Token / 90 天）"
Write-Host "  [2] 腾讯云混元（新用户免费资源包 100 万 Token）"
Write-Host "  [3] 硅基流动（注册送额度，多款模型长期免费）"
Write-Host "  [0] 我还没有 key——带我去领免费额度"
Write-Host "  [4] 其他（自己填地址）"
$keySrc = Read-Host ">"
if ($keySrc -eq "0") {
    Write-Host "领取免费额度（三选一，都在浏览器里完成）："
    Write-Host "  阿里云百炼：打开 https://bailian.console.aliyun.com → 注册/登录（需实名）→ 领取新人免费额度 → 密钥管理创建 API Key"
    Write-Host "  腾讯云混元：打开 https://console.cloud.tencent.com/hunyuan → 领取新用户资源包 → API Key 管理页面创建密钥"
    Write-Host "  硅基流动：打开 https://cloud.siliconflow.cn → 手机号注册即送额度 → API 密钥页面新建密钥"
    Write-Host "  —— 拿到 sk- 开头的密钥后，回到下面选择来源并粘贴。"
    Write-Host "你的 API key 是从哪里拿的？"
    Write-Host "  [1] 阿里云百炼  [2] 腾讯云混元  [3] 硅基流动  [4] 其他"
    $keySrc = Read-Host ">"
}
switch ($keySrc) {
    "1" { $provBase = "https://dashscope.aliyuncs.com/compatible-mode/v1"; $provModel = "qwen3.6-flash";       $provName = "bailian" }
    "2" { $provBase = "https://api.hunyuan.cloud.tencent.com/v1";           $provModel = "hunyuan-turbos-latest"; $provName = "hunyuan" }
    "3" { $provBase = "https://api.siliconflow.cn/v1";                      $provModel = "Qwen/Qwen3-8B";       $provName = "siliconflow" }
    "4" { $provBase = Read-Host "API 地址（一般以 /v1 结尾）"
          $provModel = Read-Host "默认模型名"; $provName = "custom" }
    default { $provBase = "https://dashscope.aliyuncs.com/compatible-mode/v1"; $provModel = "qwen3.6-flash"; $provName = "bailian" }
}
$secKey = Read-Host -AsSecureString "把你的 key 粘贴进来（输入不会显示在屏幕上）"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secKey)
$apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
if (-not $apiKey) { Die "key 不能为空" }

# 模型防下架：从服务商实时模型列表解析型号（列表拉不到才用预置默认——预置型号退役不影响新装机）
$modelsJson = $null
try { $modelsJson = Invoke-RestMethod -Uri "$provBase/models" -Headers @{ Authorization = "Bearer $apiKey" } -TimeoutSec 15 } catch {}
if ($modelsJson -and $modelsJson.data) {
    $ids = @($modelsJson.data | ForEach-Object { $_.id })
    $picked = switch ($provName) {
        "bailian"     { $ids | Where-Object { $_ -match "qwen" -and $_ -match "flash" -and $_ -notmatch "vl|audio|omni|coder|realtime" } | Select-Object -First 1 }
        "hunyuan"     { $ids | Where-Object { $_ -match "hunyuan" -and $_ -match "turbo" -and $_ -match "latest" } | Select-Object -First 1 }
        "siliconflow" { $ids | Where-Object { $_ -eq "Qwen/Qwen3-8B" } | Select-Object -First 1 }
        default       { $null }
    }
    if ($picked) { $provModel = $picked; Ok "模型已按服务商当前列表选定：$provModel" }
}

# 写入走上游原生机制：custom_providers 四件套 + 设为主模型（与 _model_flow_custom 落盘结构一致）
& hermes config set custom_providers.$provName.base_url $provBase | Out-Null
& hermes config set custom_providers.$provName.api_mode chat_completions | Out-Null
& hermes config set custom_providers.$provName.model $provModel | Out-Null
& hermes config set custom_providers.$provName.api_key $apiKey | Out-Null
& hermes config set model $provModel | Out-Null

# ---------- 9.6 验活（纯脚本护城河：坏 key 绝不交给 AI） ----------
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
} else {
    switch ($httpCode) {
        401 { Die "key 不对，检查有没有粘全" }
        404 { Die "地址不对（检查是否以 /v1 结尾）" }
        { $_ -eq 429 -or $_ -eq 403 } { Die "额度不可用（余额为零或未领取免费额度）" }
        0 { Die "连不上服务商（网络问题），稍后重跑 install.ps1 或手动跑 hermes setup" }
        { $_ -eq 400 -or $_ -eq 500 } { if ($respBody -match "model") { Die "预置型号已下架且列表解析失败——去服务商模型广场确认型号名后重跑 install.ps1" } else { Die "验活失败（HTTP $httpCode）——检查 key 与地址，或改用 hermes setup 官方向导" } }
        default { Die "验活失败（HTTP $httpCode）——检查 key 与地址，或改用 hermes setup 官方向导" }
    }
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
