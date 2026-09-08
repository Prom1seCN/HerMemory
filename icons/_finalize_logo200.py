# 200 定稿：黑底/白底/三底对比 + ico 五尺寸（256/64/48/32/16）+ 托盘形状 PNG（32/16，供 TrayService 运行时加载）
# 用法：uv run --with pillow --default-index https://pypi.tuna.tsinghua.edu.cn/simple python _finalize_logo200.py
from PIL import Image, ImageDraw
import os

S = 1024
ICONS = r"D:\Projects\HerMemory\icons"
CAND = os.path.join(ICONS, "logo-candidates")
SHELL = r"D:\Projects\HerMemory\shell"

SRC = os.path.join(CAND, "2-修正-分距200.png")
img = Image.open(SRC).convert("RGBA")

# ---------- 1. 黑底 / 白底 ----------
DARK, LIGHT = (13, 17, 23, 255), (250, 251, 252, 255)   # #0d1117 / #FAFBFC
def on_bg(bg):
    c = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    c.paste(Image.new("RGBA", (S, S), bg), (0, 0))
    c.alpha_composite(img)
    return c
on_bg(DARK).save(os.path.join(CAND, "2-最终-黑底.png"))
on_bg(LIGHT).save(os.path.join(CAND, "2-最终-白底.png"))

# ---------- 2. 三底对比（暗 / 浅 / 棋盘=透明） ----------
cell, pad = 340, 24
combo = Image.new("RGBA", (cell*3 + pad*4, cell + pad*2), (240, 242, 245, 255))
def cell_bg(style):
    if style == "dark":  return Image.new("RGBA", (cell, cell), DARK)
    if style == "light": return Image.new("RGBA", (cell, cell), LIGHT)
    sq = cell // 10
    c = Image.new("RGBA", (cell, cell), (255, 255, 255, 255))
    d = ImageDraw.Draw(c)
    for y in range(10):
        for x in range(10):
            if (x + y) % 2:
                d.rectangle([x*sq, y*sq, (x+1)*sq, (y+1)*sq], fill=(218, 224, 230, 255))
    return c
for i, style in enumerate(["dark", "light", "checker"]):
    c = cell_bg(style)
    c.alpha_composite(img.resize((cell, cell), Image.LANCZOS))
    combo.alpha_composite(c, (pad + i*(cell+pad), pad))
combo.save(os.path.join(CAND, "2-最终-三底对比.png"))

# ---------- 3. ico 五尺寸（256/64/48/32/16），逐档 LANCZOS 重采样 ----------
def resize_best(size):
    return img.resize((size, size), Image.LANCZOS)

ico_sizes = [256, 64, 48, 32, 16]
ico_path = os.path.join(SHELL, "app.ico")
imgs = {s: resize_best(s) for s in ico_sizes}
imgs[256].save(ico_path, format="ICO", sizes=[(s, s) for s in ico_sizes], append_images=[imgs[s] for s in ico_sizes[1:]])
print("ico saved:", ico_path)

# ---------- 4. 托盘图标：与 exe 图标完全同源（同一 PNG 直接降采样），仅分辨率不同 ----------
tray_dir = os.path.join(SHELL, "assets")
os.makedirs(tray_dir, exist_ok=True)
for size in (32, 16):
    resize_best(size).save(os.path.join(tray_dir, f"tray-{size}.png"))
print("tray pngs saved ->", tray_dir)

# ---------- 自检 ----------
from PIL import Image as I
chk = I.open(ico_path)
print("ico frames:", "(多帧)" if chk.format == "ICO" else "?")
black = I.open(os.path.join(CAND, "2-最终-黑底.png")).convert("RGBA")
white = I.open(os.path.join(CAND, "2-最终-白底.png")).convert("RGBA")
pb, pw = black.load(), white.load()
assert pb[3, 3] == DARK[:3] + (255,), "黑底角应为 #0d1117"
assert pw[3, 3] == LIGHT[:3] + (255,), "白底角应为 #FAFBFC"
assert pb[552, 512][3] == 255 and pw[552, 512][3] == 255
tray32 = I.open(os.path.join(tray_dir, "tray-32.png")).convert("RGBA")
tp = tray32.load()
assert tray32.size == (32, 32)
# 与主图同源核验：四角透明；前菱中心实色且为蓝青系（渐变中部，非单色剪影）
assert tp[0, 0][3] == 0 and tp[31, 31][3] == 0
r, g, b = tp[19, 16][:3]
assert tp[19, 16][3] == 255 and b > r and b > 100 and g > 120, ("前菱中心色", tp[19, 16])
print("all checks passed")
