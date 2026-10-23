# 常用命令

HerMemory 的内核是 Hermes Agent。日常在微信里说话就够了，偶尔用几条命令能省事。
两组：**微信里直接发**（最常用）和**终端里用**（Linux / NAS，或 Windows 的高级用法）。

## 一、在微信里发

命令以 `/` 开头，单独一条发出去。

| 命令 | 作用 |
| --- | --- |
| `/new` | 开新对话：清空上下文，历史仍可查 |
| `/status` | 看当前模型、token 与上下文占用 |
| `/usage` | 看 token 用量与限流时间 |
| `/model` | 本次对话临时换模型 |
| `/undo` | 撤回上一轮，重新提问 |
| `/stop` | 停掉正在跑的后台任务 |
| `/compress` | 压缩上下文（对话变长、回复变慢时用） |
| `/restart` | 重启网关（不回消息、卡住时用） |
| `/memory` | 查看待写入的记忆、记忆写入确认开关 |
| `/personality` | 换一套说话的人格 |
| `/reasoning` | 调推理强度：更快，或更聪明 |
| `/help` | 列出全部可用命令 |
| `/version` | 查看内核版本 |

Windows 桌面程序里也有同一份列表：主界面 →「常用命令」，每条带一个「复制」按钮。

## 二、在终端里用（Linux / NAS）

| 命令 | 作用 |
| --- | --- |
| `hermes status` | 总览：内核、网关、模型 |
| `hermes gateway status` | 网关是否在跑 |
| `hermes gateway start` / `stop` / `restart` | 启动 / 停止 / 重启网关 |
| `hermes gateway run` | 前台跑网关，报错直接打在屏幕上（排障用） |
| `hermes doctor` | 体检：依赖、配置、路径 |
| `hermes config get model.default` | 看当前模型 |
| `hermes model` | 交互式换模型 |
| `hermes sessions list` | 最近的会话 |
| `hermes backup -o ~/hermes-backup.zip` | 官方全量备份 |
| `bash export.sh` | 一键导出（记忆库 + 全量备份 + 恢复指引） |

日志在 `~/.hermes/logs/`，实时看：`tail -f ~/.hermes/logs/*.log`。

> **不要执行 `hermes update`。** HerMemory 锁定内核版本（当前 v0.22.2，含发行版补丁），
> 直接更新会绕过这层锁定。升级请用 HerMemory 安装包（Windows）或重新运行 `install.sh`（Linux）。
