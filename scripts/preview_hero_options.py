#!/usr/bin/env python3
"""hero 图案选型预览 v2：Rich 真彩渲染（与终端 truecolor 同一解析路径）。
4 图案 × 2 色板 = 8 幅，每幅独立 Rich Console 渲染后 export_html 拼页。
不动 skins/hermemory.yaml。字符集：终端安全块字符，无 braille。
"""
import html
import io
import math
import pathlib

from rich.console import Console

# ---------------- 色板 ----------------
PALETTES = {
    "A · 青": {"light": "#67E8F9", "main": "#22D3EE", "deep": "#0EA5E9", "dim": "#0E7490", "text": "#CFFAFE"},
    "B · 紫": {"light": "#C4B5FD", "main": "#A78BFA", "deep": "#8B5CF6", "dim": "#6D28D9", "text": "#EDE9FE"},
}

def row_color(r, H, p):
    t = r / max(H - 1, 1)
    if t < 0.34: return p["light"]
    if t < 0.67: return p["main"]
    return p["deep"]

# ---------------- 图案 1：记忆水晶 ----------------
def gen_diamond():
    H, W, cy = 11, 21, 5
    rows = []
    for r in range(H):
        dy = abs(r - cy) / cy
        half = int(round((1 - dy) * (W // 2 - 1))) + 1
        core = "█" if dy < 0.25 else "▓" if dy < 0.5 else "▒" if dy < 0.75 else "░"
        gap = (W - (2 * half - 1)) // 2
        line = "░" * gap + core * (2 * half - 1) + "░" * gap
        if r == H // 2:
            mid = len(line) // 2
            line = line[:mid] + "●" + line[mid + 1:]
        if r in (2, H - 3):
            for pos in (len(line) // 2 - 3, len(line) // 2 + 3):
                if 0 <= pos < len(line) and line[pos] in "▓█":
                    line = line[:pos] + "░" + line[pos + 1:]
        rows.append(line)
    return rows

# ---------------- 图案 2：大脑 + 电路纹 ----------------
def gen_brain():
    H, W = 9, 27
    cy = 4.0
    gap_cols = {12, 13, 14}
    centers = [(5.5, 6.5), (21.5, 6.5)]
    a, b = 6.8, 4.3
    grid = [[" "] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if x in gap_cols:
                continue
            for (cx, _) in centers:
                d = math.hypot((x - cx) / a, (y - cy) / b)
                if d <= 1.0:
                    if d > 0.82: grid[y][x] = "█"
                    elif d > 0.55: grid[y][x] = "▓"
                    elif d > 0.3: grid[y][x] = "▒"
                    else: grid[y][x] = "░"
                elif d <= 1.12:
                    grid[y][x] = "▄" if y > cy else "▀"
    for y in range(1, H - 1):
        grid[y][13] = "│"
    grid[0][12] = grid[0][14] = "▄"
    for (x, y, ch) in [(4, 2, "·"), (8, 3, "✦"), (8, 6, "·"), (3, 5, "·"),
                       (22, 2, "·"), (18, 3, "✦"), (18, 6, "·"), (23, 5, "·")]:
        if grid[y][x] in "▒░":
            grid[y][x] = ch
    grid[H - 1][12] = grid[H - 1][14] = "▀"
    return ["".join(row).rstrip() for row in grid]

# ---------------- 图案 3：书页升起光点 ----------------
def gen_book():
    art = [
        "      ·        ·      ",
        "           ✦          ",
        "      ░        ░      ",
        " ▄▄▄▄▄▄▄▄█▄▄▄▄▄▄▄▄▄▄▄ ",
        "▐▓▓▓▓▓▓▓│▓▓▓▓▓▓▓▓▓▓▓▌",
        "▐▒▒░░▒▒▒│▒▒▒░░▒▒▒▒▒▌",
        "▐▓▓▓▓▓▓▓│▓▓▓▓▓▓▓▓▓▓▓▌",
        " ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀ ",
    ]
    return [ln for ln in art if ln.strip()]

# ---------------- 图案 4：月相时钟环 ----------------
def gen_moon():
    H, W = 11, 23
    cx, cy, R = 11.0, 5.0, 5.0
    grid = [[" "] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            d = math.hypot(x - cx, (y - cy) * 2.05)
            if abs(d - R) <= 0.55:
                grid[y][x] = "▓"
            elif d < R - 0.8:
                if x > cx + 0.6:
                    grid[y][x] = "▓" if x > cx + 2.5 else "▒"
                elif abs(x - cx) <= 1.2 and d < 2.6:
                    grid[y][x] = "░"
    for (x, y) in [(11, 0), (11, 10), (0, 5), (22, 5)]:
        grid[y][x] = "●"
    grid[2][11] = "✦"
    return ["".join(row).rstrip() for row in grid]

HEROES = [
    ("1 · 记忆水晶", gen_diamond()),
    ("2 · 大脑 + 电路纹", gen_brain()),
    ("3 · 书页升起光点", gen_book()),
    ("4 · 月相时钟环", gen_moon()),
]

TAG = "· Your memory ·"

def render_markup(rows, p):
    """按终端实际逻辑组装 Rich markup：行渐变着色 + 底部居中小字。"""
    out = []
    width = len(max(rows, key=len))
    for r, ln in enumerate(rows):
        color = row_color(r, len(rows), p)
        out.append(f"[{color}]{ln.center(width)}[/]")
    pad = max(width - len(TAG), 0)
    tag = " " * (pad // 2) + TAG + " " * (pad - pad // 2)
    out.append(f"[dim {p['dim']}]{tag}[/]")
    return "\n".join(out)

page = ['<html><head><meta charset="utf-8"><title>hero options — truecolor</title>',
        "<style>body{background:#0d1117;color:#c9d1d9;font-family:sans-serif;margin:24px}",
        "h2{font-size:15px;margin:32px 0 6px}h1{font-size:18px}",
        "p.note{font-size:12px;color:#8b949e}</style></head><body>",
        '<h1>banner_hero 图案选型 — Rich truecolor 真彩渲染（= SSH / Windows Terminal 实际效果）</h1>',
        '<p class="note">以下每幅经 Rich 引擎解析着色，与终端 truecolor 显示一致。'
        '老式 cmd（16 色）会有降色差；Windows Terminal / SSH 推荐。报组合如「2B」。</p>']

for name, rows in HEROES:
    for pal_name, pal in PALETTES.items():
        buf = io.StringIO()
        c = Console(file=buf, record=True, width=46, force_terminal=True, color_system="truecolor")
        c.print(render_markup(rows, pal))
        page.append(f"<h2>{html.escape(name)} × 色板 {html.escape(pal_name)}</h2>")
        page.append(c.export_html(inline_styles=True))

page.append("</body></html>")
out = pathlib.Path("skins/hero-options.html")
out.write_text("\n".join(page), encoding="utf-8")
print(f"已生成 {out}（8 幅 Rich truecolor 渲染）")
