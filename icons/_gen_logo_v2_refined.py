# 方案二修正版：透明底 + 双菱各自渐变（后菱整体暗于前菱）+ 无描边
# 用法：uv run --with pillow python _gen_logo_v2_refined.py
from PIL import Image, ImageDraw
import os

S = 1024
OUT = r"D:\Projects\HerMemory\icons\logo-candidates"
os.makedirs(OUT, exist_ok=True)

# 主题色
FRONT_TOP = "#38BDF8"   # 前菱渐变顶（亮天蓝）
FRONT_BOT = "#0891B2"   # 前菱渐变底（主题青）
BACK_TOP  = "#0EA5E9"   # 后菱渐变顶（比前菱顶深一档）
BACK_BOT  = "#164E63"   # 后菱渐变底（比前菱底深一档）

def hx(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i+2], 16) for i in (0, 2, 4)) + (255,)

def diamond(cx, cy, w, h):
    return [(cx - w/2, cy), (cx, cy - h/2), (cx + w/2, cy), (cx, cy + h/2)]

def grad_layer(w, h, top, bottom):
    """垂直渐变图层（尺寸 w×h）"""
    g = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(g)
    t, b = hx(top), hx(bottom)
    for y in range(h):
        k = y / max(h - 1, 1)
        gd.line([(0, y), (w, y)], fill=tuple(int(t[i]*(1-k)+b[i]*k) for i in range(3)) + (255,))
    return g

def paste_grad(img, cx, cy, w, h, top, bottom):
    """把渐变按菱形 mask 贴进 img（层叠：后画的在前）"""
    left, top_y = int(cx - w/2), int(cy - h/2)
    gw, gh = int(w), int(h)
    grad = grad_layer(gw, gh, top, bottom)
    mask = Image.new("L", (gw, gh), 0)
    # mask 坐标系以菱形外接框为原点
    pts = [(x - left, y - top_y) for (x, y) in diamond(cx, cy, w, h)]
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    img.paste(grad, (left, top_y), mask)

# 几何与原方案一致：双菱左右叠，前菱略右
BACK  = dict(cx=448, cy=512, w=430, h=610)
FRONT = dict(cx=576, cy=512, w=430, h=610)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))   # 全透明底
paste_grad(img, BACK["cx"],  BACK["cy"],  BACK["w"],  BACK["h"],  BACK_TOP,  BACK_BOT)   # 后菱
paste_grad(img, FRONT["cx"], FRONT["cy"], FRONT["w"], FRONT["h"], FRONT_TOP, FRONT_BOT) # 前菱（最后画=在上层）

out_path = os.path.join(OUT, "2-亮色渐变-透明修正.png")
img.save(out_path)

# 自检：四角 alpha=0（真透明）；中心像素非透明
px = img.load()
corners = [px[0,0], px[1023,0], px[0,1023], px[1023,1023]]
assert all(p[3] == 0 for p in corners), "角不透明：" + repr(corners)
assert px[576, 512][3] == 255, "前菱中心不实"
assert px[300, 512][3] == 255, "后菱左翼不实"
print("saved:", out_path)
print("corners alpha=0 OK; front/back centers solid OK")
