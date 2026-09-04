#!/usr/bin/env python3
"""本地预览 HerMemory 皮肤横幅——不碰服务器。

用法：
    python scripts/preview_banner.py [skins/hermemory.yaml]

效果：以 80 列终端宽度渲染 banner_logo 与 banner_hero（Rich 着色），
生成 banner-preview.html 并在浏览器打开。改完皮肤跑一次即可看效果。

依赖：pip install rich pyyaml
"""
import io
import pathlib
import sys
import webbrowser

import yaml
from rich.console import Console

skin = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "skins/hermemory.yaml")
if not skin.exists():
    sys.exit(f"皮肤文件不存在: {skin}")

d = yaml.safe_load(io.open(skin, encoding="utf-8").read())

console = Console(record=True, width=80, force_terminal=True, color_system="truecolor")
console.print(d.get("banner_logo", ""))
console.print()
console.print(d.get("banner_hero", ""))
console.print()
b = d.get("branding", {})
console.print(f"[bold]{b.get('agent_name', '')}[/]  |  welcome: {b.get('welcome', '')}")
console.print(f"goodbye: {b.get('goodbye', '')}  |  label: {b.get('response_label', '')}")

out = skin.parent / "banner-preview.html"
out.write_text(console.export_html(), encoding="utf-8")
webbrowser.open(out.resolve().as_uri())
print(f"预览已生成: {out}")
