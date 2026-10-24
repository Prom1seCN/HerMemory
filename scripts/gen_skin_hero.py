#!/usr/bin/env python3
"""生成皮肤里的 banner_hero（双菱叠影，按真实 logo 的几何比例）。

用法：`python3 scripts/gen_skin_hero.py [总列宽]`，把输出整段替换
`skins/hermemory.yaml` 里 `banner_hero: |` 到 `tool_prefix:` 之间的内容。

几何取自 `icons/_gen_logo_v2_refined.py`：单个菱形 430×610，两菱中心距 128（重叠）。
终端字符约为 1:2（宽:高），所以列宽按 总宽/(2*行数) ≈ 0.9 来定——默认 26 列 × 15 行，
显示比例 0.87，接近真实图标的 558/610=0.915。旧版是 20 列，显示比例 0.67，所以偏瘦。
"""
import sys

H = 15
DW, DH, OFF = 430.0, 610.0, 128.0
TOTAL = int(sys.argv[1]) if len(sys.argv) > 1 else 26

def hex2rgb(h): h = h.lstrip('#'); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
def lerp(a, b, t): return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))
def rgb2hex(c): return '#%02X%02X%02X' % c

BACK_TOP, BACK_BOT = hex2rgb('#0F9DDD'), hex2rgb('#15566F')
FRONT_TOP, FRONT_BOT = hex2rgb('#34B9F1'), hex2rgb('#0C95B9')

s = TOTAL / (DW + OFF)
dw, off = DW * s, OFF * s
cx = TOTAL / 2.0
back_cx, front_cx = cx - off / 2, cx + off / 2

for i in range(H):
    y = (i + 0.5) / H
    hw = dw / 2 * (1 - abs(2 * y - 1))
    t = i / (H - 1)
    bc, fc = rgb2hex(lerp(BACK_TOP, BACK_BOT, t)), rgb2hex(lerp(FRONT_TOP, FRONT_BOT, t))
    row = ''
    for x in range(TOTAL):
        if abs((x + 0.5) - front_cx) <= hw: row += '█'
        elif abs((x + 0.5) - back_cx) <= hw: row += '▓'
        else: row += ' '
    row = row.rstrip()
    ib, ifr = row.find('▓'), row.find('█')
    lead = row[:ib] if ib >= 0 else row[:ifr]
    back = ''
    if ib >= 0:
        j = ib
        while j < len(row) and row[j] == '▓': j += 1
        back = row[ib:j]
    front = ''
    if ifr >= 0:
        j = ifr
        while j < len(row) and row[j] == '█': j += 1
        front = row[ifr:j]
    gap = row[row.find(back) + len(back):row.find(front)] if back and front else ''
    print('  ' + f'[{bc}]' + lead + back + '[/]' + gap + f'[{fc}]' + front + '[/]')
