# 女孩图标资产 v2：全透明底（窗口背景透出=与软件背景同色）+ 线稿反色 + 透明 logo 母版原位嵌入
# 用法：uv run --with pillow --default-index https://pypi.tuna.tsinghua.edu.cn/simple python _gen_girl_assets.py
from PIL import Image
import os

BASE = r"D:\Projects\HerMemory"
GIRL = os.path.join(BASE, "HerMemory_girl.png")                    # 原始：黑底白线稿 1254x1254
LOGO = os.path.join(BASE, r"icons\logo-candidates\2-修正-分距200.png")  # 定稿 logo：透明底 1024x1024
OUT = os.path.join(BASE, r"shell\assets")

# 用户在 HerMemory_girl_logo.png 里的嵌入位：菱形内容 bbox (504,484)-(880,844)，内容宽 376
# 我方 logo 内容 bbox 在 1024 画布内为 630 宽 → 缩放比 376/630 = 0.5968 → 画布 1024*0.5968 ≈ 611
# 粘贴点：使缩放后内容盒左上角落在 (504,484)
LOGO_SIZE = 611
LOGO_POS = (386, 359)

def lineart(bg_rgb):
    """线稿层：alpha = 原灰度亮度（黑底→透明），线条纯色按主题（深=白/浅=黑）"""
    gray = Image.open(GIRL).convert("L")
    layer = Image.new("RGBA", gray.size, bg_rgb + (0,))
    # putalpha：白色/黑色纯色层 + 亮度作 alpha → 黑背景完全透明，线条保真反锯齿
    layer.putalpha(gray)
    # 纯色化：RGB 统一为目标色（原图近灰阶，纯白/纯黑更干净）
    solid = Image.new("RGBA", gray.size, bg_rgb + (0,))
    r, g, b, a = layer.split()
    solid = Image.merge("RGBA", (Image.new("L", gray.size, bg_rgb[0]),
                                  Image.new("L", gray.size, bg_rgb[1]),
                                  Image.new("L", gray.size, bg_rgb[2]), a))
    return solid

def compose(line_rgb):
    img = lineart(line_rgb)
    logo = Image.open(LOGO).convert("RGBA").resize((LOGO_SIZE, LOGO_SIZE), Image.LANCZOS)
    img.alpha_composite(logo, LOGO_POS)   # 透明底 logo：只画菱形，无黑框
    return img

dark = compose((255, 255, 255))    # 深色主题：白线稿
light = compose((0, 0, 0))         # 浅色主题：黑线稿（logo 色不变）
dark.save(os.path.join(OUT, "girl-dark.png"))
light.save(os.path.join(OUT, "girl-light.png"))

# ---------- 像素级断言 ----------
def px(im, x, y): return im.load()[x, y]

for name, im, line_rgb in [("girl-dark", dark, (255,255,255)), ("girl-light", light, (0,0,0))]:
    p = px(im, 2, 2)
    assert p[3] == 0, f"{name} 角应全透明, got {p}"                       # 无底色方框
    # 线稿像素：找一处确定有线的点（原图灰度高处）
    gsrc = Image.open(GIRL).convert("L").load()
    hit = None
    for yy in range(0, 1254, 7):
        for xx in range(0, 1254, 7):
            if gsrc[xx, yy] > 200:
                hit = (xx, yy); break
        if hit: break
    assert hit, "原图找不到亮线像素"
    lp = px(im, hit[0], hit[1])
    assert lp[3] > 200 and (lp[0], lp[1], lp[2]) == line_rgb, f"{name} 线稿色错 {lp}"

# logo 两版同色（菱形中心）且非黑框
c1 = px(dark, 692, 664); c2 = px(light, 692, 664)
assert c1 == c2, f"logo 两版应同色 {c1} vs {c2}"
assert c1[2] > c1[0] and c1[3] == 255, f"logo 中心应为蓝青实色 {c1}"

# 浅色版 logo bbox 内「不透明近黑」占比 < 3%（黑框根除；残留只能是穿过 bbox 的线稿）
bl = light.load()
nb = tot = 0
for yy in range(484, 848, 2):
    for xx in range(504, 881, 2):
        tot += 1
        p = bl[xx, yy]
        if p[3] > 200 and p[0] < 60 and p[1] < 60 and p[2] < 60:
            nb += 1
ratio = nb / tot
assert ratio < 0.03, f"浅色版 logo 区黑像素占比 {ratio:.1%} 超标（黑框未根除）"

# 预览：两版分别叠在软件窗口底色上（深 #14181D / 浅 #FAFBFC），并排存图
pv = Image.new("RGBA", (1254*2 + 24, 1254), (240, 242, 245, 255))
for i, (im, bg) in enumerate([(dark, (20, 24, 29)), (light, (250, 251, 252))]):
    cell = Image.new("RGBA", (1254, 1254), bg + (255,))
    cell.alpha_composite(im)
    pv.alpha_composite(cell, (i * (1254 + 24), 0))
pv_small = pv.resize((1278, 639), Image.LANCZOS)
pv_small.save(os.path.join(BASE, "icons", "girl-theme-preview.png"))

print("saved: girl-dark.png / girl-light.png / girl-theme-preview.png")
print(f"断言全过：角色全透明、线稿 {'白/黑' if True else ''}、logo 两版同色 {c1}、浅色黑框占比 {ratio:.2%}")
