#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""产出「最小随包素材」（2026-09-16 瘦身）。

背景：Setup.exe 曾达 861.6 MB，其中 92% 是离线素材。但其中绝大部分（PortableGit / Node /
Python 运行时 / PyPI 与 npm 依赖）国内都有可靠直连镜像，安装时现场取即可 —— 真正必须随包的
只有三件「国内没有可靠直连源」的东西：

    hermes-agent.zip   上游源码快照（GitHub）
    uv.exe             uv 官方 release 只在 GitHub
    rg.exe             ripgrep 官方 release 只在 GitHub

本脚本从 build/offline/assets-offline/（由 build-offline.ps1 产出的完整素材）派生这三件，
其中源码包**剔除 .git**（68.4 MB 的当前快照对象，锚定模式下用不到，改为安装时现造空仓库）。

产出：build/minimal/{hermes-agent.zip,uv.exe,rg.exe}

用法：python scripts/make-minimal-bundle.py
"""
import io
import os
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'build', 'offline', 'assets-offline')
OUT = os.path.join(ROOT, 'build', 'minimal')

MB = lambda n: n / 1024 / 1024


def main():
    if not os.path.isdir(SRC):
        print('找不到完整素材目录：%s' % SRC)
        print('请先运行 build-offline.ps1 产出完整素材，再执行本脚本。')
        return 1

    os.makedirs(OUT, exist_ok=True)

    # ---- 1. 直接搬运的小件 ----
    for name in ('uv.exe', 'rg.exe'):
        s = os.path.join(SRC, name)
        if not os.path.exists(s):
            print('缺少 %s（完整素材不完整，请重跑 build-offline.ps1）' % name)
            return 1
        shutil.copy2(s, os.path.join(OUT, name))
        print('  %-18s %7.1f MB  （复制）' % (name, MB(os.path.getsize(s))))

    # ---- 2. 源码快照：剔除 .git 后重打包 ----
    src_zip = os.path.join(SRC, 'hermes-agent.zip')
    if not os.path.exists(src_zip):
        print('缺少 hermes-agent.zip（完整素材不完整）')
        return 1

    dst_path = os.path.join(OUT, 'hermes-agent.zip')
    zin = zipfile.ZipFile(src_zip)
    kept = dropped = 0
    dropped_bytes = 0
    with zipfile.ZipFile(dst_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
        for info in zin.infolist():
            fn = info.filename
            if fn.startswith('./.git') or '/.git' in fn:
                dropped += 1
                dropped_bytes += info.compress_size
                continue
            if fn.endswith('/'):
                continue
            zi = zipfile.ZipInfo(fn, date_time=info.date_time)
            zi.external_attr = info.external_attr
            zi.compress_type = zipfile.ZIP_DEFLATED
            zout.writestr(zi, zin.read(fn))
            kept += 1
    zin.close()

    print('  %-18s %7.1f MB  （%d 个文件，剔除 .git %d 项 / %.1f MB）'
          % ('hermes-agent.zip', MB(os.path.getsize(dst_path)), kept, dropped, MB(dropped_bytes)))

    # ---- 3. 校验：快照必须含 pyproject.toml，且不含任何 .git ----
    z = zipfile.ZipFile(dst_path)
    names = z.namelist()
    has_pyproject = any(n.endswith('pyproject.toml') for n in names)
    has_git = any('/.git' in n or n.startswith('./.git') for n in names)
    z.close()
    if not has_pyproject:
        print('  [FAIL] 快照缺 pyproject.toml —— 上游安装会失败')
        return 1
    if has_git:
        print('  [FAIL] 快照仍含 .git')
        return 1
    print('  校验通过：含 pyproject.toml、无 .git')

    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    print('\n  build/minimal 合计 %.1f MB（内嵌进 Setup 前）' % MB(total))
    return 0


if __name__ == '__main__':
    sys.exit(main())
