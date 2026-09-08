# 基于定稿 logo（双菱·分距200）重画 banner_hero 候选：4 种风格 × 真 Rich 渲染预览
# 用法：uv run --with pillow --with rich --with pyyaml --default-index https://pypi.tuna.tsinghua.edu.cn/simple python _gen_hero_candidates.py
import io, math
from rich.console import Console
import pathlib

# —— logo 几何（1024 画布）：菱宽430 高610，中心距 200，即 cx 412/612，前菱在后菱右侧（叠区110px） ——
# 转为 hero 网格（21 列 × 13 行左右，参考旧 hero 的体量）。画布逻辑坐标 → 网格映射。
COLS, ROWS = 30, 19            # 网格逻辑尺寸（横向放宽，给两菱留出分离感）
CX_B, CX_F = 11.0, 17.0        # 后菱/前菱中心列（中心距 6 列 ≈ 200/430 缩比）
HALF_W, HALF_H = 5.6, 8.6      # 菱形半宽/半高（列/行）

# 主题色（与 logo/皮肤一致）
FRONT_TOP, FRONT_BOT = "#38BDF8", "#0891B2"
BACK_TOP,  BACK_BOT  = "#0EA5E9", "#164E63"
ACCENT, DEEP, ICE    = "#22D3EE", "#0E7490", "#CFFAFE"

def in_diamond(cx, cy, hx, hy, x, y):
    """点是否在菱形内（含边界，留 0.35 缓冲让笔画连续）"""
    return abs((x - cx) / hx) + abs((y - cy) / hy) <= 1.0

def grad_color(y, cy, hy, top, bot):
    """菱形内按 y 做垂直渐变（top 在上）"""
    t = (y - (cy - hy)) / (2 * hy)
    t = max(0.0, min(1.0, t))
    def hex2rgb(h): h = h.lstrip("#"); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
    def rgb2hex(r): return "#{:02X}{:02X}{:02X}".format(*r)
    a, b = hex2rgb(top), hex2rgb(bot)
    return rgb2hex(tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)))

def grad_hexes(c1, c2, n):
    def hex2rgb(h): h = h.lstrip("#"); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
    def rgb2hex(r): return "#{:02X}{:02X}{:02X}".format(*r)
    a, b = hex2rgb(c1), hex2rgb(c2)
    return [rgb2hex(tuple(round(a[i] + (b[i] - a[i]) * k / max(n - 1, 1)) for i in range(3))) for k in range(n)]

def render(filler):
    """filler(x, y, in_back, in_front, row) -> (char, color) 或 None（空白）"""
    lines = []
    for r in range(ROWS):
        y = r + 0.5
        segs = []
        for c in range(COLS):
            x = c + 0.5
            ib = in_diamond(CX_B, ROWS / 2, HALF_W, HALF_H, x, y)
            if_ = in_diamond(CX_F, ROWS / 2, HALF_W, HALF_H, x, y)
            got = filler(x, y, ib, if_, r)
            segs.append(got)
        # 合并同色段 → [color]text[/]
        line, cur, buf = "", None, ""
        for s in segs:
            if s is None:
                if buf:
                    line += f"[{cur}]{buf}[/]" if cur else buf
                    buf, cur = "", None
                line += " "
            else:
                ch, col = s
                if col != cur and buf:
                    line += f"[{cur}]{buf}[/]" if cur else buf
                    buf, cur = "", None
                if not buf and col:
                    cur = col
                buf += ch
        if buf:
            line += f"[{cur}]{buf}[/]" if cur else buf
        lines.append("  " + line.rstrip())
    return "\n".join(lines)

SLOGAN = "   · Your memory ·   "

# ---------- A：双菱实心渐变（logo 直接字符化：前菱亮渐变、后菱暗渐变，无光点） ----------
def hero_a(x, y, ib, if_, r):
    if if_: return ("█", grad_color(y, ROWS / 2, HALF_H, FRONT_TOP, FRONT_BOT))
    if ib: return ("▓", grad_color(y, ROWS / 2, HALF_H, BACK_TOP, BACK_BOT))
    return None

# ---------- B：A + 中心冰色光点（延续旧 hero 的 ✦ 基因，前菱中心） ----------
def hero_b(x, y, ib, if_, r):
    if if_:
        if abs(x - CX_F) + abs(y - ROWS / 2) <= 1.1: return ("✦", ICE)
        return ("█", grad_color(y, ROWS / 2, HALF_H, FRONT_TOP, FRONT_BOT))
    if ib: return ("▓", grad_color(y, ROWS / 2, HALF_H, BACK_TOP, BACK_BOT))
    return None

# ---------- C：细线框双菱（描边风，极简；前实线后细线，呼应 logo 的层次） ----------
def hero_c(x, y, ib, if_, r):
    # 边界判定：在菱形内且到边界距离 < 0.45
    def edge(cx, hx, hy):
        d = abs((x - cx) / hx) + abs((y - ROWS / 2) / hy)
        return d <= 1.0 and d >= 1.0 - 0.45
    if if_ and edge(CX_F, HALF_W, HALF_H): return ("▒", grad_color(y, ROWS / 2, HALF_H, FRONT_TOP, FRONT_BOT))
    if ib and not if_ and edge(CX_B, HALF_W, HALF_H): return ("░", DEEP)
    return None

# ---------- D：密度渐变（点阵风：字符密度随渐变变化，前菱 █▓▒ 立体感，后菱 ▓▒░） ----------
def hero_d(x, y, ib, if_, r):
    if if_:
        t = (y - (ROWS / 2 - HALF_H)) / (2 * HALF_H); t = max(0, min(1, t))
        ch = "█" if t < 0.33 else "▓" if t < 0.66 else "▒"
        return (ch, FRONT_TOP if t < 0.5 else FRONT_BOT)
    if ib:
        t = (y - (ROWS / 2 - HALF_H)) / (2 * HALF_H); t = max(0, min(1, t))
        ch = "▓" if t < 0.4 else "▒" if t < 0.75 else "░"
        return (ch, BACK_TOP if t < 0.5 else BACK_BOT)
    return None

heroes = {
    "A · 双菱实心渐变（logo 直接字符化）": hero_a,
    "B · A + 前菱中心冰色光点 ✦": hero_b,
    "C · 双菱细线框（描边极简）": hero_c,
    "D · 密度渐变（█▓▒░ 立体点阵）": hero_d,
}

out = []
out.append("# 候选 hero（基于定稿 logo 双菱·分距200）— Rich 真渲染，浏览器所见 = 终端实际")
out.append("")
for name, fn in heroes.items():
    body = render(fn)
    out.append(f"== {name} ==")
    out.append("[dim]（说明行）[/]")
    out.append(body)
    out.append(f"[{DEEP}]{SLOGAN}[/]")
    out.append("")

# Console 只写内存（file=StringIO）——不落真实控制台，GBK 终端炸不了 ✦
buf = io.StringIO()
page = Console(file=buf, record=True, width=80, force_terminal=True, color_system="truecolor", legacy_windows=False)
for chunk in out:
    page.print(chunk)
page.save_html(str(dst)) if False else None

dst = pathlib.Path(r"D:\Projects\HerMemory\icons\hero-candidates-preview.html")
dst.write_text(page.export_html(inline_styles=True), encoding="utf-8")
print("saved:", dst)