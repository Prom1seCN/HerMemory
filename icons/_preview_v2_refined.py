# 生成对比预览：修正版双菱渐变 × 暗/浅/透明(棋盘格) 三底，256px 单图 + 拼图
from PIL import Image, ImageDraw
import os

SRC = r"D:\Projects\HerMemory\icons\logo-candidates\2-亮色渐变-透明修正.png"
OUT_DIR = r"D:\Projects\HerMemory\icons\logo-candidates"
img = Image.open(SRC).convert("RGBA")

cell = 300
def make_cell(style):
    c = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
    if style == "light":
        c.paste(Image.new("RGBA", (cell, cell), (250, 251, 252, 255)), (0, 0))
    elif style == "dark":
        c.paste(Image.new("RGBA", (cell, cell), (20, 24, 29, 255)), (0, 0))
    else:  # checker = 模拟透明
        sq = cell // 10
        cc = Image.new("RGBA", (cell, cell), (255, 255, 255, 255))
        d = ImageDraw.Draw(cc)
        for y in range(10):
            for x in range(10):
                if (x + y) % 2:
                    d.rectangle([x*sq, y*sq, (x+1)*sq, (y+1)*sq], fill=(218, 224, 230, 255))
        c = cc
    c.alpha_composite(img.resize((cell, cell), Image.LANCZOS), (0, 0))
    return c

pad = 20
combo = Image.new("RGBA", (cell*3 + pad*4, cell + pad*2), (240, 242, 245, 255))
for i, style in enumerate(["dark", "light", "checker"]):
    combo.alpha_composite(make_cell(style), (pad + i*(cell+pad), pad))
combo_path = os.path.join(OUT_DIR, "2-修正版三底对比.png")
combo.save(combo_path)
print("saved:", combo_path)
