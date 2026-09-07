#!/usr/bin/env bash
# ============================================================
# HerMemory installer — v0.1.0
# 基于 Hermes Agent v0.21.0 (tag v2026.8.31)，MIT。
# 上游仓库：https://github.com/NousResearch/hermes-agent.git
#
# 做的事：clone 上游 pin 版本 → 跑官方 setup-hermes.sh → 建 vault
#   → 铺出厂四文件 → 软链注入槽位 → 皮肤 → 时区 → 时间注入开关
#   → 记忆档位 → gateway 服务 → WebDAV 一键同步 → 自检脚本。
#
# key 配置：脚本内引导（用户流程 2），底层走上游原生机制；
#   不装 ripgrep（可选，后补）；不碰任何商业引导。
#
# 运行方式：clone 本仓库后，在仓库根目录 bash install.sh
# 目标环境：headless Linux（Ubuntu 22/24、主流 NAS）
# ============================================================
set -euo pipefail

HERMEMORY_VERSION="0.1.0"
PINNED_HERMES_TAG="v2026.8.31"
UPSTREAM_REPO="https://github.com/NousResearch/hermes-agent.git"
UPSTREAM_DIR="$HOME/hermes-agent"
# 上游本体包直链（zip，由 scripts/make_offline_bundle.sh 生成后上传到自己的服务器）。
# 留空 = 跳过直链层，直接 GitHub clone。境内服务器建议填上——GitHub 不可达时的兜底。
OFFLINE_BUNDLE_URL=""
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
WEBDAV_PORT="5005"
WEBDAV_USER="hermemory"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 本仓库（壳）位置

log()  { printf '\033[36m[HerMemory]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 断点续装（状态文件记录已完成步骤；删除它 = 全部重来） ----------
STATE_FILE="$HERMES_HOME/.hermemory-install-state"
mkdir -p "$HERMES_HOME"; touch "$STATE_FILE"
done_step() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { done_step "$1" || echo "$1" >> "$STATE_FILE"; }
log "安装状态文件：$STATE_FILE（已完成的步骤在重新安装时自动跳过）"

# ---------- 0. 环境检查 ----------
[[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux（headless）。PC 端装机路径见 docs/INSTALL.md（待实测）。"
[[ $EUID -ne 0 ]] || die "不要用 root 跑安装器；用普通用户 + sudo。"
command -v git  >/dev/null || die "缺 git：先 apt install git"
command -v curl >/dev/null || die "缺 curl：先 apt install curl"

log "可在 docs/INSTALL.md 查看安装说明"

# ---------- 1. vault 位置（定名，不询问——路径被提示词与文档广泛引用，固定避免漂移） ----------
VAULT_DIR="$HOME/vault"

# ---------- 2. 安装上游 Hermes（pin tag，官方脚本） ----------
# 本体获取四层：同目录本体包 → 服务器直链 → GitHub clone
if [ -x "$HOME/.local/bin/hermes" ]; then
    log "上游已安装：hermes CLI 就绪（跳过获取与 setup）"
    mark_done upstream
elif done_step upstream; then
    log "上游内核：已完成（自动跳过）"
else
    if [ ! -f "$UPSTREAM_DIR/setup-hermes.sh" ]; then
        BUNDLE_ZIP=""
        for c in "$SRC/hermes-agent-bundle.zip" "$PWD/hermes-agent-bundle.zip"; do
            [ -f "$c" ] && BUNDLE_ZIP="$c" && break
        done
        if [ -n "$BUNDLE_ZIP" ]; then
            log "检测到本地本体包：$BUNDLE_ZIP"
        elif [ -n "$OFFLINE_BUNDLE_URL" ]; then
            log "从直链下载上游本体包……"
            if curl -fL --retry 2 --max-time 600 -o /tmp/hermes-agent-bundle.zip "$OFFLINE_BUNDLE_URL"; then
                BUNDLE_ZIP=/tmp/hermes-agent-bundle.zip
            else
                warn "直链下载失败，转 GitHub clone"
            fi
        fi
        if [ -n "$BUNDLE_ZIP" ]; then
            command -v unzip >/dev/null || die "解压本体包需要 unzip：sudo apt install unzip（或删掉包转 GitHub clone）"
            mkdir -p "$UPSTREAM_DIR"
            unzip -qo "$BUNDLE_ZIP" -d "$UPSTREAM_DIR" || die "本体包解压失败（包损坏？重新下载）"
            local_tag=""
            [ -f "$UPSTREAM_DIR/HERMES_BUNDLE_TAG" ] && local_tag="$(cat "$UPSTREAM_DIR/HERMES_BUNDLE_TAG")"
            if [ -n "$local_tag" ] && [ "$local_tag" != "$PINNED_HERMES_TAG" ]; then
                die "本体包版本（$local_tag）与发行版 pin（$PINNED_HERMES_TAG）不一致——请换用匹配版本的本体包"
            fi
            ok "上游 Hermes 本体已就位（本体包，$PINNED_HERMES_TAG）"
        else
            log "clone 上游 Hermes $PINNED_HERMES_TAG ..."
            git clone --depth 1 --branch "$PINNED_HERMES_TAG" "$UPSTREAM_REPO" "$UPSTREAM_DIR"
        fi
    else
        log "上游源码已在：$UPSTREAM_DIR（跳过获取，继续 setup）"
    fi

    log "运行官方 setup-hermes.sh（uv + venv + hermes CLI，首次 1-5 分钟）..."
    # stdin 喂两个 n：① 跳过 ripgrep 可选安装 ② 跳过 key 配置向导（零商业：key 沿用官方流程，用户稍后自配）
    printf 'n\nn\n' | (cd "$UPSTREAM_DIR" && bash setup-hermes.sh) || die "上游 setup 失败，见上方输出"
    export PATH="$HOME/.local/bin:$PATH"
    command -v hermes >/dev/null || die "hermes CLI 不可用（~/.local/bin 不在 PATH？）"
    ok "hermes CLI 就绪"
    mark_done upstream
fi
ok "hermes CLI 就绪"

# ---------- 3. vault 结构 ----------
mkdir -p "$VAULT_DIR/HerMemory/memory"
ok "同步根结构：$VAULT_DIR/{用户文档, HerMemory/memory/}"

# ---------- 4. 出厂四文件（已存在则绝不覆盖——那是你的记忆） ----------
for f in MEMORY.md USER.md SOUL.md AGENTS.md AUTOMATION.md; do
    dst="$VAULT_DIR/HerMemory/memory/$f"
    if [ -f "$dst" ]; then
        log "已存在，跳过：$dst（不覆盖既有记忆）"
    else
        cp "$SRC/memory/$f" "$dst"
        ok "铺设出厂文件：HerMemory/memory/$f"
    fi
done

# ---------- 4.5 使用文档进同步范围（AI 可读、多端可读） ----------
mkdir -p "$VAULT_DIR/HerMemory/docs"
cp -R "$SRC/docs/." "$VAULT_DIR/HerMemory/docs/"
ok "使用文档已铺：HerMemory/docs/"

# ---------- 5. 软链四件（官方注入槽位，零代码） ----------
#   SOUL.md  → $HERMES_HOME/SOUL.md            （身份槽 slot#1）
#   AGENTS.md→ $HERMES_HOME/AGENTS.md          （官方 context file 通道）
#   MEMORY.md / USER.md → $HERMES_HOME/memories/（原生双文件，全量注入）
link_one() { # link_one <同步侧文件> <agent侧路径>
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        log "软链已就位：$dst"
    elif [ -e "$dst" ] && [ ! -L "$dst" ]; then
        local bak="$dst.pre-hermemory.$(date +%s)"
        mv "$dst" "$bak"
        warn "检测到已有文件 $dst，已备份为 $bak 后建立软链"
        ln -s "$src" "$dst"
    else
        ln -sfn "$src" "$dst"
    fi
    ok "软链：$dst → $src"
}
link_one "$VAULT_DIR/HerMemory/memory/SOUL.md"   "$HERMES_HOME/SOUL.md"
# AGENTS.md 的注入槽位是"会话工作目录链"（git 根→cwd），不是 HERMES_HOME。
# 槽位用 .hermes.md（Hermes 专属、优先级最前）：用户可见文件仍是 vault 里的 AGENTS.md，
# 且不会污染机器上其他遵循 AGENTS 约定的工具（Codex CLI 等不读 .hermes.md）。
link_one "$VAULT_DIR/HerMemory/memory/AGENTS.md" "$HOME/.hermes.md"
link_one "$VAULT_DIR/HerMemory/memory/MEMORY.md" "$HERMES_HOME/memories/MEMORY.md"
link_one "$VAULT_DIR/HerMemory/memory/USER.md"   "$HERMES_HOME/memories/USER.md"

# ---------- 6. 品牌皮肤 ----------
mkdir -p "$HERMES_HOME/skins"
cp "$SRC/skins/hermemory.yaml" "$HERMES_HOME/skins/hermemory.yaml"
hermes config set display.skin hermemory >/dev/null 2>&1 && ok "皮肤已激活：HerMemory（/skin 可随时切换；改 yaml 约一秒热重绘）" \
    || warn "display.skin 写入失败（不致命），可运行时 /skin hermemory 手动切换"

# ---------- 7. 时区 Asia/Shanghai（时钟错则时间感知全错） ----------
if command -v timedatectl >/dev/null; then
    if [ "$(timedatectl show -p Timezone --value 2>/dev/null)" = "Asia/Shanghai" ]; then
        ok "时区已是 Asia/Shanghai"
    else
        sudo timedatectl set-timezone Asia/Shanghai 2>/dev/null \
            && ok "时区 → Asia/Shanghai" \
            || warn "时区设置失败（无 sudo？）。手动：sudo timedatectl set-timezone Asia/Shanghai"
    fi
else
    grep -q "TZ=Asia/Shanghai" "$HOME/.bashrc" 2>/dev/null || \
        echo 'export TZ=Asia/Shanghai' >> "$HOME/.bashrc"
    ok "无 timedatectl（容器/NAS）：已在 ~/.bashrc 追加 TZ=Asia/Shanghai"
fi

# ---------- 8. 时间注入开关（官方原生，默认关）+ 界面显示偏好 ----------
hermes config set gateway.message_timestamps.enabled true >/dev/null 2>&1 \
    && ok "时间注入已开启：每条用户消息头部自动拼服务器真实时间" \
    || die "gateway.message_timestamps.enabled 写入失败"
hermes config set display.language zh >/dev/null 2>&1 \
    && ok "界面语言：中文" \
    || warn "display.language 写入失败（不致命）"
hermes config set display.timestamps true >/dev/null 2>&1 \
    && ok "对话时间标签 [HH:MM]：已开启" \
    || warn "display.timestamps 写入失败（不致命）"

# ---------- 9. 记忆档位（新手引导1：多档可选） ----------
if done_step memory-tier; then
    log "记忆档位：已完成（自动跳过）"
else
log "MEMORY/USER容量设置"

echo "提升容量会增强AI记忆力，但可能降低专注度，建议选择1-2档"

echo "  1.紧凑：2200/1375 [默认]"
echo "  2.标准：5000/3000"
echo "  3.详细：10000/5000"

read -rp "请选择记忆档位（1/2/3）: " MEM_CHOICE
MEM_CHOICE="${MEM_CHOICE:-1}"
case "$MEM_CHOICE" in
    2) MEM_LIMIT=5000;  USER_LIMIT=3000  ;;
    3) MEM_LIMIT=10000; USER_LIMIT=5000  ;;
    *) MEM_LIMIT=2200;  USER_LIMIT=1375  ;;
esac
hermes config set memory.memory_char_limit "$MEM_LIMIT"  >/dev/null
hermes config set memory.user_char_limit   "$USER_LIMIT" >/dev/null
ok "记忆档位：MEMORY $MEM_LIMIT / USER $USER_LIMIT 字符（随时改档：bash memory-size.sh）"
mark_done memory-tier
fi
ok "记忆档位：MEMORY $MEM_LIMIT / USER $USER_LIMIT 字符（随时改档：bash memory-size.sh）"

# ---------- 9.5/9.6 配置 AI（用户流程 2：地址先验证，Key 后验证；Key 阶段输 1 可返回地址；完成后 AI 上线） ----------
if done_step config-ai; then
    log "配置 AI：已完成（自动跳过）"
else
echo "HerMemory本身永久免费"
echo "但AI每次回答都会消耗服务商的算力"

echo "需要你获取："

echo "1.Base URL：AI去哪里干活"
echo "通常以https开头，v1结尾"
echo "控制台里可能叫：API地址 / OpenAI兼容地址"

echo "2.APIkey：AI如何计费"
echo "一长串字符，常以sk-开头，也可能没有规律"
echo "控制台里可能叫：API key / API密钥"


AT_URL=1
while true; do
    if [ "$AT_URL" = "1" ]; then
        log "第一步：验证 API 地址"
        while true; do
            read -rp "请输入 API 地址: " PROV_BASE
            # 只保留可见 ASCII——剔除复制粘贴混入的零宽/全角/控制字符
            PROV_BASE=$(printf '%s' "$PROV_BASE" | LC_ALL=C tr -d '\000-\040\177-\377')
            PROV_BASE="${PROV_BASE%/}"
            log "正在验证 API 地址……"
            URL_CODE=$(curl -s --noproxy '*' --max-time 20 -o /tmp/hm_url_test.json -w "%{http_code}" "$PROV_BASE/models" || true)
            [ "$URL_CODE" = "000" ] && URL_CODE=$(curl -s --max-time 20 -o /tmp/hm_url_test.json -w "%{http_code}" "$PROV_BASE/models" || true)
            if [ "$URL_CODE" = "000" ]; then
                warn "[连接超时] 无法连接至该 API 地址。请确认：① 地址为服务商提供的接口地址（通常以 /v1 结尾）；② 本机当前可以访问互联网；③ 若开启了代理软件，尝试关闭代理或更换节点后重试"
                continue
            fi
            if [ "$URL_CODE" = "404" ]; then
                warn "[404] 该接口路径不存在。请核对是否使用了服务商标注的 OpenAI 兼容接口地址"
                continue
            fi
            ok "API 地址可达（HTTP $URL_CODE）"
            break
        done
        AT_URL=0
    fi

    log "第二步：验证 API Key（输入 1 返回上一步）"
    read -rsp "请输入 API Key（输入可能不显示）: " API_KEY
    echo ""
    API_KEY=$(printf '%s' "$API_KEY" | LC_ALL=C tr -d '\000-\040\177-\377')
    if [ "$API_KEY" = "1" ]; then AT_URL=1; continue; fi
    [ -n "$API_KEY" ] || { warn "key 不能为空——重新输入"; continue; }

    log "正在验证 API Key……"
    HTTP_CODE=$(curl -s --noproxy '*' --max-time 20 -o /tmp/hm_models.json -w "%{http_code}" "$PROV_BASE/models" -H "Authorization: Bearer $API_KEY" || true)
    [ "$HTTP_CODE" = "000" ] && HTTP_CODE=$(curl -s --max-time 20 -o /tmp/hm_models.json -w "%{http_code}" "$PROV_BASE/models" -H "Authorization: Bearer $API_KEY" || true)
    case "$HTTP_CODE" in
        401|403)
            warn "[$HTTP_CODE] 认证未通过（服务返回：$(head -c 150 /tmp/hm_models.json 2>/dev/null)）。请确认 API Key 复制完整（注意首尾空格与截断），且该 Key 在服务商控制台处于启用状态"
            continue ;;
        000)
            warn "[连接超时] 网络异常——重新输入，或输 1 返回上一步" ;;
    esac
    if [ "$HTTP_CODE" != "200" ]; then
        warn "[$HTTP_CODE] 服务商暂时故障或限流——稍等几秒重试；持续出现请检查服务商状态页"
        continue
    fi
    if ! grep -q '"data"' /tmp/hm_models.json 2>/dev/null; then
        warn "[格式异常] 该地址返回的内容不是标准接口响应（HTTP $HTTP_CODE）。请确认使用的是 API 接口地址，而非控制台网页地址"
        continue
    fi
    mapfile -t MODEL_LIST < <(grep -o '"id" *: *"[^"]*"' /tmp/hm_models.json | sed 's/.*"id" *: *"//;s/"$//' || true)
    if [ ${#MODEL_LIST[@]} -eq 0 ]; then
        warn "[错误] 连接正常，但该 Key 名下无可用模型。请在服务商控制台确认已开通模型调用权限"
        continue
    fi
    ok "连接正常，检测到 ${#MODEL_LIST[@]} 个可用模型。"
    break
done

i=1
for m in "${MODEL_LIST[@]}"; do echo "  [$i] $m"; i=$((i+1)); done
while true; do
    read -rp "请选择模型序号: " MODEL_PICK
    if [[ "$MODEL_PICK" =~ ^[0-9]+$ ]] && [ "$MODEL_PICK" -ge 1 ] && [ "$MODEL_PICK" -le ${#MODEL_LIST[@]} ]; then
        PROV_MODEL="${MODEL_LIST[$((MODEL_PICK-1))]}"
        break
    fi
    warn "序号无效——重新选择"
done

# 上游机制（_model_flow_custom）：key 存 .env 的 HERMES_CUSTOM_<主机>_API_KEY；
# config model 段 = provider custom + base_url + api_key ${ENV引用} + api_mode。
# 绝不能写 OPENAI_API_KEY——auto 路由见到它会劫持到 OpenRouter。
HOSTPORT=$(printf '%s' "$PROV_BASE" | sed -E 's#^https?://([^/]+).*#\1#')
SLUG=$(printf '%s' "$HOSTPORT" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//')
KEY_ENV="HERMES_CUSTOM_${SLUG}_API_KEY"
hermes config set "$KEY_ENV" "$API_KEY" >/dev/null
grep -q "^${KEY_ENV}=" "$HERMES_HOME/.env" 2>/dev/null || echo "${KEY_ENV}=$API_KEY" >> "$HERMES_HOME/.env"
# 清除会劫持路由的 OPENAI_*（上游明确告警的 env 污染场景）
hermes config unset OPENAI_API_KEY >/dev/null 2>&1
hermes config unset OPENAI_BASE_URL >/dev/null 2>&1
sed -i '/^OPENAI_API_KEY=/d; /^OPENAI_BASE_URL=/d' "$HERMES_HOME/.env"
hermes config set model.default "$PROV_MODEL" >/dev/null
hermes config set model.provider custom >/dev/null
hermes config set model.base_url "$PROV_BASE" >/dev/null
hermes config set model.api_key "\${${KEY_ENV}}" >/dev/null
hermes config set model.api_mode chat_completions >/dev/null
# 落盘验证：缺则直改文件
grep -q "provider: custom" "$HERMES_HOME/config.yaml" 2>/dev/null || sed -i 's/^  provider: .*/  provider: custom/' "$HERMES_HOME/config.yaml"
if ! grep -q 'api_key: \${'"$KEY_ENV"'}' "$HERMES_HOME/config.yaml" 2>/dev/null; then
    sed -i "/^  base_url: /a\\  api_key: \\${${KEY_ENV}}\\  api_mode: chat_completions" "$HERMES_HOME/config.yaml"
fi
ok "配置完成（模型：$PROV_MODEL）"
mark_done config-ai
fi

# ---------- 10. 微信扫码接入（可选；完成后 AI 直接出现在用户微信） ----------
WX_CONFIGURED=0
if grep -q "WEIXIN_ACCOUNT_ID" "$HERMES_HOME/.env" 2>/dev/null; then
    WX_CONFIGURED=1
    ok "微信通道：已配置（跳过扫码）"
else
    log "微信接入（推荐现在完成——完成后 AI 直接出现在你的微信里）"
    echo "即将打开英文配置向导，请对照下面的中文答题卡操作："
    echo ""
    echo "  向导问题（英文原文）                              → 你该输入"
    echo "  ─────────────────────────────────────────────"
    echo "  Select platform（选择平台）                        → Weixin / WeChat 对应的数字"
    echo "  终端出现二维码                                     → 用微信扫码并确认；扫不出就把链接复制到"
    echo "                                                       浏览器打开，页面里会出现二维码，再扫码"
    echo "  How should direct messages be authorized?         → 输入 3（不要选默认的 1）"
    echo "  Allowed Weixin user IDs                           → 直接回车（已预填你的微信 ID）"
    echo "  How should group chats be handled?                → 输入 1（禁用群聊，推荐）"
    echo "  其余提示                                           → 直接回车保持默认"
    echo ""
    echo "  完成后向导自动结束；不想现在配置可按 Ctrl+C 跳过"
    while true; do
        read -rp "现在扫码连接微信？[y/n]: " WX_NOW
        WX_NOW="${WX_NOW:-Y}"
        [[ "$WX_NOW" =~ ^[Nn] ]] && break
        hermes gateway setup || true
        if grep -q "WEIXIN_ACCOUNT_ID" "$HERMES_HOME/.env" 2>/dev/null; then
            WX_CONFIGURED=1
            ok "微信通道已配置"
            break
        fi
        warn "微信尚未配置成功（二维码可能已超时）"
        read -rp "重新打开向导扫码？[y/n]: " WX_RETRY
        [[ "$WX_RETRY" =~ ^[Nn] ]] && break
    done
    if [ "$WX_CONFIGURED" = "1" ]; then
        # 兜底：统一消息授权为 allowlist（防止向导默认的 pairing 拦截首条微信消息）
        WX_USER_ID=$(python3 -c "
import json, glob, os
files = sorted(glob.glob(os.path.expanduser('~/.hermes/weixin/accounts/*.json')), key=os.path.getmtime)
print(json.load(open(files[-1])).get('user_id', '') if files else '')" 2>/dev/null || true)
        if [ -n "$WX_USER_ID" ]; then
            if grep -q "WEIXIN_DM_POLICY" "$HERMES_HOME/.env" 2>/dev/null; then
                sed -i "s|^WEIXIN_DM_POLICY=.*|WEIXIN_DM_POLICY=allowlist|" "$HERMES_HOME/.env"
            else
                echo "WEIXIN_DM_POLICY=allowlist" >> "$HERMES_HOME/.env"
            fi
            if grep -q "WEIXIN_ALLOWED_USERS" "$HERMES_HOME/.env" 2>/dev/null; then
                sed -i "s|^WEIXIN_ALLOWED_USERS=.*|WEIXIN_ALLOWED_USERS=$WX_USER_ID|" "$HERMES_HOME/.env"
            else
                echo "WEIXIN_ALLOWED_USERS=$WX_USER_ID" >> "$HERMES_HOME/.env"
            fi
            ok "消息授权：仅允许你的微信 ID（首条消息直达）"
        fi
    fi
fi

# ---------- 11. gateway 服务（消息通道 + cron） ----------
log "安装 gateway 服务（消息通道 + 定时任务）……"
if hermes gateway install >/dev/null 2>&1; then
    ok "gateway 服务已安装（消息 + 定时任务）"
    # AGENTS.md 走 cwd 目录链：服务必须以 $HOME 为 WorkingDirectory
    for unit in "$HOME/.config/systemd/user/"*hermes*.service; do
        [ -f "$unit" ] || continue
        if grep -q "^WorkingDirectory=" "$unit"; then
            sudo -n sed -i "s|^WorkingDirectory=.*|WorkingDirectory=$HOME|" "$unit" 2>/dev/null || true
        else
            echo "WorkingDirectory=$HOME" >> "$unit"
        fi
        systemctl --user daemon-reload 2>/dev/null || true
        ok "服务 WorkingDirectory 固定为 \$HOME（AGENTS.md 目录链单点）：$unit"
    done
else
    warn "gateway 服务未安装成功，消息通道与定时任务暂不可用"
    warn "可前台运行 hermes gateway run 查看日志定位问题；排除后重跑安装器"
fi

# ---------- 12. 脚本下线 ----------
# 设计（用户流程 2）：key 配置完成后 AI 上线，脚本下线。
# WebDAV / 微信接入 / 同步引导 / 能力演示全部由 AI 完成（#13）——AI 读 AGENTS.md 指针（内容在 docs）。

# ---------- 12. 自检脚本（HERMES_HOME / SYNC_ROOT 写进配置区） ----------
mkdir -p "$HERMES_HOME"
sed -e "s|^HERMES_HOME=.*|HERMES_HOME=\"$HERMES_HOME\"|" \
    -e "s|^SYNC_ROOT=.*|SYNC_ROOT=\"$VAULT_DIR\"|" \
    "$SRC/sync_check.sh" > "$HERMES_HOME/sync_check.sh"
chmod +x "$HERMES_HOME/sync_check.sh"
ok "自检脚本已就位：~/.hermes/sync_check.sh（对 agent 说「体检一下」也会调它）"

# ---------- 13. 完成提示（两处如实告知，不隐瞒） ----------
echo ""
log "HerMemory $HERMEMORY_VERSION 安装完成。两件事必须知道（详解见 docs/GUIDE.md）："
echo "  ① AGENTS.md 可自由编辑，但上游 Hermes 对它做威胁扫描——含触发词的内容"
echo "     会被整体拦截（规则静默失效）。规则不生效时先想到这一条。"
echo "     （MEMORY.md / USER.md 逐条扫描：命中条目在对话中显示为 [BLOCKED]，文件本身保留。）"
echo "  ② 自动化默认全关：写日记/总结由你说一声才写；周小结、定时任务等口述即建"
echo "     （agent 自建 cron 并登记进 AUTOMATION.md）。"
echo ""
log "接下来："
if [ "$WX_CONFIGURED" = "1" ]; then
    log "你的 HerMemory 已在微信里——打开微信，给它发第一句话，它会向你自我介绍并引导完成剩余部署。"
else
    echo "  1. hermes              —— 启动 AI：首次对话它主动采档案（怎么称呼/主要用途/说话方式），"
    echo "                            然后按 docs/ONBOARDING.md 引导你配置同步与微信接入"
    log "启动 AI 后，将「部署待办」发送给 AI，后续配置将由它引导完成。"
fi
echo "  2. 改 $VAULT_DIR/HerMemory/memory/ 下任何文件 → 开新对话即生效"
echo ""
log "文档：docs/INSTALL.md（部署）｜docs/GUIDE.md（使用）｜docs/ONBOARDING.md（AI 的部署手册）"
