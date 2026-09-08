# hero 候选预览 v2：确定性网格布局——每个字符一个固定格子，跨设备渲染一致
# 用法：uv run --with rich --default-index https://pypi.tuna.tsinghua.edu.cn/simple python _gen_hero_preview2.py
import io, pathlib
from rich.console import Console

def hero_A_markup():
    """A 方案（双菱实心渐变）逐行 [(text, color), ...]"""
    COLS, ROWS = 30, 19
    CX_B, CX_F = 11.0, 17.0
    HALF_W, HALF_H = 5.6, 8.6

    def in_d(cx, x, y): return abs((x - cx) / HALF_W) + abs((y - ROWS / 2) / HALF_H) <= 1.0
    def hex2rgb(h): h = h.lstrip("#"); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
    def rgb2hex(r): return "#{:02X}{:02X}{:02X}".format(*r)
    def grad(y, top, bot):
        t = max(0.0, min(1.0, (y - (ROWS/2 - HALF_H)) / (2*HALF_H)))
        a, b = hex2rgb(top), hex2rgb(bot)
        return rgb2hex(tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)))

    F_TOP, F_BOT, B_TOP, B_BOT = "#38BDF8", "#0891B2", "#0EA5E9", "#164E63"
    rows = []
    for r in range(ROWS):
        y = r + 0.5
        segs = []
        for c in range(COLS):
            x = c + 0.5
            if in_d(CX_F, x, y): segs.append(("█", grad(y, F_TOP, F_BOT)))
            elif in_d(CX_B, x, y): segs.append(("▓", grad(y, B_TOP, B_BOT)))
            else: segs.append(None)
        # 同色合并
        out, cur, buf = "", None, ""
        for s in segs:
            if s is None:
                if buf: out += f"[{cur}]{buf}[/]" if cur else buf; buf, cur = "", None
                out += " "
            else:
                ch, col = s
                if col != cur and buf:
                    out += f"[{cur}]{buf}[/]" if cur else buf; buf, cur = "", None
                if not buf: cur = col
                buf += ch
        if buf: out += f"[{cur}]{buf}[/]" if cur else buf
        rows.append(out.rstrip())
    return rows

rows = hero_A_markup()
buf = io.StringIO()
c = Console(file=buf, record=True, width=80, force_terminal=True, color_system="truecolor", legacy_windows=False)
c.print("[bold]HerMemory banner_hero · 方案 A（定稿预览）[/]")
c.print("[dim]双菱渐变 · 分距200 · 与 exe 图标同构图[/]")
c.print()
for ln in rows: c.print(ln)
c.print("[#0E7490]   · Your memory ·   [/]")
html = c.export_html(inline_styles=True)

# 确定性网格改造：外层 .hero 每字符一格（等宽矩阵），任意设备渲染一致
inject = """
<style>
/* —— 一致性补丁：字符画按等宽网格渲染，跨设备所见相同 —— */
.term-hero { font-family: 'Cascadia Mono', 'Consolas', 'DejaVu Sans Mono', 'Courier New', monospace !important;
             font-size: 18px; line-height: 1.0 !important; letter-spacing: 0; font-variant-ligatures: none; }
.term-hero > div, .term-hero span { line-height: 1.0 !important; }
</style>
"""
html = html.replace("<head>", "<head>" + inject, 1)
# body 外包一层缩放容器，移动端可横向滚动而不是压扁
html = html.replace("<body>", '<body style="margin:24px;background:#0d1117">', 1)

dst = pathlib.Path(r"D:\Projects\HerMemory\icons\hero-A-preview.html")
dst.write_text(html, encoding="utf-8")
print("saved:", dst)
