# -*- coding: utf-8 -*-
"""HerMemory headless 微信二维码登录（exe 专用，发行版自研、零改上游）。

为什么不用 `hermes gateway setup`：其 curses 菜单在非 TTY stdin 下直接返回取消值
（hermes_cli/curses_ui.py _run_curses_menu 的 isatty 守卫——上游不读管道输入），
exe 无法管道答题自动化。本脚本直调上游 gateway.platforms.weixin.qr_login，
行为与向导 _setup_weixin 一致：登录成功写 accounts json（qr_login 内部）+
本脚本补齐 .env 的 WEIXIN_* 五键（DM 策略固定 allowlist=当前扫码用户）。

用法：python weixin_qr_login.py <hermes-agent-root> <hermes-home>
输出：stdout 裸行打印 https://liteapp.weixin.qq.com/... 二维码链接（刷新后重打）；
结束打 ##HM-QR## ok|fail（人读排障用）。
"""
import asyncio
import os
import sys
from pathlib import Path


def set_kv(env_path: Path, key: str, value: str) -> None:
    lines = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
    idx = next((i for i, l in enumerate(lines) if l.startswith(key + "=")), -1)
    if idx >= 0:
        lines[idx] = f"{key}={value}"
    else:
        lines.append(f"{key}={value}")
    env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: python weixin_qr_login.py <hermes-agent-root> <hermes-home>", flush=True)
        return 2
    root, home = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
    sys.path.insert(0, str(root))
    try:
        from gateway.platforms.weixin import check_weixin_requirements, qr_login
    except Exception as exc:
        print(f"##HM-QR## fail import: {exc}", flush=True)
        return 1
    if not check_weixin_requirements():
        print("##HM-QR## fail deps: 需要 aiohttp/cryptography（上游 venv 依赖不完整）", flush=True)
        return 1

    creds = asyncio.run(qr_login(str(home)))
    if not creds or not creds.get("account_id"):
        print("##HM-QR## fail（登录未完成或超时）", flush=True)
        return 1

    env = home / ".env"
    set_kv(env, "WEIXIN_ACCOUNT_ID", creds.get("account_id", ""))
    set_kv(env, "WEIXIN_TOKEN", creds.get("token", ""))
    if creds.get("base_url"):
        set_kv(env, "WEIXIN_BASE_URL", creds["base_url"])
    if not os.environ.get("WEIXIN_CDN_BASE_URL"):
        set_kv(env, "WEIXIN_CDN_BASE_URL", "https://novac2c.cdn.weixin.qq.com/c2c")
    # DM 策略 = allowlist 当前扫码用户（与 exe 应用户端兜底一致：首条消息不被拦）。
    # user_id 为空时不写 allowlist——空名单会把所有私聊拦掉，宁可留给 exe 兜底。
    uid = creds.get("user_id", "")
    if uid:
        set_kv(env, "WEIXIN_DM_POLICY", "allowlist")
        set_kv(env, "WEIXIN_ALLOW_ALL_USERS", "false")
        set_kv(env, "WEIXIN_ALLOWED_USERS", uid)
    else:
        print("##HM-QR## warn user_id 为空，未写 allowlist（由 exe 兜底）", flush=True)
    print("##HM-QR## ok account=%s user=%s" % (creds.get("account_id", ""), creds.get("user_id", "")), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
