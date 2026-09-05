#!/usr/bin/env bash
# ============================================================
# HerMemory installer — v0.1.0
# 基于 Hermes Agent v0.21.0 (tag v2026.8.31)，MIT。
# 目标环境：headless Linux（Ubuntu 22/24、主流 NAS）。无 GUI。
# 状态：骨架——各步骤的逻辑待在干净机器上实测后填充（见 TODO）。
# ============================================================
set -euo pipefail

HERMEMORY_VERSION="0.1.0"
PINNED_HERMES_TAG="v2026.8.31"        # 上游 release tag（版本契约，改这里=换 pin）
PINNED_HERMES_VER="v0.21.0"
VAULT_DIR=""                          # 用户 vault 根（交互询问）
HERMES_DIR="$HOME/.hermes"

log()  { printf '\033[36m[hermemory]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 环境检查 ----------
[[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux（headless）。Windows/macOS 用户请见 docs/INSTALL.md 的手动路径。"
[[ $EUID -ne 0 ]] || die "不要用 root 跑安装器；用普通用户 + sudo。"
command -v python3 >/dev/null || die "未找到 python3（需 3.10+）。"

# ---------- 1. 询问 vault 位置 ----------
read -rp "文档库（vault）根目录路径 [默认 ~/HerMemory-vault]: " VAULT_DIR
VAULT_DIR="${VAULT_DIR:-$HOME/HerMemory-vault}"
log "vault 目录：$VAULT_DIR"

# ---------- 2. 安装 Hermes Agent（pin 版本） ----------
# TODO(实测)：确认上游推荐安装方式（pipx / install 脚本 / 源码），并固定到 $PINNED_HERMES_TAG。
# API key 配置：完全沿用上游官方流程（hermes model / hermes setup 向导），不自研、不改造、不引导。
# 上游怎么配，HerMemory 就怎么配——发行版不碰 key 的配置体验。
log "TODO: 安装 Hermes Agent $PINNED_HERMES_VER（pin: $PINNED_HERMES_TAG）"

# ---------- 3. 出厂memory/技能落位 ----------
# TODO(实测)：拷贝 memory/ → "$VAULT_DIR/memory/"，skills 白名单 → "$VAULT_DIR/skills/"
#   注意：vault 目录若属 root（webdav 容器以 root 跑），需 sudo 并保持文件属主为当前用户（双端可读写）。
log "TODO: 出厂默认文件 → vault"

# ---------- 4. 符号链接（仅记忆层：~/.hermes/memories → 同步范围） ----------
# 官方注入槽位（agent/prompt_builder.py 已核，9/5）：
#   SOUL.md = 身份槽 slot#1（load_soul_md 读 HERMES_HOME/SOUL.md，自动注入，支持 profile 多实例）
#   AGENTS.md = context file 链（git root→cwd；systemd 设 WorkingDirectory=$HOME 即稳定单点）
#   落法：~/.hermes/AGENTS.md 软链 → 同步范围 memory/RULES.md（零代码走官方通道，RULES 缺口的解）
# TODO(实测)：记忆软链五件——SOUL.md（身份槽根目录）、memories/MEMORY.md、memories/USER.md、AGENTS.md（=RULES）、其余按需。
#   坑：目录软链必须 ln -sfn（缺 -n 会在目标里再套一层）。
log "TODO: 创建符号链接"

# ---------- 5. 品牌皮肤 ----------
# TODO(实测)：cp skins/hermemory.yaml → ~/.hermes/skins/ （官方皮肤机制，即装即用）
log "TODO: 安装皮肤"

# ---------- 6. 时区 ----------
# TODO(实测)：统一 Asia/Shanghai（Docker 与进程两个层面），否则时间优化会引入 bug。
log "TODO: 时区校验"

# ---------- 7. 首启引导提示 ----------
log "安装完成后：启动 agent，它会主动发起「采档案」对话（怎么称呼你 / 主要用途 / 说话方式）。"
log "HerMemory $HERMEMORY_VERSION 安装流程结束（骨架版——步骤 2-6 待实测填充）。"
