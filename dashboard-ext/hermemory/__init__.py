"""HerMemory 插件入口。

真正的界面与接口在 ``dashboard/`` 下（manifest.json + dist/index.js + plugin_api.py）。
这里留一个空的 register，让插件能被 `hermes plugins enable/disable` 正常管理——
dashboard 的后端路由只对 enabled 的用户插件挂载。
"""


def register(ctx):  # noqa: ARG001 - 上游插件协议要求
    return None
