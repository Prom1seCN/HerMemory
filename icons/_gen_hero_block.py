# 生成 yaml banner_hero 块文本，写入 hero_block.txt（供 Edit 粘贴）
COLS, ROWS = 30, 19
CX_B, CX_F = 11.0, 17.0
HALF_W, HALF_H = 5.6, 8.6

def in_d(cx, x, y):
    return abs((x - cx) / HALF_W) + abs((y - ROWS / 2) / HALF_H) <= 1.0

def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def rgb2hex(r):
    return "#{:02X}{:02X}{:02X}".format(*r)

def grad(y, top, bot):
    t = max(0.0, min(1.0, (y - (ROWS / 2 - HALF_H)) / (2 * HALF_H)))
    a, b = hex2rgb(top), hex2rgb(bot)
    return rgb2hex(tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)))

F_TOP, F_BOT, B_TOP, B_BOT = "#38BDF8", "#0891B2", "#0EA5E9", "#164E63"
lines = []
for r in range(ROWS):
    y = r + 0.5
    segs = []
    for c in range(COLS):
        x = c + 0.5
        if in_d(CX_F, x, y):
            segs.append(("█", grad(y, F_TOP, F_BOT)))
        elif in_d(CX_B, x, y):
            segs.append(("▓", grad(y, B_TOP, B_BOT)))
        else:
            segs.append(None)
    out, cur, buf = "", None, ""
    for s in segs:
        if s is None:
            if buf:
                out += "[%s]%s[/]" % (cur, buf) if cur else buf
                buf, cur = "", None
            out += " "
        else:
            ch, col = s
            if col != cur and buf:
                out += "[%s]%s[/]" % (cur, buf) if cur else buf
                buf, cur = "", None
            if not buf:
                cur = col
            buf += ch
    if buf:
        out += "[%s]%s[/]" % (cur, buf) if cur else buf
    lines.append("  " + out.rstrip())

slogan = "  [#0E7490]   · Your memory ·   [/]"
with open(r"D:\Projects\HerMemory\hero_block.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n" + slogan + "\n")
print("written")
