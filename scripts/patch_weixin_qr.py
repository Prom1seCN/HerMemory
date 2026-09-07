# 内核 UX 补丁（幂等）：微信扫码改为"链接 + 复制到浏览器打开"，删除终端 ASCII 渲染逻辑
# 用法：python patch_weixin_qr.py <weixin.py 路径>
import sys

p = sys.argv[1]
t = open(p, encoding="utf-8").read()
if "终端二维码渲染失败" not in t:
    sys.exit(0)  # 已打补丁或版本不符，跳过

a = t.find("import qrcode")
assert a > 0, "anchor import qrcode not found"
try_start = t.rfind("        try:", 0, a)
assert try_start > 0, "anchor try not found"
hint = t.find("请直接打开上面的二维码链接")
assert hint > a, "anchor hint not found"
line_end = t.find("\n", hint)
block_end = line_end + 1
if t[block_end:block_end + 1] == "\n":
    block_end += 1  # 吞掉块后空行

new_block = '            print("（复制链接到浏览器打开）")\n\n'
t2 = t[:try_start] + new_block + t[block_end:]
open(p, "w", encoding="utf-8", newline="").write(t2)
print("[完成] 内核补丁：微信扫码改为复制链接到浏览器打开")
