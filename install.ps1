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

function Log([string]$m)  { Write-Host "[HerMemory] $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "[完成] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[note] $m" -ForegroundColor Yellow }
function Die([string]$m)  { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }

# ---------- 断点续装（状态文件记录已完成步骤；删除它 = 全部重来） ----------
$StateFile = Join-Path $HermesHome "hermemory-install.state"
New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null
function Test-Done([string]$step) { (Test-Path $StateFile) -and ((Get-Content $StateFile -ErrorAction SilentlyContinue) -contains $step) }
function Mark-Done([string]$step) { if (-not (Test-Done $step)) { Add-Content -Path $StateFile -Value $step } }
Log "安装状态文件：$StateFile（已完成的步骤在重新安装时自动跳过）"

# ---------- 0. 环境检查 ----------
if ($env:OS -ne "Windows_NT") { Die "本脚本仅用于 Windows 原生路径；Linux/macOS 用 install.sh" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "缺 git：先安装 Git for Windows（https://git-scm.com）" }
Log "可在 docs\INSTALL.md 查看安装说明"

# ---------- 1. vault 位置（定名，不询问——路径被提示词与文档广泛引用，固定避免漂移） ----------
$VaultDir = "$HOME\vault"

# ---------- 2. 上游内核（官方安装器，pin tag；本脚本不自研内核安装） ----------
if (Test-Done "upstream") {
    Log "上游内核：已完成（自动跳过）"
} elseif ((Test-Path (Join-Path $HermesHome "bin\hermes.cmd")) -or (Get-Command hermes -ErrorAction SilentlyContinue)) {
    Log "上游内核：检测到已安装，跳过"
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
Ok "使用文档已铺：HerMemory\docs/"

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
        Warn "检测到已有文件 $dst，已备份为 $bak 后建立软链"
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
if ($LASTEXITCODE -eq 0) { Ok "皮肤已激活：HerMemory（/skin 可随时切换；改 yaml 约一秒热重绘）" }
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
    Log "记忆档位：已完成（自动跳过）"
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
& hermes config set memory.memory_char_limit $memLimit | Out-Null
& hermes config set memory.user_char_limit $userLimit | Out-Null
Ok "记忆档位：MEMORY $memLimit / USER $userLimit 字符（随时改档：bash memory-size.sh）"
Mark-Done "memory-tier"
}

# ---------- 9.5/9.6 配置 AI（用户流程 2：地址先验证，Key 后验证；Key 阶段输 1 可返回地址；完成后 AI 上线） ----------
if (Test-Done "config-ai") {
    Log "配置 AI：已完成（自动跳过）"
} else {
Write-Host "HerMemory本身永久免费"
Write-Host "但AI每次回答都会消耗服务商的算力"

Write-Host "需要你获取："

Write-Host "1.Base URL：AI去哪里干活"
Write-Host "通常以https开头，v1结尾"
Write-Host "控制台里可能叫：API地址 / OpenAI兼容地址"

Write-Host "2.APIkey：AI如何计费"
Write-Host "一长串字符，常以sk-开头，也可能没有规律"
Write-Host "控制台里可能叫：API key / API密钥"


$atUrl = $true
while ($true) {
    if ($atUrl) {
        Log "第一步：验证 API 地址"
        while ($true) {
            $provBase = (Read-Host "请输入 API 地址").Trim()
            $provBase = $provBase.TrimEnd("/")
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
    $secKey = Read-Host -AsSecureString "请输入 API Key（输入可能不显示）"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secKey)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
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

& hermes config set custom_providers.$provName.base_url $provBase | Out-Null
& hermes config set custom_providers.$provName.api_mode chat_completions | Out-Null
& hermes config set custom_providers.$provName.model $provModel | Out-Null
& hermes config set custom_providers.$provName.api_key $apiKey | Out-Null
& hermes config set model $provModel | Out-Null
Ok "配置完成（模型：$provModel）"
Mark-Done "config-ai"
}
# ---------- 10. 微信扫码接入（可选；完成后 AI 直接出现在用户微信） ----------
$wxConfigured = $false
$envFile = Join-Path $HermesHome ".env"
if ((Test-Path $envFile) -and (Select-String -Path $envFile -Pattern "WEIXIN_ACCOUNT_ID" -Quiet)) {
    $wxConfigured = $true
    Ok "微信通道：已配置（跳过扫码）"
} else {
    Log "微信接入（推荐现在完成——完成后 AI 直接出现在你的微信里）"
    Write-Host "即将打开英文配置向导，请对照下面的中文答题卡操作："
    Write-Host ""
    Write-Host "  向导问题（英文原文）                              → 你该输入"
    Write-Host "  ─────────────────────────────────────────────"
    Write-Host "  Select platform（选择平台）                        → Weixin / WeChat 对应的数字"
    Write-Host "  终端出现二维码                                     → 用微信扫码并确认；扫不出就把链接复制到"
    Write-Host "                                                       浏览器打开，页面里会出现二维码，再扫码"
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
        & hermes gateway setup
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
            $envLines = Get-Content $envFile -ErrorAction SilentlyContinue
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
            Set-Content -Path $envFile -Value $envLines -Encoding ASCII
            Ok "消息授权：仅允许你的微信 ID（首条消息直达）"
        }
    }
}

# ---------- 11. gateway 服务（消息通道 + cron；上游在 Windows 用 schtasks 自启） ----------
Log "安装 gateway 服务（消息通道 + 定时任务，可能需要一两分钟）……"
& hermes gateway install 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Ok "gateway 服务已安装（消息 + 定时任务，登录自启）" }
else { Warn "hermes gateway install 未成功。可稍后手动执行：hermes gateway install" }

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
if ($wxConfigured) {
    Log "你的 HerMemory 已在微信里——打开微信，给它发第一句话，它会向你自我介绍并引导完成剩余部署。"
} else {
    Write-Host "  1. hermes         —— 启动 AI：首次对话它主动采档案（怎么称呼/主要用途/说话方式），"
    Write-Host "                      然后按 docs/ONBOARDING.md 引导你配置同步与微信接入"
    Log "启动 AI 后，将「部署待办」发送给 AI，后续配置将由它引导完成。"
}
Write-Host "  2. 改 $VaultDir\HerMemory\memory\ 下任何文件 → 开新对话即生效"
Log "文档：docs\INSTALL.md（部署）｜docs\GUIDE.md（使用）｜docs\README_REBORN.md（导出包内给下一个 agent 的恢复指引）"
