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

log()  { printf '\033[36m[hermemory]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 断点续装（状态文件记录已完成步骤；删除它 = 全部重来） ----------
STATE_FILE="$HERMES_HOME/.hermemory-install-state"
mkdir -p "$HERMES_HOME"; touch "$STATE_FILE"
done_step() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { done_step "$1" || echo "$1" >> "$STATE_FILE"; }
log "断点状态：$STATE_FILE（中断后重跑会跳过已完成步骤；删除此文件可全部重来）"

# ---------- 0. 环境检查 ----------
[[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux（headless）。PC 端装机路径见 docs/INSTALL.md（待实测）。"
[[ $EUID -ne 0 ]] || die "不要用 root 跑安装器；用普通用户 + sudo。"
command -v git  >/dev/null || die "缺 git：先 apt install git"
command -v curl >/dev/null || die "缺 curl：先 apt install curl"

log "建议：另开一个终端/窗口打开 docs/INSTALL.md，边装边看——每一步在做什么都在里面"

# ---------- 1. vault 位置（定名，不询问——路径被提示词与文档广泛引用，固定避免漂移） ----------
VAULT_DIR="$HOME/vault"
log "vault（同步根）：$VAULT_DIR —— 用户文档直接放这里，HerMemory/ 子目录放四核心文件"

# ---------- 2. 安装上游 Hermes（pin tag，官方脚本） ----------
# 本体获取四层：同目录本体包 → 服务器直链 → GitHub clone
if [ -x "$HOME/.local/bin/hermes" ]; then
    log "上游已安装：hermes CLI 就绪（跳过获取与 setup）"
    mark_done upstream
elif done_step upstream; then
    log "上游内核：已完成（断点跳过）"
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
ok "使用文档已铺：HerMemory/docs/（随同步走；问 agent「怎么用」它自己会读）"

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
        warn "agent 侧已有真实文件 $dst —— 已备份为 $bak 再建软链"
        ln -s "$src" "$dst"
    else
        ln -sfn "$src" "$dst"
    fi
    ok "软链：$dst → $src"
}
link_one "$VAULT_DIR/HerMemory/memory/SOUL.md"   "$HERMES_HOME/SOUL.md"
link_one "$VAULT_DIR/HerMemory/memory/AGENTS.md" "$HERMES_HOME/AGENTS.md"
link_one "$VAULT_DIR/HerMemory/memory/MEMORY.md" "$HERMES_HOME/memories/MEMORY.md"
link_one "$VAULT_DIR/HerMemory/memory/USER.md"   "$HERMES_HOME/memories/USER.md"

# ---------- 6. 品牌皮肤 ----------
mkdir -p "$HERMES_HOME/skins"
cp "$SRC/skins/hermemory.yaml" "$HERMES_HOME/skins/hermemory.yaml"
hermes config set display.skin hermemory >/dev/null 2>&1 && ok "皮肤已激活：hermemory（/skin 可随时切换；改 yaml 约一秒热重绘）" \
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
    && ok "界面语言：中文（静态 UI 消息，官方支持）" \
    || warn "display.language 写入失败（不致命）"
hermes config set display.timestamps true >/dev/null 2>&1 \
    && ok "对话时间标签 [HH:MM]：已开启" \
    || warn "display.timestamps 写入失败（不致命）"

# ---------- 9. 记忆档位（新手引导1：多档可选） ----------
if done_step memory-tier; then
    log "记忆档位：已完成（断点跳过）"
else
log "选择记忆容量档位（MEMORY.md / USER.md 字符上限，影响 agent 写记忆的预算）："
echo "  1) 紧凑  2200 / 1375  （上游默认，≈1300 token，注意力最集中）"
echo "  2) 标准  8000 / 5000  （≈4700 token，日常推荐）"
echo "  3) 宽敞 20000 / 12000 （≈11700 token，重度使用）"
echo "  4) 自定义"
read -rp "档位 [2]: " MEM_CHOICE
MEM_CHOICE="${MEM_CHOICE:-2}"
case "$MEM_CHOICE" in
    1) MEM_LIMIT=2200;  USER_LIMIT=1375  ;;
    3) MEM_LIMIT=20000; USER_LIMIT=12000 ;;
    4) read -rp "MEMORY.md 字符上限: " MEM_LIMIT
       read -rp "USER.md   字符上限: " USER_LIMIT ;;
    *) MEM_LIMIT=8000;  USER_LIMIT=5000  ;;
esac
hermes config set memory.memory_char_limit "$MEM_LIMIT"  >/dev/null
hermes config set memory.user_char_limit   "$USER_LIMIT" >/dev/null
mark_done memory-tier
fi
ok "记忆档位：MEMORY $MEM_LIMIT / USER $USER_LIMIT 字符（随时改档：bash memory-size.sh）"

# ---------- 9.5/9.6 配置 AI（用户流程 2：填地址+key，失败可重输；验活通过才写配置，完成后 AI 上线） ----------
if done_step config-ai; then
    log "配置 AI：已完成（断点跳过——要重配就删状态文件）"
else
log "配置 AI（API 地址 + API key，输错可重输；不想装了按 Ctrl+C 退出）"
echo "还没有 key？先去领免费额度（浏览器操作，详见 docs/INSTALL.md）："
echo "  阿里云百炼 https://bailian.console.aliyun.com ｜ 腾讯云混元 https://console.cloud.tencent.com/hunyuan ｜ 硅基流动 https://cloud.siliconflow.cn"
while true; do
    read -rp "API 地址（服务商控制台提供，一般以 /v1 结尾）: " PROV_BASE
    if [[ "$PROV_BASE" =~ ^https?:// ]]; then
        PROV_BASE="${PROV_BASE%/}"
    else
        warn "API 地址要以 http(s):// 开头——重新输入"; continue
    fi
    read -rsp "API key（输入不会显示在屏幕上）: " API_KEY
    echo ""
    [ -n "$API_KEY" ] || { warn "key 不能为空——重新输入"; continue; }

    PROV_NAME="custom"
    log "获取可用模型列表……"
    MODELS_JSON=$(curl -s --max-time 15 "$PROV_BASE/models" -H "Authorization: Bearer $API_KEY" || true)
    PROV_MODEL=""
    if echo "$MODELS_JSON" | grep -q '"id"'; then
        mapfile -t MODEL_LIST < <(echo "$MODELS_JSON" | grep -o '"id" *: *"[^"]*"' | sed 's/.*"id" *: *"//;s/"$//')
        if [ ${#MODEL_LIST[@]} -gt 0 ]; then
            i=1
            for m in "${MODEL_LIST[@]}"; do echo "  [$i] $m"; i=$((i+1)); done
            read -rp "选默认模型序号 [1]: " MODEL_PICK
            MODEL_PICK="${MODEL_PICK:-1}"
            if [[ "$MODEL_PICK" =~ ^[0-9]+$ ]] && [ "$MODEL_PICK" -ge 1 ] && [ "$MODEL_PICK" -le ${#MODEL_LIST[@]} ]; then
                PROV_MODEL="${MODEL_LIST[$((MODEL_PICK-1))]}"
            else
                warn "序号无效——重新输入"; continue
            fi
        else
            read -rp "列表为空——手动输入模型名: " PROV_MODEL
        fi
    else
        read -rp "列表拉取失败（服务商可能不支持）——手动输入模型名: " PROV_MODEL
    fi
    [ -n "$PROV_MODEL" ] || { warn "模型名不能为空——重新输入"; continue; }

    log "正在测试连通……"
    HTTP_CODE=$(curl -s --max-time 20 -o /tmp/hm_probe.json -w "%{http_code}" \
        "$PROV_BASE/chat/completions" \
        -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
        -d "{\"model\":\"$PROV_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}" || echo 000)
    if [ "$HTTP_CODE" = "200" ] && grep -q "choices" /tmp/hm_probe.json 2>/dev/null; then
        rm -f /tmp/hm_probe.json
        ok "通了，额度可用（模型：$PROV_MODEL）"
        break
    fi
    case "$HTTP_CODE" in
        401)      warn "key 不对，检查有没有粘全" ;;
        404)      warn "地址不对（检查是否以 /v1 结尾）" ;;
        429|403)  warn "额度不可用（余额为零或未领取免费额度）" ;;
        000)      warn "连不上服务商（网络问题）" ;;
        400|500)  grep -qi "model" /tmp/hm_probe.json 2>/dev/null \
                      && warn "所选模型不可用（换一个型号试试）" \
                      || warn "验活失败（HTTP $HTTP_CODE）——检查 key 与地址" ;;
        *)        warn "验活失败（HTTP $HTTP_CODE）——检查 key 与地址" ;;
    esac
    rm -f /tmp/hm_probe.json
    warn "——重新输入（不想装了按 Ctrl+C 退出）"
done

# 验活通过才写配置（上游原生机制：custom_providers 四件套 + 设为主模型，与 _model_flow_custom 落盘结构一致）
hermes config set custom_providers.$PROV_NAME.base_url "$PROV_BASE" >/dev/null
hermes config set custom_providers.$PROV_NAME.api_mode chat_completions >/dev/null
hermes config set custom_providers.$PROV_NAME.model "$PROV_MODEL" >/dev/null
hermes config set custom_providers.$PROV_NAME.api_key "$API_KEY" >/dev/null
hermes config set model "$PROV_MODEL" >/dev/null
mark_done config-ai
fi

# ---------- 10. gateway 服务（消息通道 + cron） ----------
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
    warn "hermes gateway install 未成功——微信等通道与 cron 暂不可用。后补：hermes gateway install"
fi

# ---------- 11. 脚本下线 ----------
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
echo "  1. hermes              —— 启动 AI：首次对话它主动采档案（怎么称呼/主要用途/说话方式），"
echo "                            然后按 docs/ONBOARDING.md 引导你连接微信、配置同步"
echo "  2. 改 $VAULT_DIR/HerMemory/memory/ 下任何文件 → 开新对话即生效"
echo ""
log "最后一句话：启动 AI 后，把「部署待办」发给它——剩下的配置它来引导。"
log "文档：docs/INSTALL.md（部署）｜docs/GUIDE.md（使用）｜docs/ONBOARDING.md（AI 的部署手册）"
