#!/usr/bin/env bash
# make_offline_bundle.sh — 打上游 Hermes pin tag 本体包（供 install.sh 直链层/本地包层使用）
# 用法：bash make_offline_bundle.sh <tag> [上游clone路径]
#   默认上游路径 = $HOME/hermes-agent（install.sh 的默认安装位置）
# 产物：hermes-agent-bundle.zip（根级结构，无 .git；内含 HERMES_BUNDLE_TAG 版本戳）
# 发布：上传到自己的服务器静态目录，把直链填进 install.sh 的 OFFLINE_BUNDLE_URL
set -euo pipefail

TAG="${1:?用法: bash make_offline_bundle.sh <tag> [上游clone路径，默认 \$HOME/hermes-agent]}"
SRC="${2:-$HOME/hermes-agent}"

[ -d "$SRC/.git" ] || { echo "错误：$SRC 不是 git 仓库"; exit 1; }
git -C "$SRC" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
    echo "错误：$SRC 里没有 tag $TAG（先 git fetch --tags）"; exit 1; }
command -v zip >/dev/null || { echo "错误：需要 zip（sudo apt install zip）"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "导出 $TAG 工作树……"
git -C "$SRC" archive --format=tar "$TAG" | tar -x -C "$TMP"
echo "$TAG" > "$TMP/HERMES_BUNDLE_TAG"

echo "打包……"
(cd "$TMP" && zip -qr "$OLDPWD/hermes-agent-bundle.zip" .)

SIZE=$(du -h "hermes-agent-bundle.zip" | cut -f1)
echo "完成：hermes-agent-bundle.zip（$TAG，$SIZE）"
echo "上传到服务器静态目录后，把直链填进 install.sh 的 OFFLINE_BUNDLE_URL"
