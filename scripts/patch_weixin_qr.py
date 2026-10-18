# 内核 UX 补丁（幂等）：微信扫码只留链接，删掉终端 ASCII 二维码渲染。
#
# 为什么需要：HerMemory 的扫码页在图形界面里，「把二维码画成终端字符」对用户毫无用处，
# 反而会往 stdout 灌几十行方块字符，把真正的二维码链接（GUI 要解析的那一行）淹没。
#
# 上游结构：
#   v0.22.x  _print_qr() 里先 print(qrcode_url)，再 try: import qrcode ... print_ascii()
#   v0.21.0  同一段内联在 qr_login 的循环里
# 本脚本只删「渲染」这一段，绝不碰 URL 打印与其它逻辑。结构不匹配时安全退出（退出码 0），
# 宁可少打一个补丁，也不要把内核改坏。
#
# 用法：python patch_weixin_qr.py <weixin.py 路径>
import sys

MARKER = "[HerMemory] 终端 ASCII 二维码已由发行版移除"

# v0.22.x：_print_qr() 内的 try/except 块（缩进 4 空格）
BLOCK_022 = '''    try:
        import qrcode
        qr = qrcode.QRCode()
        qr.add_data(qrcode_url or qrcode_value)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
    except Exception as _qr_exc:
        if report_render_error:
            print(f"（终端二维码渲染失败: {_qr_exc}，请直接打开上面的二维码链接）")
'''

# v0.22.x 稍早的写法（没有 report_render_error 守卫）
BLOCK_022_B = '''    try:
        import qrcode
        qr = qrcode.QRCode()
        qr.add_data(qrcode_url or qrcode_value)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
    except Exception as _qr_exc:
        print(f"（终端二维码渲染失败: {_qr_exc}，请直接打开上面的二维码链接）")
'''

# v0.21.0：qr_login 循环内联写法。整块（含 try 行）一起换——只换块内 body 会留下
# 一个空 try，Python 直接 IndentationError，装完就打不开内核。
BLOCK_021 = '''        try:
            import qrcode

            qr = qrcode.QRCode()
            qr.add_data(qr_scan_data)
            qr.make(fit=True)
            qr.print_ascii(invert=True)
        except Exception as _qr_exc:
            print(f"（终端二维码渲染失败: {_qr_exc}，请直接打开上面的二维码链接）")
'''

# 每个版本块替换成注释后必须保持原缩进，否则整份文件语法坏掉。
REPLACEMENT_4 = (
    "    # " + MARKER + "：只打印链接，GUI 自己展示二维码/链接。\n"
    "    # 需要终端版二维码时用上游原始内核，或 `hermes gateway setup`。\n"
)
REPLACEMENT_8 = (
    "        # " + MARKER + "：只打印链接，GUI 自己展示二维码/链接。\n"
    "        # 需要终端版二维码时用上游原始内核，或 `hermes gateway setup`。\n"
)


def main() -> int:
    if len(sys.argv) != 2:
        print("用法：python patch_weixin_qr.py <weixin.py 路径>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        print("[跳过] 读不到内核文件：%s（%s）" % (path, exc), file=sys.stderr)
        return 0

    if MARKER in text:
        # 已打过：不重复改，保持幂等
        return 0

    for block, replacement in ((BLOCK_022, REPLACEMENT_4),
                               (BLOCK_022_B, REPLACEMENT_4),
                               (BLOCK_021, REPLACEMENT_8)):
        if block in text:
            text = text.replace(block, replacement, 1)
            break
    else:
        # 结构不认识（上游又改了，或版本比 pin 新）：什么都不做，明确说出来。
        # 注意这不影响扫码——二维码链接仍然会被打印，只是终端多一坨字符画。
        print("[跳过] 内核二维码渲染块结构与已知版本不符，未打补丁（不影响扫码）")
        return 0

    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print("[完成] 内核补丁：微信扫码只打印链接，已移除终端 ASCII 二维码")
    return 0


if __name__ == "__main__":
    sys.exit(main())
