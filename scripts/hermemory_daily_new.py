#!/usr/bin/env python3
"""HerMemory 每日新对话：把此刻仍活着的网关会话标记为「用户主动重置」。

下一条消息到来时，网关就会为这个聊天开一个新会话——上下文归零，不会因为用户一直
不开口说 /new 而把历史越堆越长。

怎么触发：`hermes cron create "0 4 * * *" --script hermemory_daily_new.py --no-agent`
（--no-agent 表示不经过模型；本脚本也不打印任何内容，所以不会往微信里发消息）。
HerMemory 的「设置 → 每日新对话」就是替用户写这条 cron。

为什么不用上游的 session_reset 配置：v0.22 内核已不再读 `session_reset.*`
（见 hermes_cli/session_reset_retirement.py），定时轮换被移到了社区插件
`hermes-session-reset-policy`。这里直接调用内核自己的
`SessionDB.promote_to_session_reset()` —— 与 `/new` 走同一条路径，所以网关的
「过期路由复活」逻辑不会把这个重置又翻回去，也不需要装任何插件、不联网。

失败一律安静退出（返回 0）：这是个后台维护任务，坏掉也不该让 cron 报错刷屏。
"""
from __future__ import annotations

import os
import sqlite3
import sys
from pathlib import Path

RESET_REASON = "hermemory_daily_new"

# 这些来源是「进程内一次性的工作会话」，不是用户对话，不该被重置。
_NON_CONVERSATION_SOURCES = frozenset(
    {"cli", "cron", "kanban", "acp", "api_server", "subagent", "tool", "recovered"}
)


def _hermes_home() -> Path:
    env = (os.environ.get("HERMES_HOME") or "").strip()
    return Path(env).expanduser() if env else Path.home() / ".hermes"


def _active_conversation_ids(db_path: Path) -> list[str]:
    """活着的（未结束）网关会话 id。只读查询，用短超时避免和网关抢锁。"""
    ids: list[str] = []
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5.0)
    except sqlite3.Error:
        return ids
    try:
        rows = conn.execute(
            "SELECT id, source FROM sessions WHERE end_reason IS NULL"
        ).fetchall()
        for session_id, source in rows:
            if not session_id:
                continue
            if str(source or "").strip().lower() in _NON_CONVERSATION_SOURCES:
                continue
            ids.append(str(session_id))
    except sqlite3.Error:
        return []
    finally:
        try:
            conn.close()
        except sqlite3.Error:
            pass
    return ids


def main() -> int:
    home = _hermes_home()
    db_path = home / "state.db"
    if not db_path.is_file():
        return 0

    ids = _active_conversation_ids(db_path)
    if not ids:
        return 0  # 没有活会话：什么都不用做

    try:
        from hermes_state import SessionDB
    except Exception as exc:  # 不在内核环境里（例如被人手工拿系统 python 跑）
        print(f"[hermemory] 跳过：无法导入内核的 SessionDB（{exc}）", file=sys.stderr)
        return 0

    promoted = 0
    try:
        with SessionDB(db_path) as db:
            for session_id in ids:
                try:
                    if db.promote_to_session_reset(session_id, RESET_REASON):
                        promoted += 1
                except Exception as exc:
                    print(f"[hermemory] 会话 {session_id} 重置失败：{exc}", file=sys.stderr)
    except Exception as exc:
        print(f"[hermemory] 打开会话库失败：{exc}", file=sys.stderr)
        return 0

    # 只写到 stderr：cron 的 --no-agent 会把 stdout 原样投递给用户，这里不该发任何消息。
    if promoted:
        print(f"[hermemory] 每日新对话：已重置 {promoted} 个会话", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
