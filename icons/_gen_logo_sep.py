# 方案二修正 · 分离距离五档：菱形本身不变（430×610），仅拉开水平中心距
# 用法：uv run --with pillow --default-index https://pypi.tuna.tsinghua.edu.cn/simple python _gen_logo_sep.py
from PIL import Image, ImageDraw
import os

S = 1024
OUT = r"D:\Projects\HerMemory\icons\logo-candidates"
os.makedirs(OUT, exist_ok=True)

FRONT_TOP = "#38BDF8"; FRONT_BOT = "#0891B2"   # 前菱渐变（亮）
BACK_TOP  = "#0EA5E9"; BACK_BOT  = "#164E63"   # 后菱渐变（整体暗于前菱）
W, H = 430, 610
CY = 512

def hx(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i+2], 16) for i in (0, 2, 4)) + (255,)

def diamond(cx, cy, w, h):
    return [(cx - w/2, cy), (cx, cy - h/2), (cx + w/2, cy), (cx, cy + h/2)]

def grad_layer(w, h, top, bottom):
    g = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(g)
    t, b = hx(top), hx(bottom)
    for y in range(h):
        k = y / max(h - 1, 1)
        gd.line([(0, y), (w, y)], fill=tuple(int(t[i]*(1-k)+b[i]*k) for i in range(3)) + (255,))
    return g

def paste_grad(img, cx, cy, w, h, top, bottom):
    left, top_y = int(cx - w/2), int(cy - h/2)
    grad = grad_layer(int(w), int(h), top, bottom)
    mask = Image.new("L", (int(w), int(h)), 0)
    pts = [(x - left, y - top_y) for (x, y) in diamond(cx, cy, w, h)]
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    img.paste(grad, (left, top_y), mask)

def build(d):
    """d = 两菱中心距；构图水平居中（中点 512）"""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    paste_grad(img, 512 - d/2, CY, W, H, BACK_TOP, BACK_BOT)
    paste_grad(img, 512 + d/2, CY, W, H, FRONT_TOP, FRONT_BOT)
    return img

DISTANCES = [200, 260, 320, 380, 430]
for d in DISTANCES:
    img = build(d)
    p = os.path.join(OUT, f"2-修正-分距{d}.png")
    img.save(p)
    # 自检：四角透明；两菱主体实色；d<430 时画布中点在叠区内
    px = img.load()
    assert all(px[x, y][3] == 0 for x, y in [(0, 0), (1023, 0), (0, 1023), (1023, 1023)]), f"d={d} 角不透明"
    assert px[552, 512][3] == 255, f"d={d} 前菱内部不实"
    assert px[472, 512][3] == 255, f"d={d} 后菱内部不实"
    if d < 430:
        assert px[512, 512][3] == 255, f"d={d} 中点应属叠区"
    print("saved d =", d)

# 五档总览条（棋盘底=透明），从左到右 200/260/320/380/430
cell, pad = 240, 14
strip = Image.new("RGBA", (cell*5 + pad*6, cell + pad*2), (240, 242, 245, 255))
sq = cell // 10
for i, d in enumerate(DISTANCES):
    cb = Image.new("RGBA", (cell, cell), (255, 255, 255, 255))
    cd = ImageDraw.Draw(cb)
    for yy in range(10):
        for xx in range(10):
            if (xx + yy) % 2:
                cd.rectangle([xx*sq, yy*sq, (xx+1)*sq, (yy+1)*sq], fill=(218, 224, 230, 255))
    cb.alpha_composite(build(d).resize((cell, cell), Image.LANCZOS))
    strip.alpha_composite(cb, (pad + i*(cell+pad), pad))
strip.save(os.path.join(OUT, "2-修正-分距五档总览.png"))
print("overview saved")
