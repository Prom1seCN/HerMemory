# Logo 方案生成器：双菱叠影 × 主题色（1024px，跑完保留备查）
from PIL import Image, ImageDraw
import os

S = 1024                     # 画布
R = 224                      # 圆角半径（对齐参考样式）
OUT = r"D:\Projects\HerMemory\icons\logo-candidates"
os.makedirs(OUT, exist_ok=True)

# 主题色
ACCENT   = "#0891B2"   # 浅色主色
ACCENT_H = "#0EA5E9"   # 浅色 hover
DARK_ACC = "#22D3EE"   # 深色主色
DARK_H   = "#38BDF8"   # 深色 hover
DEEP     = "#0E7490"
DEEPER   = "#164E63"
ICE      = "#CFFAFE"
BG_DARK  = "#0d1117"
BG_LIGHT = "#FAFBFC"

def hx(c, a=None):
    c = c.lstrip("#")
    if a is None:
        return tuple(int(c[i:i+2], 16) for i in (0, 2, 4)) + (255,)
    return tuple(int(c[i:i+2], 16) for i in (0, 2, 4)) + (a,)

def canvas(bg):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S-1, S-1], radius=R, fill=hx(bg))
    return img, d

def diamond(cx, cy, w, h):
    return [(cx - w/2, cy), (cx, cy - h/2), (cx + w/2, cy), (cx, cy + h/2)]

def grad_layer(box, top, bottom):
    """垂直渐变图层"""
    x0, y0, x1, y1 = box
    g = Image.new("RGBA", (x1-x0, y1-y0), (0, 0, 0, 0))
    gd = ImageDraw.Draw(g)
    t, b = hx(top), hx(bottom)
    for y in range(g.height):
        k = y / max(g.height - 1, 1)
        gd.line([(0, y), (g.width, y)], fill=tuple(int(t[i]*(1-k)+b[i]*k) for i in range(3)) + (255,))
    return g

def make(name, fn):
    img = fn()
    img.save(os.path.join(OUT, name + ".png"))
    print("saved", name)

# 两菱几何（对齐参考：左右叠，前菱略大略右）
def geo():
    return dict(back=dict(cx=448, cy=512, w=430, h=610),
                front=dict(cx=576, cy=512, w=430, h=610))

# ---------- V1 基准色修（暗底·原样式复刻，色号对齐主题） ----------
def v1():
    img, d = canvas(BG_DARK)
    g = geo()
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.polygon(diamond(g["back"]["cx"], g["back"]["cy"], g["back"]["w"], g["back"]["h"]), fill=hx(DEEP, 215))
    img.alpha_composite(layer)
    ld = ImageDraw.Draw(layer)
    fp = diamond(g["front"]["cx"], g["front"]["cy"], g["front"]["w"], g["front"]["h"])
    ld.polygon(fp, fill=hx(DARK_ACC))
    ld.line(fp + [fp[0]], fill=hx(ICE), width=12, joint="curve")
    img.alpha_composite(layer)
    return img

# ---------- V2 亮色浅底（浅色模式同源） ----------
def v2():
    img, d = canvas(BG_LIGHT)
    g = geo()
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.polygon(diamond(g["back"]["cx"], g["back"]["cy"], g["back"]["w"], g["back"]["h"]), fill=hx(ACCENT, 225))
    img.alpha_composite(layer)
    # 前菱：浅 hover→主色 渐变
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    md.polygon(diamond(g["front"]["cx"], g["front"]["cy"], g["front"]["w"], g["front"]["h"]), fill=255)
    fg.paste(grad_layer([0, g["front"]["cy"]-g["front"]["h"]//2, S, g["front"]["cy"]+g["front"]["h"]//2], DARK_H, ACCENT), (0, g["front"]["cy"]-g["front"]["h"]//2), mask.crop((0, g["front"]["cy"]-g["front"]["h"]//2, S, g["front"]["cy"]+g["front"]["h"]//2)))
    img.alpha_composite(fg)
    oline = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(oline)
    fp = diamond(g["front"]["cx"], g["front"]["cy"], g["front"]["w"], g["front"]["h"])
    od.line(fp + [fp[0]], fill=hx(ICE), width=10, joint="curve")
    img.alpha_composite(oline)
    return img

# ---------- V3 渐变水晶（暗底·#67E8F9→#0891B2 渐变 + 冰色细描边） ----------
def v3():
    img, d = canvas(BG_DARK)
    g = geo()
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.polygon(diamond(g["back"]["cx"], g["back"]["cy"], g["back"]["w"], g["back"]["h"]), fill=hx(DEEPER))
    img.alpha_composite(layer)
    top, bot = g["front"]["cy"]-g["front"]["h"]//2, g["front"]["cy"]+g["front"]["h"]//2
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(diamond(g["front"]["cx"], g["front"]["cy"], g["front"]["w"], g["front"]["h"]), fill=255)
    fg.paste(grad_layer([0, top, S, bot], "#67E8F9", ACCENT), (0, top), mask.crop((0, top, S, bot)))
    img.alpha_composite(fg)
    oline = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(oline)
    fp = diamond(g["front"]["cx"], g["front"]["cy"], g["front"]["w"], g["front"]["h"])
    od.line(fp + [fp[0]], fill=hx(ICE, 120), width=6, joint="curve")
    img.alpha_composite(oline)
    return img

# ---------- V4 双描边线稿（极简，交叠透色） ----------
def v4():
    img, d = canvas(BG_DARK)
    g = geo()
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    bp = diamond(g["back"]["cx"], g["back"]["cy"], g["back"]["w"], g["back"]["h"])
    ld.polygon(bp, fill=hx(DARK_ACC, 36))          # 交叠透色底
    ld.line(bp + [bp[0]], fill=hx(ACCENT_H), width=16, joint="curve")
    img.alpha_composite(layer)
    ld = ImageDraw.Draw(layer)
    fp = diamond(g["front"]["cx"], g["front"]["cy"], g["front"]["w"], g["front"]["h"])
    ld.polygon(fp, fill=hx(BG_DARK, 160))          # 前菱半透底，让交叠区可辨
    ld.line(fp + [fp[0]], fill=hx(DARK_ACC), width=16, joint="curve")
    img.alpha_composite(layer)
    return img

# ---------- V5 光点水晶（V3 + banner ✦ 呼应） ----------
def star(cx, cy, r):
    pts = []
    import math
    for i in range(8):
        ang = math.pi/2 * (i/2) - math.pi/2 if False else (math.pi/2)*(i % 2)*0  # placeholder
    # 四角星：外 r 内 r*0.28，8 点
    pts = []
    for i in range(8):
        ang = -math.pi/2 + i * math.pi/4
        rr = r if i % 2 == 0 else r * 0.26
        pts.append((cx + rr*math.cos(ang), cy + rr*math.sin(ang)))
    return pts

def v5():
    img = v3()
    d = ImageDraw.Draw(img)
    d.polygon(star(576, 500, 88), fill=hx(ICE))
    return img

# ---------- V6 错位镂空（上下错位叠 + 前菱镂空） ----------
def v6():
    img, d = canvas(BG_DARK)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    back = diamond(512, 436, 430, 610)
    ld.polygon(back, fill=hx(ACCENT_H, 150))
    img.alpha_composite(layer)
    ld = ImageDraw.Draw(layer)
    fp = diamond(512, 588, 430, 610)
    ld.polygon(fp, fill=hx(ACCENT))
    ld.polygon(diamond(512, 588, 190, 270), fill=hx(BG_DARK))   # 镂空小菱
    img.alpha_composite(layer)
    return img

make("1-基准色修-暗底", v1)
make("2-亮色浅底", v2)
make("3-渐变水晶-暗底", v3)
make("4-双描边线稿", v4)
make("5-光点水晶", v5)
make("6-错位镂空", v6)
print("done ->", OUT)
