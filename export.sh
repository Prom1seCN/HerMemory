#!/usr/bin/env bash
# ============================================================
# export.sh — HerMemory 一键全量导出
# 对应设计核心功能之二（备份）与核心功能之三（自主）第 3 条。
# 纯 bash + hermes 官方 CLI——AI 瘫痪也能导出全部内容。
#
# 包内结构：
#   vault/               文档库：四核心文件（HerMemory/memory/）+ 全部用户文档
#   hermes-home.zip      hermes backup 官方全量：state.db 一致性副本（sqlite
#                        backup API）+ 所有 skill + 配置 + cron + 皮肤
#   README_REBORN.md     恢复指引（docs/ 有则随包，供下一个 agent 读）
#
# 输出：服务器 = 生成临时下载链接；PC / 本地 = 存到本地文件夹。
# 用法：bash export.sh [-o 输出目录]
# ============================================================
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
EXPORT_NAME="hermemory-export-$TS"
STAGE="$(mktemp -d)/$EXPORT_NAME"
OUT_DIR=""

while getopts "o:" opt; do
    case "$opt" in o) OUT_DIR="$OPTARG" ;; *) exit 1 ;; esac
done

log()  { printf '\033[36m[HerMemory]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[完成]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

command -v hermes >/dev/null || die "hermes CLI 不可用（~/.local/bin 不在 PATH？）——但导出 vault 部分不依赖它，见文末手动路径"
command -v zip >/dev/null || die "zip 命令缺失（第 4 步合包需要，最小化镜像常见）：Debian/Ubuntu 执行 apt install zip，Alpine 执行 apk add zip；Windows 侧请改用 HerMemory.exe 主界面的一键导出"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 0. vault 位置 ----------
read -rp "vault（同步根）路径 [默认 ~/vault]: " VAULT_DIR
VAULT_DIR="${VAULT_DIR:-$HOME/vault}"
[ -d "$VAULT_DIR" ] || die "vault 不存在：$VAULT_DIR"

# ---------- 1. vault：四核心 + 用户文档 ----------
mkdir -p "$STAGE"
log "打包文档库（四核心 + 用户文档）..."
tar -C "$VAULT_DIR" -cf - . | tar -C "$STAGE" -xf - --one-top-level=vault \
    2>/dev/null || { mkdir -p "$STAGE/vault"; cp -R "$VAULT_DIR/." "$STAGE/vault/"; }
[ -f "$STAGE/vault/HerMemory/memory/MEMORY.md" ] \
    || warn "vault/HerMemory/memory/MEMORY.md 不在包内——软链断了还是 vault 位置变了？请检查"
ok "文档库已入包"

# ---------- 2. hermes backup：官方全量（DB 一致性副本 + skills + 配置） ----------
log "hermes backup 官方全量打包（数据库用 sqlite backup API 生成一致性副本，热备不锁库）..."
hermes backup -o "$STAGE/hermes-home.zip"
[ -f "$STAGE/hermes-home.zip" ] && ok "agent 端全量已入包（skills / 配置 / 数据库 / cron）" \
    || die "hermes backup 未产出 zip——见上方输出"

# ---------- 3. README_REBORN（平时在 docs，打包时随行） ----------
if [ -f "$SRC/docs/README_REBORN.md" ]; then
    cp "$SRC/docs/README_REBORN.md" "$STAGE/"
    ok "README_REBORN.md 已随包"
else
    warn "docs/README_REBORN.md 尚未编写——恢复指引暂缺，不影响数据完整性"
fi

# ---------- 4. 合包 ----------
FINAL="$EXPORT_NAME.zip"
(cd "$(dirname "$STAGE")" && zip -qr "$FINAL" "$EXPORT_NAME")
FINAL_PATH="$(dirname "$STAGE")/$FINAL"
ok "导出包完成：$FINAL_PATH"

# ---------- 5. 输出：服务器生成下载链接，PC 存本地文件夹 ----------
IS_SERVER=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    IS_SERVER=1
fi

if [ "$IS_SERVER" = "1" ] && [ -z "$OUT_DIR" ] && command -v python3 >/dev/null 2>&1; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    PORT=$(( RANDOM % 2000 + 8100 ))
    log "服务器模式：启动临时下载服务（Ctrl+C 即关闭）"
    warn "链接无鉴权，仅限临时使用，取完即关"
    echo ""
    echo "    下载链接:  http://${SERVER_IP:-<服务器IP>}:$PORT/$FINAL"
    echo ""
    trap 'kill $HTTP_PID 2>/dev/null' EXIT
    python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$(dirname "$FINAL_PATH")" &
    HTTP_PID=$!
    wait "$HTTP_PID"
elif [ "$IS_SERVER" = "1" ] && [ -z "$OUT_DIR" ]; then
    warn "python3 不可用，无法起临时下载服务——导出包已生成，请自行取走（scp / sftp）："
    ok "$FINAL_PATH"
else
    # PC / 本地：存本地文件夹
    DEST="${OUT_DIR:-$HOME/Desktop}"
    [ -d "$DEST" ] || { DEST="${OUT_DIR:-$(pwd)}"; }
    mkdir -p "$DEST"
    mv "$FINAL_PATH" "$DEST/"
    ok "已保存到本地：$DEST/$FINAL"
fi

# ---------- 手动路径（hermes CLI 都不可用时） ----------
cat <<'EOF'

[HerMemory] 手动导出路径（应急）：vault 目录整体拷贝即是记忆本体；
agent 端（skills/配置/数据库）在 ~/.hermes/，停服后整体拷贝。

EOF
