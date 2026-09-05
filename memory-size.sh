#!/usr/bin/env bash
# memory-size.sh — 记忆容量档位调节（新手引导1：多档可选）
# 用法：bash memory-size.sh            交互选档
#       bash memory-size.sh 8000 5000  直接指定 MEMORY/USER 字符上限
# 原理：hermes config set memory.memory_char_limit / memory.user_char_limit
# 说明：上限只约束 agent 用记忆工具写入时的预算（超限会被要求先整合）；
#       文件内容注入对话不做截断。改完开新对话生效。
set -euo pipefail

command -v hermes >/dev/null || { echo "[错误] hermes CLI 不可用（~/.local/bin 不在 PATH？）" >&2; exit 1; }

if [ $# -ge 2 ]; then
    MEM_LIMIT="$1"; USER_LIMIT="$2"
else
    echo "记忆容量档位（MEMORY.md / USER.md 字符上限）："
    echo "  1) 紧凑  2200 / 1375  （上游默认，≈1300 token）"
    echo "  2) 标准  8000 / 5000  （≈4700 token，日常推荐）"
    echo "  3) 宽敞 20000 / 12000 （≈11700 token，重度使用）"
    echo "  4) 自定义"
    read -rp "档位 [2]: " CHOICE
    case "${CHOICE:-2}" in
        1) MEM_LIMIT=2200;  USER_LIMIT=1375  ;;
        3) MEM_LIMIT=20000; USER_LIMIT=12000 ;;
        4) read -rp "MEMORY.md 字符上限: " MEM_LIMIT
           read -rp "USER.md   字符上限: " USER_LIMIT ;;
        *) MEM_LIMIT=8000;  USER_LIMIT=5000  ;;
    esac
fi

hermes config set memory.memory_char_limit "$MEM_LIMIT"
hermes config set memory.user_char_limit   "$USER_LIMIT"
echo "[ok] MEMORY $MEM_LIMIT / USER $USER_LIMIT 字符。开新对话生效。"
