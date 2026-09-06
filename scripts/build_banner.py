#!/usr/bin/env python3
"""把你自己设计的字符画文本，变成可直接粘贴进 yaml 的带色片段。

用法：
    python scripts/build_banner.py <字符画.txt> [--gradient "#7FD7FF:#0A5C9E"] [--solid cyan]

输入：一个 .txt 文件，内容是你设计的字符画（每行一行）。
输出：stdout 打印 yaml 片段（banner_logo: | ...），直接整段复制进
      skins/hermemory.yaml 替换原 banner_logo 块即可。
同时生成 banner-preview.html 并打开浏览器，改完即看。

颜色三选一：
    --solid cyan                 单色（rich 色名或 #RRGGBB）
    --gradient "#7FD7FF:#0A5C9E" 从上到下按行插值渐变（真颜色渐变，非密度纹理）
    （都不选）                    不加色，字符画原样

规则：整幅宽度 ≤80 列（脚本会检查并拒绝）；行尾避免反斜杠；YAML 用 | 块由本脚本生成，别手写。
"""
import argparse
import colorsys
import io
import pathlib
import subprocess
import sys
import webbrowser

p = argparse.ArgumentParser()
p.add_argument("txt", help="字符画文本文件")
p.add_argument("--gradient", help='"起始色:结束色"，如 #7FD7FF:#0A5C9E（按行渐变）')
p.add_argument("--solid", help="单色，rich 色名或 #RRGGBB，如 cyan")
args = p.parse_args()

lines = io.open(args.txt, encoding="utf-8").read().rstrip("\n").split("\n")
w = max(len(l) for l in lines)
if w > 80:
    sys.exit(f"拒绝：宽 {w} 列，超过 80。请在设计工具里缩小或换字体。")
if any(l.rstrip().endswith("\\") for l in lines):
    sys.exit("拒绝：有行以反斜杠结尾（YAML 块标量会吞掉它）。")

def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))

def rgb2hex(rgb):
    return "#{:02X}{:02X}{:02X}".format(*rgb)

# 着色
colored = []
non_empty = [i for i, l in enumerate(lines) if l.strip()]
if args.gradient:
    start, end = [hex2rgb(x) for x in args.gradient.split(":")]
    span = max(len(non_empty) - 1, 1)
    for i, line in enumerate(lines):
        if not line.strip():
            colored.append(line)
            continue
        t = non_empty.index(i) / span
        rgb = tuple(round(a + (b - a) * t) for a, b in zip(start, end))
        colored.append(f"[{rgb2hex(rgb)}]{line}[/]")
elif args.solid:
    colored = [f"[{args.solid}]{l}[/]" if l.strip() else l for l in lines]
else:
    colored = lines

block = "\n".join(f"  {l}" for l in colored)
snippet = f"banner_logo: |\n{block}\n"
print(snippet)

out = pathlib.Path("banner-preview.html")
html_lines = "\n".join(
    f'<div style="white-space:pre">{l.replace("&", "&amp;").replace("<", "&lt;")}</div>'
    for l in colored
)
page = (
    '<html><head><meta charset="utf-8"><title>banner preview</title>'
    "<style>body{background:#0d1117;color:#c9d1d9;font-family:Consolas,monospace;"
    "font-size:14px;margin:24px}div{line-height:1.15}</style></head><body>"
    + html_lines
    + "</body></html>"
)
out.write_text(page, encoding="utf-8")
webbrowser.open(out.resolve().as_uri())

# 顺手触发完整预览（含 branding），失败不影响
try:
    subprocess.run(
        [sys.executable, str(pathlib.Path(__file__).parent / "preview_banner.py")],
        capture_output=True,
    )
except Exception:
    pass
print(f"已生成 {out} — 宽 {w} 列，合格。把上面 yaml 片段粘进 skins/hermemory.yaml 替换 banner_logo 块。")
