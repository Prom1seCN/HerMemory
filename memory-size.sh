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
    echo "MEMORY/USER容量设置"

    echo "提升容量会增强AI记忆力，但可能降低专注度，建议选择1-2档"

    echo "  1.紧凑：2200/1375 [默认]"
    echo "  2.标准：5000/3000"
    echo "  3.详细：10000/5000"

    read -rp "请选择记忆档位（1/2/3）: " CHOICE
    case "${CHOICE:-1}" in
        2) MEM_LIMIT=5000;  USER_LIMIT=3000  ;;
        3) MEM_LIMIT=10000; USER_LIMIT=5000  ;;
        *) MEM_LIMIT=2200;  USER_LIMIT=1375  ;;
    esac
fi

hermes config set memory.memory_char_limit "$MEM_LIMIT"
hermes config set memory.user_char_limit   "$USER_LIMIT"
echo "[完成] MEMORY $MEM_LIMIT / USER $USER_LIMIT 字符。开新对话生效。"
