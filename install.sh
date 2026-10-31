#!/usr/bin/env bash
# ============================================================
# HerMemory installer — v0.2.0
# 基于 Hermes Agent v0.22.2 (commit d923a5e)，MIT。
# 上游仓库：https://github.com/NousResearch/hermes-agent.git
#
# 做的事：跑随包的官方安装器（clone pin → PM 装 Python/Node/依赖 → 构建 hermes 命令）
#   → 建 vault → 铺出厂五文件 → 软链注入槽位 → 皮肤 → 时区 → 时间注入开关
#   → 记忆档位 → AI 配置 → 微信接入 → gateway 服务。
#
# key 配置：脚本内引导（用户流程 2），底层走上游原生机制；不碰任何商业引导。
#   同步/备份不在安装范围：装完由用户自己决定，AI 不主动引导。
#   随包内核：把 hermes-agent.bundle 放在本脚本同目录即走离线落位；没有就按 GitHub 在线装。
#
# 运行方式：clone 本仓库后，在仓库根目录 bash install.sh（需交互式终端）
# 目标环境：headless Linux（Ubuntu 22/24、主流 NAS）
# ============================================================
set -euo pipefail

HERMEMORY_VERSION="0.2.0"
PINNED_HERMES_TAG="v0.22.2"
# 上游 v0.22 的安装器只认 commit（没有 -Tag 参数），且要求它是 origin/main 的祖先。
# 随包内核是「快照仓库」：pin 的工作树重做成单提交仓库（树字节与 pin 一致、带 pin tag，
# 见 build-offline.ps1）。这里的 commit 是**那个快照提交**，由 hermes-agent.commit 提供；
# 没有戳时退回「按 main 落位」。真实上游 commit = d923a5eb487a17c0a68801bba9ef0f56c81040a8。
PINNED_HERMES_COMMIT=""   # 由随包 hermes-agent.commit 填充（见下方内核段）
UPSTREAM_REPO="https://github.com/NousResearch/hermes-agent.git"
UPSTREAM_DIR="$HOME/hermes-agent"
# 内核 git bundle 直链（由 build-offline.ps1 产出，上传到自己的服务器）。
# 留空 = 跳过直链层，用同目录的 hermes-agent.bundle，再没有就 GitHub clone。
OFFLINE_BUNDLE_URL=""
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
# 无交互安装：跳过记忆档位 / AI 配置 / 微信扫码三段问答，其余照装；
# 装完自己用 hermes model / hermes gateway setup 配（技术用户的常用路径）。
HEADLESS="${HERMEMORY_HEADLESS:-0}"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 本仓库（壳）位置

log()  { printf '\033[36m[HerMemory]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- hermes CLI 的调用口径（2026-09-16 补）----------
# 一律**先把 ~/.local/bin 前置到 PATH**，不依赖"当前 shell 恰好 source 过 .bashrc"。
# 三处会让 hermes 解析不到：
#   ① 非交互 / 非登录 shell（ssh host 'bash install.sh'、sudo、cron）不 source .bashrc；
#   ② 上游安装器里的 export PATH 只作用于**它自己那个进程**，父脚本看不到；
#   ③ 重跑安装器时走"已装"分支，那个分支原本什么都不补——而 set -e 下第一次
#      hermes 调用失败就是**静默中止**（输出被 >/dev/null 吞掉），看不出原因。
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# 配置写入的统一入口：失败时给出**可读原因**，而不是让 set -e 静默收场。
cfg_set() {
    if ! hermes config set "$1" "$2" >/dev/null 2>&1; then
        die "配置写入失败：hermes config set $1 = $2（hermes CLI：$(command -v hermes 2>/dev/null || echo 未找到)）"
    fi
}

# ---------- 断点续装（状态文件记录已完成步骤；删除它 = 全部重来） ----------
STATE_FILE="$HERMES_HOME/.hermemory-install-state"
mkdir -p "$HERMES_HOME"; touch "$STATE_FILE"
done_step() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { done_step "$1" || echo "$1" >> "$STATE_FILE"; }
log "安装状态文件：$STATE_FILE"

# ---------- 交互性检查 ----------
# 脚本要用 read 采集记忆档位与 API Key。stdio 不是终端时 read 会立刻 EOF，
# 在 set -e 下表现为"跑了几行就静默退出"，完全看不出原因（`ssh host 'bash install.sh'`
# 这类非交互调用最容易踩）。只在**确实还有要采集的步骤**时才拦：已经装完的机器
# 仍可用它做无交互的修复重跑。
if [ "$HEADLESS" != "1" ] && [ ! -t 0 ] && { ! done_step memory-tier || ! done_step config-ai; }; then
    die "本脚本需要交互式终端（要采集记忆档位与 API Key），但当前 stdin 不是终端。请登录服务器后在终端里运行：bash install.sh"
fi

# ---------- 0. 环境检查 ----------
[[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux（headless）。PC 端部署见 docs/INSTALL.md。"
[[ $EUID -ne 0 ]] || die "不要用 root 跑安装器；用普通用户 + sudo。"
command -v git  >/dev/null || die "缺 git：先 apt install git"
command -v curl >/dev/null || die "缺 curl：先 apt install curl"

log "安装说明见 docs/INSTALL.md"

# ---------- 1. vault 位置（定名，不询问——路径被提示词与文档广泛引用，固定避免漂移） ----------
# 记忆库位置：默认 ~/vault，可用 HERMEMORY_VAULT_DIR 覆盖（与 Windows 向导里的同类选项对应）
VAULT_DIR="${HERMEMORY_VAULT_DIR:-$HOME/vault}"
case "$VAULT_DIR" in
    /*) ;;
    *) die "HERMEMORY_VAULT_DIR 必须是绝对路径（当前：$VAULT_DIR）" ;;
esac
VAULT_DIR="${VAULT_DIR%/}"

# ---------- 2. 安装上游 Hermes（vendored 官方安装器 + 随包 bundle，pin commit） ----------
# v0.22 起上游装法变了：安装器只负责 clone → PM 装 Python/Node/依赖 → 构建 hermes 命令，
# 重依赖全部由 PM 从 pm/lock.json 的 sha256 钉死制品取。我们不再自己 clone + setup-hermes.sh。
# 判据同 Windows：CLI 真的跑得起来才算装上（venv 由 PM 托管，没有固定路径可查）。
hermes_works() {
    command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1
}

# 「跑得起来」不够：0.1.0 装的 v0.21.0 也跑得起来，只判可用会让升级被静默跳过。
hermes_version() {
    command -v hermes >/dev/null 2>&1 || return 0
    hermes --version 2>/dev/null | sed -n 's/.*Hermes Agent v\([0-9][0-9.]*\).*/\1/p' | head -1
}

# PM 托管的解释器：<HERMES_HOME>/installs/<key>/facts.json 的 packages.venv.environment。
# 与上游 pm/environments.py:_recorded_venv 同一口径；没有就回落 v0.21 的 venv。
resolve_pm_python() {
    local f envdir
    for f in "$HERMES_HOME"/installs/*/facts.json; do
        [ -f "$f" ] || continue
        envdir=$(grep -o '"environment"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//')
        if [ -n "$envdir" ] && [ -x "$envdir/bin/python" ]; then printf '%s\n' "$envdir/bin/python"; return 0; fi
    done
    if [ -x "$UPSTREAM_DIR/venv/bin/python" ]; then printf '%s\n' "$UPSTREAM_DIR/venv/bin/python"; return 0; fi
    return 1
}

HERMES_WANT_VERSION="0.22.2"
if hermes_works && [ "$(hermes_version)" = "$HERMES_WANT_VERSION" ]; then
    log "上游内核：已安装 v$HERMES_WANT_VERSION，跳过"
    mark_done upstream
else
    if hermes_works; then
        HAVE_VERSION="$(hermes_version)"
        # 已有安装比本发行版新就不降级：会动到用户正在用的内核与会话库 schema，且没有回滚保证。
        NEWEST="$(printf '%s\n%s\n' "$HAVE_VERSION" "$HERMES_WANT_VERSION" | sort -V | tail -1)"
        if [ -n "$HAVE_VERSION" ] && [ "$NEWEST" = "$HAVE_VERSION" ] && [ "$HAVE_VERSION" != "$HERMES_WANT_VERSION" ]; then
            die "检测到已有的 Hermes v$HAVE_VERSION 比本发行版锁定的 v$HERMES_WANT_VERSION 更新。为避免降级损坏数据，安装已中止。可选：换更新版的 HerMemory、先卸载现有 Hermes，或改数据目录（HERMES_HOME）做并存。"
        fi
        warn "检测到 Hermes v${HAVE_VERSION:-未知}（本发行版锁定 v$HERMES_WANT_VERSION），将升级内核与运行环境。"
        # 接管已有安装：先备份配置与凭据，给用户一个就地回滚点
        TS="$(date +%Y%m%d-%H%M%S)"
        for f in config.yaml .env; do
            [ -f "$HERMES_HOME/$f" ] && cp "$HERMES_HOME/$f" "$HERMES_HOME/$f.pre-hermemory-$TS" 2>/dev/null || true
        done
        log "已备份现有配置：config.yaml / .env（.pre-hermemory-$TS）"
        KERNEL_UPGRADED=1
        # 落一个标记：升级中途失败/被 Ctrl-C 后重跑，$KERNEL_UPGRADED 这个进程变量就没了，
        # 旧 unit 会继续指向旧 venv。标记让重跑仍然知道"网关必须重建"。
        : > "$HERMES_HOME/.hm-kernel-upgrade" 2>/dev/null || true
    fi
    # 联网预检：PM 要下载 Python / Node / 依赖（GitHub，失败回退 hermes-assets 镜像）。
    # 没网时上游会在深处报一串 Python 下载异常——提前用中文说清楚。
    if ! curl -sI -m 8 https://github.com >/dev/null 2>&1 \
       && ! curl -sI -m 8 https://hermes-assets.nousresearch.com >/dev/null 2>&1; then
        die "无法联网：安装需要下载 Python / Node / 依赖（GitHub 或镜像 hermes-assets.nousresearch.com）。请检查网络或代理后重试。"
    fi


    UPSTREAM_INSTALLER="$SRC/scripts/upstream-install.sh"
    [ -f "$UPSTREAM_INSTALLER" ] || die "缺 vendored 上游安装器：$UPSTREAM_INSTALLER（发行包不完整，请重新 git clone 本仓库）"

    # 境内索引：PM 只把 UV_* / PIP_* 的索引类设置转发给 uv（pm/index_config.py），官方口子。
    # ⚠ 必须写 ${VAR:-}：本脚本 set -u，干净环境下裸引用外部变量会当场 unbound variable 退出。
    [ -n "${UV_DEFAULT_INDEX:-}" ]    || export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
    [ -n "${PIP_INDEX_URL:-}" ]       || export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
    [ -n "${npm_config_registry:-}" ] || export npm_config_registry="https://registry.npmmirror.com"
    # 引导阶段的 CPython 由 uv 直连 GitHub 下载；npmmirror 有同源镜像。
    [ -n "${UV_PYTHON_INSTALL_MIRROR:-}" ] || export UV_PYTHON_INSTALL_MIRROR="https://registry.npmmirror.com/-/binary/python-build-standalone"
    log "在线镜像：PyPI 走清华 / npm 走 npmmirror / CPython 走 npmmirror（用户已自设则沿用）"

    # ---- 代理自愈（2026-10-26）----
    # 装过 clash / v2ray 的机器常留着 HTTP(S)_PROXY 指向已经退出的本地端口：uv / pip / curl
    # 每次连接都被内核直接拒绝（ECONNREFUSED），而安装要到很深处才炸，报一串英文。
    # 开跑前逐个探端口，连不上就摘掉变量并说清楚。
    _probe_tcp() {
        local hp="$1" host port
        case "$hp" in *://*) hp="${hp#*://}" ;; esac
        hp="${hp%%/*}"
        case "$hp" in *:*) host="${hp%:*}" ; port="${hp##*:}" ;; *) return 0 ;; esac
        [ -n "$host" ] && [ -n "$port" ] || return 0
        if command -v timeout >/dev/null 2>&1; then
            timeout 1 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
        else
            (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null
        fi
    }
    _dead_proxies=""
    for _pv_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
        eval "_pv_val=\${$_pv_name:-}"
        [ -n "${_pv_val:-}" ] || continue
        if ! _probe_tcp "$_pv_val"; then
            unset "$_pv_name"
            _dead_proxies="$_dead_proxies $_pv_name=$_pv_val"
        fi
    done
    if [ -n "$_dead_proxies" ]; then
        warn "已忽略连不上的代理设置（端口没有在听）：$_dead_proxies；本次安装全程直连。"
    fi
    # 国内镜像直连更快更稳：塞进 NO_PROXY，别让用户的外网代理绕一圈。
    for _np in registry.npmmirror.com pypi.tuna.tsinghua.edu.cn mirrors.aliyun.com mirrors.ustc.edu.cn localhost 127.0.0.1; do
        case ",${NO_PROXY:-}," in
            *",$_np,"*) ;;
            *) NO_PROXY="${NO_PROXY:+$NO_PROXY,}$_np" ;;
        esac
    done
    export NO_PROXY

    # 内核来源：同目录 bundle → 直链 bundle → GitHub（由上游自己 clone）
    KERNEL_BUNDLE=""
    for cand in "$SRC/hermes-agent.bundle" "$PWD/hermes-agent.bundle"; do
        [ -f "$cand" ] && KERNEL_BUNDLE="$cand" && break
    done
    if [ -z "$KERNEL_BUNDLE" ] && [ -n "$OFFLINE_BUNDLE_URL" ]; then
        log "下载内核 bundle……"
        tmp_bundle="$(mktemp -d)/hermes-agent.bundle"
        if curl -fL --retry 2 --max-time 900 -o "$tmp_bundle" "$OFFLINE_BUNDLE_URL"; then
            KERNEL_BUNDLE="$tmp_bundle"
        else
            warn "bundle 直链下载失败，转 GitHub clone"
        fi
    fi
    if [ -n "$KERNEL_BUNDLE" ]; then
        export HERMES_REPO_URL="$KERNEL_BUNDLE"
        ok "内核来源：随包 bundle（$KERNEL_BUNDLE）"
    else
        export HERMES_REPO_URL="$UPSTREAM_REPO"
        log "内核来源：GitHub（$UPSTREAM_REPO）"
    fi

    # 快照 commit 戳（build-offline.ps1 产出）：有就做 -Commit 钉住，没有就按 main 落位。
    if [ -z "$PINNED_HERMES_COMMIT" ] && [ -f "$SRC/hermes-agent.commit" ]; then
        PINNED_HERMES_COMMIT="$(tr -d '[:space:]' < "$SRC/hermes-agent.commit" 2>/dev/null || true)"
    fi
    # 没有随包 bundle 时，快照提交（hermes-agent.commit）在 GitHub 上根本不存在——只存在于
    # bundle 里。这时改钉「真实上游提交」，Linux 装出来的才是锁定的 v0.22.2，而不是上游 main
    # 的最新版（2026-10-30 容器实测：没这一步装成了 v0.22.5）。
    if [ -z "$KERNEL_BUNDLE" ] && [ -f "$SRC/hermes-agent.upstream-commit" ]; then
        PINNED_HERMES_COMMIT="$(tr -d '[:space:]' < "$SRC/hermes-agent.upstream-commit" 2>/dev/null || true)"
        log "内核来源为 GitHub：钉住上游提交 ${PINNED_HERMES_COMMIT:0:12}（$PINNED_HERMES_TAG）"
    fi

    # 浏览器与电脑操作：默认装。设 HERMEMORY_SKIP_BROWSER=1 / HERMEMORY_SKIP_COMPUTER_USE=1 可跳过
    # （上游会把选择记进 declined-packages.json，之后 hermes update 也不会加回来）。
    inst_args=(--non-interactive --branch main
               --dir "$UPSTREAM_DIR" --hermes-home "$HERMES_HOME")
    [ -n "$PINNED_HERMES_COMMIT" ] && inst_args+=(--commit "$PINNED_HERMES_COMMIT")
    [ "${HERMEMORY_SKIP_BROWSER:-0}" = "1" ]      && inst_args+=(--skip-browser)
    [ "${HERMEMORY_SKIP_COMPUTER_USE:-0}" = "1" ] && inst_args+=(--skip-computer-use)

    if [ -n "$PINNED_HERMES_COMMIT" ]; then
        log "运行官方安装器（pin $PINNED_HERMES_TAG / ${PINNED_HERMES_COMMIT:0:12}）……"
    else
        log "运行官方安装器（pin $PINNED_HERMES_TAG，按 main 落位）……"
    fi
    bash "$UPSTREAM_INSTALLER" "${inst_args[@]}" || die "上游安装失败，见上方输出。重跑可续装。"

    export PATH="$HOME/.local/bin:$PATH"
    hermes_works || die "上游安装结束，但 hermes CLI 仍不可用。看 $HERMES_HOME/logs/ 下的日志；重跑可续装。"
    ok "hermes CLI 就绪"
    mark_done upstream
fi

# ---------- 2.45 微信通道依赖（PM 的 messaging extra） ----------
# v0.22 政策：平台 SDK 不进 [all]，缺了只给「hermes pm install --extra messaging」的提示。
# 这里替用户执行那条提示，否则「扫码即用」不成立。
if hermes pm install --extra messaging >/dev/null 2>&1; then
    ok "微信通道依赖已就位（messaging extra）"
else
    warn "messaging extra 安装失败：扫码可能不可用。稍后可手动执行 hermes pm install --extra messaging"
fi

# ---------- 2.5 内核 UX 补丁（发行版自有，幂等）：微信二维码只打印链接 ----------
WX_PY="$UPSTREAM_DIR/gateway/platforms/weixin.py"
WX_PATCH="$SRC/scripts/patch_weixin_qr.py"
if [ -f "$WX_PY" ] && [ -f "$WX_PATCH" ]; then
    if PM_PY="$(resolve_pm_python)"; then
        "$PM_PY" "$WX_PATCH" "$WX_PY" || true
    else
        warn "找不到 PM 托管的解释器，跳过内核补丁（不影响扫码，只是终端多一坨字符画）"
    fi
fi

# ---------- 2.6 每日新对话脚本 ----------
# 设置页「每日新对话」用 cron 的 --script X --no-agent 执行它；cron 只认
# $HERMES_HOME/scripts/ 下的文件。默认不创建定时任务（自动化默认关闭）。
if [ -f "$SRC/scripts/hermemory_daily_new.py" ]; then
    mkdir -p "$HERMES_HOME/scripts"
    cp "$SRC/scripts/hermemory_daily_new.py" "$HERMES_HOME/scripts/hermemory_daily_new.py"
    ok "每日新对话脚本已就位：$HERMES_HOME/scripts"
fi

# ---------- 3. vault 结构 ----------
mkdir -p "$VAULT_DIR/HerMemory/memory"
ok "记忆库结构：$VAULT_DIR/{用户文档, HerMemory/memory/}"

# ---------- 4. 出厂四文件（已存在则绝不覆盖——那是你的记忆） ----------
for f in MEMORY.md USER.md SOUL.md AGENTS.md AUTOMATION.md; do
    dst="$VAULT_DIR/HerMemory/memory/$f"
    if [ -f "$dst" ]; then
        log "已存在，跳过：$dst（不覆盖既有文件）"
    else
        cp "$SRC/memory/$f" "$dst"
        ok "铺设出厂文件：HerMemory/memory/$f"
    fi
done

# ---------- 4.5 使用文档进记忆库（AI 可读） ----------
mkdir -p "$VAULT_DIR/HerMemory/docs"
cp -R "$SRC/docs/." "$VAULT_DIR/HerMemory/docs/"
ok "使用文档已就位：HerMemory/docs/"

# ---------- 4.7 非默认记忆库：把文档与提示词里的 ~/vault 换成真实路径 ----------
DEFAULT_VAULT="$HOME/vault"
if [ "$VAULT_DIR" != "$DEFAULT_VAULT" ]; then
    for t in "$VAULT_DIR/HerMemory/memory/AGENTS.md" "$VAULT_DIR"/HerMemory/docs/*.md; do
        [ -f "$t" ] || continue
        grep -q '~/vault' "$t" || continue
        python3 - "$t" "$VAULT_DIR" <<'PYEOF' 2>/dev/null || sed -i "s|~/vault|$VAULT_DIR|g" "$t"
import io, sys
path, vault = sys.argv[1], sys.argv[2]
with io.open(path, encoding="utf-8") as fh:
    text = fh.read()
with io.open(path, "w", encoding="utf-8", newline="") as fh:
    fh.write(text.replace("~/vault", vault))
PYEOF
    done
    ok "记忆库位置：$VAULT_DIR（文档与提示词已改用该路径）"
else
    log "记忆库位置：$VAULT_DIR（默认）"
fi

# ---------- 5. 软链四件（官方注入槽位，零代码） ----------
#   SOUL.md  → $HERMES_HOME/SOUL.md            （身份槽 slot#1）
#   AGENTS.md→ $HERMES_HOME/AGENTS.md          （官方 context file 通道）
#   MEMORY.md / USER.md → $HERMES_HOME/memories/（原生双文件，全量注入）
link_one() { # link_one <记忆库侧文件> <agent侧路径>
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        log "符号链接已就位：$dst"
    elif [ -e "$dst" ] && [ ! -L "$dst" ]; then
        local bak="$dst.pre-hermemory.$(date +%s)"
        mv "$dst" "$bak"
        warn "已有文件 $dst，已备份为 $bak，随后建立链接"
        ln -s "$src" "$dst"
    else
        ln -sfn "$src" "$dst"
    fi
    ok "符号链接：$dst -> $src"
}
link_one "$VAULT_DIR/HerMemory/memory/SOUL.md"   "$HERMES_HOME/SOUL.md"
# AGENTS.md 的注入槽位是"会话工作目录链"（git 根→cwd），不是 HERMES_HOME。
# 槽位用 .hermes.md（Hermes 专属、优先级最前）：用户可见文件仍是 vault 里的 AGENTS.md，
# 且不会污染机器上其他遵循 AGENTS 约定的工具（Codex CLI 等不读 .hermes.md）。
link_one "$VAULT_DIR/HerMemory/memory/AGENTS.md" "$HOME/.hermes.md"

# memories 整目录软链（与 Windows 版 junction 同构）：hermes 的 memories 路径硬编码
# （agent/learning_mutations.py: get_hermes_home()/"memories"），目录级重定向使其对
# memories\ 的任何写入方式——含 atomic_replace 的 tmp+rename 原子替换——天然落在
# vault 内。Linux 符号链接免特权，且上游断链保护只认 symlink（正好覆盖）。
mem_dir="$HERMES_HOME/memories"
mem_target="$VAULT_DIR/HerMemory/memory"
mkdir -p "$mem_target"
if [ -L "$mem_dir" ] && [ "$(readlink "$mem_dir")" = "$mem_target" ]; then
    log "memories 符号链接已就位：$mem_dir"
else
    if [ -e "$mem_dir" ] && [ ! -L "$mem_dir" ]; then
        bak="$mem_dir.pre-hermemory.$(date +%s)"
        mv "$mem_dir" "$bak"
        warn "已有目录 $mem_dir，已备份为 $bak，随后建立链接（既有记忆已迁移）"
    elif [ -L "$mem_dir" ]; then
        rm "$mem_dir"
    fi
    ln -s "$mem_target" "$mem_dir"
    ok "memories 已以符号链接挂载至 vault：$mem_dir -> $mem_target"
fi

# ---------- 5.5 命令别名 hermemory ----------
# 用户装的是 HerMemory，终端里却要敲 hermes——补一个等价别名，纯转发，不带任何逻辑。
if [ -d "$HOME/.local/bin" ]; then
    cat > "$HOME/.local/bin/hermemory" <<'EOS'
#!/usr/bin/env sh
# hermemory = hermes（HerMemory 发行版的等价命令）
self=$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")
dir=$(CDPATH= cd -- "$(dirname -- "$self")" 2>/dev/null && pwd)
if [ -n "$dir" ] && [ -x "$dir/hermes" ]; then
    exec "$dir/hermes" "$@"
fi
exec hermes "$@"
EOS
    chmod +x "$HOME/.local/bin/hermemory"
    ok "命令别名：hermemory（等价于 hermes）"
fi

# ---------- 6. 品牌皮肤 ----------
mkdir -p "$HERMES_HOME/skins"
cp "$SRC/skins/hermemory.yaml" "$HERMES_HOME/skins/hermemory.yaml"
hermes config set display.skin hermemory >/dev/null 2>&1 && ok "皮肤已配置：HerMemory（/skin 可切换）" \
    || warn "display.skin 写入失败（非致命）。可运行时执行 /skin hermemory 手动切换。"
# 配了不等于生效：皮肤 YAML 缺顶层 name 字段会被加载器静默丢弃（0.1.0 的旧文件就是这样，
# 回复前缀仍是默认的「⚕ Hermes」）。这里以 skin list 的实际结果为准。
if hermes skin list 2>/dev/null | grep -qE '(^|[[:space:]])hermemory([[:space:]]|$)'; then
    ok "皮肤已生效：hermemory"
else
    warn "皮肤未生效：hermemory.yaml 未被识别（检查文件顶层是否有 name: hermemory）"
fi

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
    && ok "时间注入已开启：每条用户消息头部自动附加服务器时间" \
    || die "gateway.message_timestamps.enabled 写入失败"
hermes config set display.language zh >/dev/null 2>&1 \
    && ok "界面语言：中文" \
    || warn "display.language 写入失败（非致命）"
# 进程级兜底：配置写在 HERMES_HOME，网关若在写入前启动会缓存英文；环境变量优先级更高，
# 顺带让硬编码活动描述的中文化补丁生效。
if ! grep -q 'HERMES_LANGUAGE' "$HOME/.bashrc" 2>/dev/null; then
    printf '\nexport HERMES_LANGUAGE=zh\n' >> "$HOME/.bashrc" 2>/dev/null || true
fi
export HERMES_LANGUAGE=zh
hermes config set display.timestamps true >/dev/null 2>&1 \
    && ok "对话时间标签 [HH:MM]：已开启" \
    || warn "display.timestamps 写入失败（非致命）"

# ---------- 9. 记忆档位（新手引导1：多档可选） ----------
if [ "$HEADLESS" = "1" ]; then
    log "无交互模式：跳过记忆档位（沿用默认 2200 / 1375，之后可用 memory-size.sh 改）"
elif [ -f "$HERMES_HOME/config.yaml" ] && grep -qE '^[[:space:]]+memory_char_limit:[[:space:]]*[0-9]+' "$HERMES_HOME/config.yaml"; then
    log "记忆档位：沿用现有配置（要改：bash memory-size.sh）"
    mark_done memory-tier
elif done_step memory-tier; then
    log "记忆档位：已完成（自动跳过）"
else
log "MEMORY / USER 容量设置"
echo ""

echo "  容量提升增强记忆能力，同时降低专注度。建议选择 1-2 档。"
echo ""

echo "  1. 紧凑：2200 / 1375（默认）"
echo "  2. 标准：5000 / 3000"
echo "  3. 详细：10000 / 5000"
echo ""

read -rp "请选择记忆档位（1/2/3）: " MEM_CHOICE
MEM_CHOICE="${MEM_CHOICE:-1}"
case "$MEM_CHOICE" in
    2) MEM_LIMIT=5000;  USER_LIMIT=3000  ;;
    3) MEM_LIMIT=10000; USER_LIMIT=5000  ;;
    *) MEM_LIMIT=2200;  USER_LIMIT=1375  ;;
esac
hermes config set memory.memory_char_limit "$MEM_LIMIT"  >/dev/null
hermes config set memory.user_char_limit   "$USER_LIMIT" >/dev/null
ok "记忆档位：MEMORY $MEM_LIMIT / USER $USER_LIMIT 字符（调整：memory-size.sh）"
mark_done memory-tier
fi

# ---------- 9.5/9.6 配置 AI（用户流程 2：地址先验证，Key 后验证；Key 阶段输 1 可返回地址；完成后 AI 上线） ----------
if [ "$HEADLESS" = "1" ]; then
    log "无交互模式：跳过 AI 配置（之后执行 hermes model 或 hermes config set 配置）"
elif [ -f "$HERMES_HOME/config.yaml" ] && grep -qE '^[[:space:]]+api_key:[[:space:]]*[^[:space:]"'"'"']+' "$HERMES_HOME/config.yaml"; then
    log "检测到已有模型配置：沿用（要改：hermes model）"
    mark_done config-ai
elif done_step config-ai; then
    log "配置 AI：已完成，自动跳过"
else
echo ""
echo "HerMemory 永久免费。AI 每次回答消耗服务商算力，需自备接口凭据。"
echo ""
echo "  需要准备两项"
echo ""
echo "  1. Base URL"
echo "     以 https 开头、/v1 结尾。控制台中可能标注为：API 地址 / OpenAI 兼容地址。"
echo ""
echo "  2. API Key"
echo "     一长串字符，通常以 sk- 开头。控制台中可能标注为：API key / API 密钥。"
echo ""


AT_URL=1
while true; do
    if [ "$AT_URL" = "1" ]; then
        log "第一步：验证 API 地址"
        while true; do
            echo ""
            read -rp "请输入 API 地址: " PROV_BASE
            echo ""
            # 只保留可见 ASCII——剔除复制粘贴混入的零宽/全角/控制字符
            PROV_BASE=$(printf '%s' "$PROV_BASE" | LC_ALL=C tr -d '\000-\040\177-\377')
            PROV_BASE="${PROV_BASE%/}"
            log "正在验证 API 地址……"
            URL_CODE=$(curl -s --noproxy '*' --max-time 20 -o /tmp/hm_url_test.json -w "%{http_code}" "$PROV_BASE/models" || true)
            [ "$URL_CODE" = "000" ] && URL_CODE=$(curl -s --max-time 20 -o /tmp/hm_url_test.json -w "%{http_code}" "$PROV_BASE/models" || true)
            if [ "$URL_CODE" = "000" ]; then
                warn "[连接超时] 无法连接该地址。请检查：地址是否为服务商的 OpenAI 兼容接口（通常以 /v1 结尾）；本机能否访问互联网；若已开启代理，可关闭或更换节点后重试"
                continue
            fi
            if [ "$URL_CODE" = "404" ]; then
                warn "[404] 接口路径不存在。请核对是否为服务商标注的 OpenAI 兼容地址"
                continue
            fi
            ok "API 地址可达（HTTP $URL_CODE）"
            break
        done
        AT_URL=0
    fi

    log "第二步：验证 API Key（输入 1 返回上一步）"
    echo ""
    read -rp "请输入 API Key: " API_KEY
    echo ""
    API_KEY=$(printf '%s' "$API_KEY" | LC_ALL=C tr -d '\000-\040\177-\377')
    if [ "$API_KEY" = "1" ]; then AT_URL=1; continue; fi
    [ -n "$API_KEY" ] || { warn "API Key 不能为空，请重新输入"; continue; }

    log "正在验证 API Key……"
    HTTP_CODE=$(curl -s --noproxy '*' --max-time 20 -o /tmp/hm_models.json -w "%{http_code}" "$PROV_BASE/models" -H "Authorization: Bearer $API_KEY" || true)
    [ "$HTTP_CODE" = "000" ] && HTTP_CODE=$(curl -s --max-time 20 -o /tmp/hm_models.json -w "%{http_code}" "$PROV_BASE/models" -H "Authorization: Bearer $API_KEY" || true)
    case "$HTTP_CODE" in
        401|403)
            warn "[$HTTP_CODE] 认证未通过（服务返回：$(head -c 150 /tmp/hm_models.json 2>/dev/null)）。请确认 API Key 复制完整（注意首尾空格与截断），且该 Key 在服务商控制台处于启用状态"
            continue ;;
        000)
            warn "[连接超时] 网络异常。重新输入，或输 1 返回上一步" ;;
    esac
    if [ "$HTTP_CODE" != "200" ]; then
        warn "[$HTTP_CODE] 服务商暂时故障或限流。稍等几秒重试；持续出现请检查服务商状态页"
        continue
    fi
    if ! grep -q '"data"' /tmp/hm_models.json 2>/dev/null; then
        warn "[格式异常] 该地址返回的内容不是标准接口响应（HTTP $HTTP_CODE）。请确认使用的是 API 接口地址，而非控制台网页地址"
        continue
    fi
    mapfile -t MODEL_LIST < <(grep -o '"id" *: *"[^"]*"' /tmp/hm_models.json | sed 's/.*"id" *: *"//;s/"$//' || true)
    if [ ${#MODEL_LIST[@]} -eq 0 ]; then
        # 有些服务商不实现 /models：不让用户卡死在这里，直接手填型号
        warn "连接正常，但没有返回模型列表（部分服务商不提供 /models）。"
        read -rp "请直接输入模型名（例如 deepseek-chat）: " PROV_MODEL
        PROV_MODEL=$(printf '%s' "$PROV_MODEL" | tr -d '[:space:]')
        [ -n "$PROV_MODEL" ] || { warn "模型名不能为空，请重新输入"; continue; }
        ok "模型：$PROV_MODEL"
        break
    fi
    ok "连接正常，检测到 ${#MODEL_LIST[@]} 个可用模型。"
    break
done

i=1
for m in "${MODEL_LIST[@]}"; do echo "  [$i] $m"; i=$((i+1)); done
while true; do
    read -rp "请选择模型序号（0 = 手动输入模型名）: " MODEL_PICK
    if [ "$MODEL_PICK" = "0" ]; then
        read -rp "请输入模型名: " PROV_MODEL
        PROV_MODEL=$(printf '%s' "$PROV_MODEL" | tr -d '[:space:]')
        [ -n "$PROV_MODEL" ] && break
        warn "模型名不能为空"
        continue
    fi
    if [[ "$MODEL_PICK" =~ ^[0-9]+$ ]] && [ "$MODEL_PICK" -ge 1 ] && [ "$MODEL_PICK" -le ${#MODEL_LIST[@]} ]; then
        PROV_MODEL="${MODEL_LIST[$((MODEL_PICK-1))]}"
        break
    fi
    warn "序号无效，重新选择"
done

# 上游机制（_model_flow_custom）：key 存 .env 的 HERMES_CUSTOM_<主机>_API_KEY；
# config model 段 = provider custom + base_url + api_key ${ENV引用} + api_mode。
# 绝不能写 OPENAI_API_KEY——auto 路由见到它会劫持到 OpenRouter。
HOSTPORT=$(printf '%s' "$PROV_BASE" | sed -E 's#^https?://([^/]+).*#\1#')
SLUG=$(printf '%s' "$HOSTPORT" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//')
KEY_ENV="HERMES_CUSTOM_${SLUG}_API_KEY"
hermes config set "$KEY_ENV" "$API_KEY" >/dev/null
grep -q "^${KEY_ENV}=" "$HERMES_HOME/.env" 2>/dev/null || echo "${KEY_ENV}=$API_KEY" >> "$HERMES_HOME/.env"
# 清除会劫持路由的 OPENAI_*（上游明确告警的 env 污染场景）。
# ⚠ || true 必需：key 不存在时上游 unset_config_value 的两条分支（env 路径与 config 路径）
#   都是 print("Config key not set") + sys.exit(1)，与分支无关。本脚本 set -e，而 stderr
#   已被 2>&1 吞掉 → 干净机器上用户刚选完模型序号，安装器无一句报错当场死在 AI 上线前一步。
#   真正兜底的是下面那段 sed（直接删 .env 里的 OPENAI_* 两行）；这两行只是让上游顺带做
#   完整的凭据生命周期清理（credential_pool / model-cache 行），做成尽力而为即可。
hermes config unset OPENAI_API_KEY  >/dev/null 2>&1 || true
hermes config unset OPENAI_BASE_URL >/dev/null 2>&1 || true
# 存在性保护：上游 config set 有可能没把 .env 落盘（Windows 侧踩过同一处），
# 而 set -e 下 sed -i 对不存在的文件会直接中断安装。
if [ -f "$HERMES_HOME/.env" ]; then
    sed -i '/^OPENAI_API_KEY=/d; /^OPENAI_BASE_URL=/d' "$HERMES_HOME/.env"
fi
cfg_set model.default "$PROV_MODEL"
cfg_set model.provider custom
cfg_set model.base_url "$PROV_BASE"
cfg_set model.api_key "\${${KEY_ENV}}"
cfg_set model.api_mode chat_completions
# 落盘验证：缺则直改文件
grep -q "provider: custom" "$HERMES_HOME/config.yaml" 2>/dev/null || sed -i 's/^  provider: .*/  provider: custom/' "$HERMES_HOME/config.yaml"
if ! grep -q 'api_key: \${'"$KEY_ENV"'}' "$HERMES_HOME/config.yaml" 2>/dev/null; then
    # 旧的 sed 兜底是坏的：嵌套 ${${KEY_ENV}} 在 bash 里是 bad substitution，set -e 直接中断；
    # 就算展开成功，`a\` 也只追加一行，YAML 结构是错的。宁可停下来说清楚怎么补。
    die "config.yaml 里没有写入 model.api_key（可能被其他进程占用）。请手动执行：hermes config set model.api_key '\${$KEY_ENV}' 后重新运行安装。"
fi
ok "配置完成（模型：$PROV_MODEL）"
mark_done config-ai
fi

# ---------- 10. 微信扫码接入（可选；完成后 AI 直接出现在用户微信） ----------
WX_CONFIGURED=0
if grep -q "WEIXIN_ACCOUNT_ID" "$HERMES_HOME/.env" 2>/dev/null; then
    WX_CONFIGURED=1
    ok "微信通道：已配置（跳过扫码）"
elif [ "$HEADLESS" = "1" ]; then
    warn "无交互模式：跳过微信接入（之后执行 hermes gateway setup 扫码）"
else
    log "微信接入"
    echo "上游将启动英文配置向导。对照下表作答："
    echo ""
    echo "  向导提问                                          应答"
    echo "  ────────────────────────────────────────────────────────"
    echo "  Select platform                                   Weixin / WeChat 对应序号"
    echo "  输出二维码链接                                     复制到浏览器打开，"
    echo "                                                    微信扫码并确认"
    echo "  How should direct messages be authorized?         输入 3"
    echo "  Allowed Weixin user IDs                           回车（已预填）"
    echo "  How should group chats be handled?                输入 1"
    echo "  其余提问                                           回车取默认"
    echo ""
    echo "  向导完成后自动关闭。暂不接入可关闭向导窗口。"
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
        warn "微信未配置成功（二维码可能已超时）"
        read -rp "重新打开向导扫码？[y/n]: " WX_RETRY
        [[ "$WX_RETRY" =~ ^[Nn] ]] && break
    done
    if [ "$WX_CONFIGURED" = "1" ]; then
        # 兜底：统一消息授权为 allowlist（防止向导默认的 pairing 拦截首条微信消息）
        # 账号 JSON 的位置随 HERMES_HOME 走（**不能硬编码 ~/.hermes**：自定义数据目录时
        # 会读不到本人 ID，allowlist 便写不进去 → 首条微信消息被 pairing 拦下）。
        # python 优先用 venv 里的真身，不假设系统装了 python3。
        # 变量名避开 WX_PY：那个名字在上面（2.5 段内核补丁）指的是"要打补丁的 weixin.py"，
        # 这里指的是解释器——同名会让后来改那一段的人踩坑。
        # 解释器优先用 PM 托管环境（v0.22 起没有固定的 venv 路径），再回落系统 python3。
        # 这只是读一个 JSON 里的 user_id，不需要 venv 里的依赖。
        WX_PYTHON=""
        if WX_PYTHON="$(resolve_pm_python)"; then
            :
        elif command -v python3 >/dev/null 2>&1; then
            WX_PYTHON="python3"
        fi
        WX_USER_ID=""
        if [ -n "$WX_PYTHON" ]; then
            WX_USER_ID=$(HERMES_HOME="$HERMES_HOME" "$WX_PYTHON" -c "
import json, glob, os
home = os.environ.get('HERMES_HOME') or os.path.expanduser('~/.hermes')
files = sorted(glob.glob(os.path.join(home, 'weixin/accounts/*.json')), key=os.path.getmtime)
print(json.load(open(files[-1])).get('user_id', '') if files else '')" 2>/dev/null || true)
        fi
        if [ -n "$WX_USER_ID" ]; then
            if grep -qE '^(export )?WEIXIN_DM_POLICY=' "$HERMES_HOME/.env" 2>/dev/null; then
                sed -i -E 's|^(export )?WEIXIN_DM_POLICY=.*|WEIXIN_DM_POLICY=allowlist|' "$HERMES_HOME/.env"
            else
                echo "WEIXIN_DM_POLICY=allowlist" >> "$HERMES_HOME/.env"
            fi
            if grep -qE '^(export )?WEIXIN_ALLOWED_USERS=' "$HERMES_HOME/.env" 2>/dev/null; then
                sed -i -E "s|^(export )?WEIXIN_ALLOWED_USERS=.*|WEIXIN_ALLOWED_USERS=$WX_USER_ID|" "$HERMES_HOME/.env"
            else
                echo "WEIXIN_ALLOWED_USERS=$WX_USER_ID" >> "$HERMES_HOME/.env"
            fi
            ok "消息授权：仅允许本人微信 ID"
        fi
    fi
fi

# ---------- 10.5 兼容 0.1.x：把 OPENAI_* 迁移成 model.* ----------
# v0.22 的 auth.py 见到 OPENAI_API_KEY 会按它选 provider（自定义端点会被劫持到 OpenRouter）。
# 0.1.x 的安装器正是把自定义端点写成 OPENAI_BASE_URL / OPENAI_API_KEY 的，这里就地迁移：
#   · model.* 三件套（base_url / api_key / default）齐了 → 只删旧变量
#   · 缺任一件且能读到模型名 → 用旧值补出 HERMES_CUSTOM_<host>_API_KEY + model.*
#   · 取不到模型名 → 原样保留并提示，绝不在没有模型名的情况下把凭据删掉
# .env 里允许带可选的 export 前缀，匹配与删除都要认这一形态。
_cfg_has() {
    local _v
    _v="$(hermes config get "$1" 2>/dev/null || true)"
    case "$_v" in
        ""|*"not set"*|*"Config key"*|*"Error"*) return 1 ;;
        *) return 0 ;;
    esac
}
if [ -f "$HERMES_HOME/.env" ]; then
    # 尾部 `|| true`：set -o pipefail 下 grep 没匹配到就是非零，会让整个脚本静默退出
    # （2026-10-30 容器实测：没有 OPENAI_BASE_URL 时安装到微信那步后无声 EXIT=1）。
    _olb="$(grep -E '^(export )?OPENAI_BASE_URL=' "$HERMES_HOME/.env" | head -1 | sed -E 's/^(export )?OPENAI_BASE_URL=//' | tr -d '\r' | tr -d '"' || true)"
    _okey="$(grep -E '^(export )?OPENAI_API_KEY=' "$HERMES_HOME/.env" | head -1 | sed -E 's/^(export )?OPENAI_API_KEY=//' | tr -d '\r' | tr -d '"' || true)"
    if [ -n "$_olb" ] && [ -n "$_okey" ] && [ "${_olb#*api.openai.com}" = "$_olb" ]; then
        _cfg_complete=0
        if _cfg_has model.base_url && _cfg_has model.api_key && _cfg_has model.default; then
            _cfg_complete=1
        fi
        if [ "$_cfg_complete" = "1" ]; then
            sed -i -E '/^(export )?OPENAI_(API_KEY|BASE_URL)=/d' "$HERMES_HOME/.env"
            ok "已清理旧版遗留的 OPENAI_*（会劫持模型路由）"
        else
            _m="$(hermes config get model.default 2>/dev/null | tr -d '[:space:]' || true)"
            case "$_m" in ""|*Config*|*not*|*Error*) _m="" ;; esac
            if [ -z "$_m" ]; then
                warn "检测到旧版 OPENAI_*，但读不到模型名，已原样保留；请执行 hermes model 重新配置"
            else
                _slug="$(printf '%s' "$_olb" | sed -E 's#^https?://([^/]+).*#\1#' | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//')"
                _kenv="HERMES_CUSTOM_${_slug}_API_KEY"
                hermes config set "$_kenv" "$_okey" >/dev/null 2>&1 || true
                grep -qE "^(export )?${_kenv}=" "$HERMES_HOME/.env" 2>/dev/null || echo "${_kenv}=$_okey" >> "$HERMES_HOME/.env"
                cfg_set model.base_url "$_olb"
                cfg_set model.provider custom
                cfg_set model.api_key "\${${_kenv}}"
                cfg_set model.api_mode chat_completions
                cfg_set model.default "$_m"
                sed -i -E '/^(export )?OPENAI_(API_KEY|BASE_URL)=/d' "$HERMES_HOME/.env"
                ok "已把旧版 OPENAI_* 迁移为 model.* 配置（模型：$_m）"
            fi
        fi
    fi
fi

# ---------- 11. gateway 服务（消息通道 + cron） ----------
if [ "${KERNEL_UPGRADED:-0}" = "1" ] || [ -f "$HERMES_HOME/.hm-kernel-upgrade" ]; then
    # 内核换了版本：旧 systemd 单元里的解释器/工作目录都是旧的，留着它网关就起不来。
    # 先停掉并删单元，让下面那段老老实实重装。
    log "内核已升级：重建 gateway 服务单元"
    hermes gateway stop >/dev/null 2>&1 || true
    # 只删 gateway 单元，别把同目录下别的 hermes-*.service 一起误杀
    rm -f "$HOME/.config/systemd/user/hermes-gateway"*.service "$HOME/.config/systemd/user/hermes.service" 2>/dev/null || true
    : > "$HERMES_HOME/.hm-kernel-upgrade" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
fi
log "安装 gateway 服务……"
# 上游 CLI 以 sys.stdin.isatty() 判定交互性
#（hermes_cli/gateway.py：non_interactive = not sys.stdin.isatty()）：从终端运行时为交互态，
# 会问 "Start the gateway now / on login?"。旧实现把 stdout 丢进 /dev/null——提示不可见、
# 终端看似冻住（2026-09-10 与 Windows 侧同一类 bug，触发条件不同）。
# 注意：此分支 **不读** HERMES_NONINTERACTIVE，设它无效。修法二合一：
#   ① 显式传 --start-now / --start-on-login 定调，不依赖任何自动判定；
#   ② stdin 接 /dev/null 使 isatty() 为假 → non_interactive=True，连带压掉 systemd_install
#      内部的 legacy-unit 提问（gateway.py:4498）。
# 输出落日志文件（而非 /dev/null）：失败时回显尾部，便于定位——不再静默。
GW_LOG="${TMPDIR:-/tmp}/hm-gateway-install.log"
GW_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then GW_TIMEOUT="timeout 240"; fi
if $GW_TIMEOUT hermes gateway install --start-now --start-on-login < /dev/null > "$GW_LOG" 2>&1; then
    ok "gateway 服务已安装"
    rm -f "$HERMES_HOME/.hm-kernel-upgrade" 2>/dev/null || true
    # ---- 登出后常驻（systemd linger）----
    # systemd 的 **user** 服务默认在最后一个会话退出时被停掉：服务器上这意味着
    # SSH 一断 gateway 就停了、微信不再有回复，"24h 在线"不成立。
    # 上游只**检测并提示**（hermes_cli/doctor.py:_check_gateway_service_linger，建议
    # 手动 `sudo loginctl enable-linger $USER`），不代劳，所以这里补上。
    # 只用 `sudo -n`（免密）：需要密码时**故意不弹提示**——远程挂机安装会一直卡在
    # 密码输入上；那种情况改为打印一条明确的手动命令，完成提示里再列一次。
    LINGER_STATE=none
    if command -v loginctl >/dev/null 2>&1; then
        if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" = "yes" ]; then
            LINGER_STATE=on
            ok "systemd linger 已开启（登出后 gateway 继续运行）"
        elif sudo -n loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then
            LINGER_STATE=on
            ok "systemd linger 已开启（登出后 gateway 继续运行）"
        else
            LINGER_STATE=need
            warn "未能自动开启 systemd linger：**退出 SSH 后微信通道会停止**。"
            warn "  请手动执行一次：sudo loginctl enable-linger $(id -un)"
        fi
    fi
    # AGENTS.md 走 cwd 目录链：服务必须以 $HOME 为 WorkingDirectory
    # unit 文件在用户自己的 ~/.config 下——直接改写即可，用 sudo 反而会在无免密环境静默失败
    for unit in "$HOME/.config/systemd/user/"*hermes*.service; do
        [ -f "$unit" ] || continue
        if ! grep -q "^Environment=HERMES_LANGUAGE=" "$unit"; then
            echo "Environment=HERMES_LANGUAGE=zh" >> "$unit" 2>/dev/null || true
        fi
        if grep -q "^WorkingDirectory=" "$unit"; then
            sed -i "s|^WorkingDirectory=.*|WorkingDirectory=$HOME|" "$unit" \
                && ok "服务 WorkingDirectory 固定为 \$HOME（AGENTS.md 目录链单点）：$unit" \
                || warn "改写 WorkingDirectory 失败：$unit。AGENTS.md 可能不生效，请手动添加一行 WorkingDirectory=$HOME"
        else
            echo "WorkingDirectory=$HOME" >> "$unit" \
                && ok "服务 WorkingDirectory 固定为 \$HOME（AGENTS.md 目录链单点）：$unit" \
                || warn "写入 WorkingDirectory 失败：$unit。AGENTS.md 可能不生效，请手动添加一行 WorkingDirectory=$HOME"
        fi
        systemctl --user daemon-reload 2>/dev/null || true
    done
else
    warn "gateway 服务未安装成功，消息通道与定时任务暂不可用"
    if [ -s "$GW_LOG" ]; then
        tail -n 5 "$GW_LOG" | while IFS= read -r _l; do warn "  $_l"; done
    fi
    warn "可前台运行 hermes gateway run 查看日志定位问题；排除后重跑安装器"
fi

# ---------- 12. 脚本下线 ----------
# 设计（用户流程 2）：key 配置完成后 AI 上线，脚本下线。
# 微信接入 / 初次部署 / 能力演示全部由 AI 完成（#13）——AI 读 AGENTS.md 指针（内容在 docs）。

# ---------- 13. 完成提示 ----------
echo ""
log "HerMemory $HERMEMORY_VERSION 安装完成。使用说明见 docs/GUIDE.md。"
echo ""
echo "  注意事项"
echo "  1. AGENTS.md 可自由编辑。上游 Hermes 对其执行威胁扫描，含触发词的内容会被整体拦截。"
echo "     MEMORY.md 与 USER.md 逐条扫描，命中条目在对话中显示为 [BLOCKED]，文件本身保留。"
echo "  2. 自动化默认关闭。日记与总结需明确指令后写入；定时任务由对话建立并登记至 AUTOMATION.md。"
if [ "${LINGER_STATE:-}" = "need" ]; then
    echo "  3. 【待办】退出 SSH 后 gateway 会被 systemd 停掉，微信将不再回复。"
    echo "     执行一次即可：sudo loginctl enable-linger $(id -un)"
fi
echo ""
if [ "$WX_CONFIGURED" = "1" ]; then
    log "微信已接入。打开微信发送消息即可开始。"
else
    log "启动方式：命令行输入 hermes，按 docs/ONBOARDING.md 的指引完成剩余配置。"
fi
log "文档修改：编辑 $VAULT_DIR/HerMemory/memory/ 内文件，开启新对话后生效。"
log "文档：docs/INSTALL.md 部署｜docs/GUIDE.md 使用｜docs/LINUX.md 运维｜docs/COMMANDS.md 常用命令｜docs/ONBOARDING.md 部署手册"
