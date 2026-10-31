#!/usr/bin/env python3
"""Localize Hermes' free-form activity descriptions to Chinese.

Hermes' static UI strings live in ``locales/zh.yaml`` (fully translated), but the
"what is the agent doing right now" descriptions are hardcoded English literals
passed to ``_touch_activity()`` -- e.g. ``receiving stream response``. They leak
straight into the WeChat/terminal status lines:

    ⏳ Working — 3 min — iteration 13/150, receiving stream response

Every description (live and persisted) passes through
``agent/session_activity.py::bound_activity_description()``, so that is the one
place to translate. Anything unrecognised is returned untouched, and nothing
happens unless the active language is Chinese.

Usage: patch_i18n_zh.py <checkout-dir>
"""
import pathlib
import sys

MARK = "HERMEMORY_I18N_ZH"

HELPER = '''# HERMEMORY_I18N_ZH: 活动描述是硬编码英文（"receiving stream response" 等），会漏进
# 微信/终端的状态行。在唯一入口 bound_activity_description() 做本地化；非中文语言原样返回。
_HM_ZH_EXACT = {
    "receiving stream response": "正在接收流式回复",
    "model reading the prompt": "模型正在读取提示词",
    "waiting for provider response (streaming)": "等待模型响应（流式）",
    "waiting for non-streaming API response": "等待模型响应",
    "local model loading": "本地模型加载中",
    "starting new turn": "开始新一轮",
    "starting new turn (cached)": "开始新一轮（缓存）",
}

_HM_ZH_RULES = (
    (r"^waiting for stream response \\((\\d+)s, (.+)\\)$", r"等待流式响应（\\1 秒，\\2）"),
    (r"^waiting for provider response \\((\\d+)s, (.+)\\)$", r"等待模型响应（\\1 秒，\\2）"),
    (r"^starting API call #(\\d+)$", r"开始第 \\1 次 API 调用"),
    (r"^tool results posted, continuing iteration #(\\d+)$", r"工具结果已提交，继续第 \\1 轮"),
    (r"^tool completed: (\\S+) \\(([\\d.]+)s\\)(.*)$", r"工具完成：\\1（\\2 秒）\\3"),
    (r"^sequential tool running \\((\\d+)s\\): (.+)$", r"正在运行工具（\\1 秒）：\\2"),
    (r"^stream retry (\\d+)/(\\d+) after (.+)$", r"流式重试 \\1/\\2（\\3）"),
    (r"^stale stream detected after (\\d+)s, reconnecting$", r"检测到流式停滞（\\1 秒），正在重连"),
    (r"^stale non-streaming call killed after (\\d+)s$", r"非流式调用停滞（\\1 秒），已中断"),
    (r"^resumed after the computer slept for (\\d+)s$", r"电脑休眠 \\1 秒后恢复"),
)


def _hm_zh_activity(text: str) -> str:
    try:
        from agent.i18n import get_language
        if not str(get_language() or "").lower().startswith("zh"):
            return text
    except Exception:
        return text
    exact = _HM_ZH_EXACT.get(text)
    if exact:
        return exact
    import re as _re
    for pattern, repl in _HM_ZH_RULES:
        if _re.match(pattern, text):
            return _re.sub(pattern, repl, text)
    return text


'''

ANCHOR_DEF = "def bound_activity_description(description: Optional[str]) -> str:"
OLD_BODY = '''    """Clamp free-form activity text to the shared description budget."""
    text = (description or "").strip()'''
NEW_BODY = '''    """Clamp free-form activity text to the shared description budget."""
    text = (description or "").strip()
    text = _hm_zh_activity(text)  # HERMEMORY_I18N_ZH'''


def patch(root: pathlib.Path):
    path = root / "agent" / "session_activity.py"
    if not path.is_file():
        return "skip: no agent/session_activity.py"
    src = path.read_text(encoding="utf-8")
    if MARK in src:
        return "already patched"
    if ANCHOR_DEF not in src or OLD_BODY not in src:
        return "skip: unexpected session_activity.py layout"
    src = src.replace(ANCHOR_DEF, HELPER + ANCHOR_DEF, 1)
    src = src.replace(OLD_BODY, NEW_BODY, 1)
    path.write_text(src, encoding="utf-8")
    return "patched"


RUN_TURN_OLD = '                        _status_detail = " — " + ", ".join(_parts)'
RUN_TURN_NEW = ('                        _status_detail = t("gateway.busy.ack_detail_wrap", '
                'detail=t("gateway.busy.ack_detail_joiner").join(_parts))')


def patch_run_turn(root: pathlib.Path):
    """心跳/忙碌状态行里 detail 的拼接符是硬编码的 " — " 与 ", "，中文下会露出 ASCII 逗号。

    换成目录里的 ack_detail_wrap / ack_detail_joiner（zh 为「（…，…）」），非中文语言
    保持原样——en 目录与硬编码值一致。
    """
    path = root / "gateway" / "run_turn.py"
    if not path.is_file():
        return "skip: no gateway/run_turn.py"
    src = path.read_text(encoding="utf-8")
    if RUN_TURN_NEW in src:
        return "already patched"
    if RUN_TURN_OLD not in src:
        return "skip: unexpected run_turn.py layout"
    path.write_text(src.replace(RUN_TURN_OLD, RUN_TURN_NEW, 1), encoding="utf-8")
    return "patched"


def main():
    if len(sys.argv) != 2:
        print("usage: patch_i18n_zh.py <checkout-dir>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1]).resolve()
    print("session_activity.py:", patch(root))
    print("run_turn.py:", patch_run_turn(root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
