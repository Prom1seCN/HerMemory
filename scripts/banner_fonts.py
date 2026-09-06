#!/usr/bin/env python3
"""浏览 pyfiglet 全部字体渲染指定文字的效果——挑字型用。

用法：
    python scripts/banner_fonts.py [文字，默认 HERMEMORY]

生成 banner-fonts.html（每字体一节）并在浏览器打开。
三级标注：
    ✓ 终端安全   纯 ASCII 或常见块字符（█▀▄░▒▓ 等），任何终端字体都能显示
    △ 扩展字符   含 Latin-1/Unicode 特殊字形——终端/浏览器字体缺字形时显示为乱码
    ✗ 超宽       >80 列，终端内会折行
排序：终端安全且宽度合格者在最前。
"""
import html as html_mod
import io
import pathlib
import string
import sys
import webbrowser

import pyfiglet

text = sys.argv[1] if len(sys.argv) > 1 else "HerMemory"

# 终端字体普遍有字形的字符集：可打印 ASCII + 常见 Unicode 块/线字符
SAFE = (
    set(string.printable)
    | set("█▀▄░▒▓▌▐■║═╔╗╚╝╠╣╦╩╦─│┌┐└┘┤┬├┴┼▼▲◄►○●◘◙")
)

def classify(art: str) -> str:
    lines = art.rstrip("\n").split("\n")
    w = max((len(l) for l in lines), default=0)
    if w > 80:
        return ("bad", f"✗ 超宽（{w} 列，终端内折行）")
    # 字体缺小写字形：pyfiglet 渲染出替换符/控制符/空输出——真乱码，直接剔除
    if "\ufffd" in art or any(ord(ch) < 32 and ch != "\n" for ch in art) or not art.strip():
        return ("bad2", "✗ 渲染异常（字体缺小写字形，输出乱码/空白）——混合大小写不可用")
    extended = {ch for ch in art if ord(ch) > 126 and ch not in SAFE}
    if extended:
        sample = "".join(sorted(extended))[:12]
        return ("warn", f"△ 扩展字符（终端可能乱码）：{html_mod.escape(sample)}")
    return ("ok", "✓ 终端安全")

fonts = sorted(set(pyfiglet.FigletFont.getFonts()))
buckets = {"ok": [], "warn": [], "bad": [], "bad2": []}
for f in fonts:
    try:
        art = pyfiglet.figlet_format(text, font=f, width=400)
        label = classify(art)
        buckets[label[0]].append(
            (f, label[1], html_mod.escape(art))
        )
    except Exception:
        continue

titles = {
    "ok": f"✓ 终端安全且 ≤80 列（{len(buckets['ok'])} 种）——从这里挑",
    "warn": f"△ 宽度合格但含扩展字符（{len(buckets['warn'])} 种）——浏览器可能正常，SSH 终端可能乱码",
    "bad": f"✗ 超过 80 列（{len(buckets['bad'])} 种）——不建议",
    "bad2": f"✗ 渲染异常（{len(buckets['bad2'])} 种）——字体缺小写字形，混合大小写直接乱码，不可用",
}
page = ['<html><head><meta charset="utf-8"><title>banner fonts</title>',
        "<style>body{background:#0d1117;color:#c9d1d9;font-family:Consolas,'DejaVu Sans Mono',"
        "'Courier New','Microsoft YaHei',monospace;"
        "margin:24px}pre{background:#161b22;padding:12px;border-radius:8px;"
        "overflow-x:auto;line-height:1.1;font-size:12px}h2{font-family:sans-serif;"
        "font-size:15px;margin:36px 0 8px}h1{font-family:sans-serif;font-size:18px}</style></head><body>",
        f'<h1>{html_mod.escape(text)} — pyfiglet 全字体预览</h1>']

for key in ("ok", "warn", "bad", "bad2"):
    page.append(f"<h2>{titles[key]}</h2>")
    for name, label, art in buckets[key]:
        if key == "bad2":
            # 字体输出本身含乱码字符（U+FFFD 等），不展示原画，防止污染页面
            body = f"<pre>（字体对混合大小写缺字形——输出乱码/空白，已省略）</pre>"
        else:
            body = f"<pre>{art}</pre>"
        page.append(f"<h2 style='font-size:13px;color:#8b949e'>{html_mod.escape(name)}</h2>{body}")

page.append("</body></html>")
out = pathlib.Path("banner-fonts.html")
out.write_text("\n".join(page), encoding="utf-8")
webbrowser.open(out.resolve().as_uri())
print(f"已生成 {out}：终端安全 {len(buckets['ok'])} / 扩展字符 {len(buckets['warn'])} / 超宽 {len(buckets['bad'])}")
