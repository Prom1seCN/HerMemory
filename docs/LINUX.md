# Linux / NAS 运维

Linux 上没有桌面程序：装完就在终端和微信里用。这份文档把 Windows 主界面上每个按钮
对应的命令列出来，功能一一对应，没有阉割，只是没有图形界面。

## 一、安装、升级、重装

**系统依赖**（Ubuntu / Debian 系一行装齐）：

```bash
sudo apt install -y git curl ca-certificates \
  libxi6 libxtst6 libxkbcommon0 libxkbcommon-x11-0 libgl1 libegl1 libgbm1 libdrm2
```

后面那串图形库只有「电脑操作」（cua-driver）用得到；纯 server 也可以跳过它：
`HERMEMORY_SKIP_COMPUTER_USE=1 bash install.sh`（日后 `hermes pm install cua-driver` 补装）。

```bash
git clone https://github.com/Prom1seCN/HerMemory.git
cd HerMemory
bash install.sh          # 需要交互式终端；中途 Ctrl+C 可退出，重跑会从断点继续
```

内核默认钉上游 **v0.22.2**（用仓库里的 `hermes-agent.upstream-commit`），不会装成 main 最新版。

**升级**：进到同一个仓库目录，`git pull` 后重跑 `bash install.sh`。
已完成步骤自动跳过；内核版本不一致时会走升级分支，记忆与配置保留。

**换记忆库位置**：`HERMEMORY_VAULT_DIR=/srv/vault bash install.sh`（必须是绝对路径）。

装完终端里多一个等价命令 **`hermemory`**（`~/.local/bin/hermemory`，纯转发到 `hermes`）：
`hermemory --version`、`hermemory gateway status` 都可以，和 `hermes` 完全一样。

**无交互安装**（不想回答那几段问题）：

```bash
HERMEMORY_HEADLESS=1 bash install.sh
```

只装内核、记忆库、文档、皮肤与网关服务；记忆档位用默认值，AI 与微信之后自己配：
`hermes model`、`hermes gateway setup`。适合写进自动化脚本或在 `tmux` 里跑。

**卸载**：

```bash
hermes gateway stop
hermes uninstall            # 移除内核与运行数据
```

记忆库 `~/vault` 默认保留（那是资产，不是软件痕迹），确认不要了再 `rm -rf ~/vault`。
别名也一并删掉：`rm -f ~/.local/bin/hermemory`。
仓库目录直接删掉即可。

## 二、模型与 API Key

```bash
hermes model                                   # 交互式选服务商与模型
hermes config set model.base_url "https://api.deepseek.com/v1"
hermes config set model.api_key  "sk-..."
hermes config set model.default  "deepseek-chat"
hermes gateway restart                         # 改完重启网关才生效
```

Base URL 和 API Key 是什么、去哪申请，见 [GET-API-KEY.md](GET-API-KEY.md)。
常用服务商的地址：DeepSeek `https://api.deepseek.com/v1`、阿里云百炼
`https://dashscope.aliyuncs.com/compatible-mode/v1`、硅基流动 `https://api.siliconflow.cn/v1`、
Kimi `https://api.moonshot.cn/v1`、智谱 `https://open.bigmodel.cn/api/paas/v4`。

## 三、记忆

记忆就是文件，直接编辑即可：

```
~/vault/HerMemory/memory/USER.md        你告诉过它的事
~/vault/HerMemory/memory/MEMORY.md      它自己沉淀的长期记忆
~/vault/HerMemory/memory/SOUL.md        人格
~/vault/HerMemory/memory/AGENTS.md      必须遵守的规则
~/vault/HerMemory/memory/AUTOMATION.md  定时任务登记册
```

改档位（字符上限）：`bash memory-size.sh` 交互选，或 `bash memory-size.sh 5000 3000`。
改完开新对话生效。

## 四、每日新对话

安装器只放脚本、不建任务（自动化默认关闭）。要开：

```bash
hermes cron create "0 4 * * *" --script hermemory_daily_new.py --no-agent \
  --name "HerMemory 每日新对话" --deliver local
```

查看 / 暂停 / 删除：`hermes cron list`，再按列出的 id 执行 `hermes cron pause <id>` 或 `hermes cron delete <id>`。
作用是把到点仍活着的会话标成"用户主动重置"，下一条消息自动开新会话，上下文归零。

## 五、微信

```bash
hermes gateway setup        # 扫码绑定（按提示操作，二维码链接会打印出来）
```

一台机器同一时刻只能绑一个微信，最后扫码的生效。被顶掉后用同一条命令重新扫码即可。

解绑（谨慎，会断开微信通道，不影响记忆）：

```bash
hermes gateway stop
rm -rf ~/.hermes/weixin/accounts
sed -i '/^WEIXIN_/d' ~/.hermes/.env
hermes gateway start
```

## 六、网关与开机自启

```bash
hermes gateway status
hermes gateway start | stop | restart
hermes gateway run          # 前台运行，排障时看实时日志
```

注册为 systemd 用户服务并随登录启动：

```bash
hermes gateway install --start-now --start-on-login
sudo loginctl enable-linger "$USER"     # 不执行的话，退出登录后服务会被停掉
```

## 七、体检与日志

```bash
hermes doctor               # 依赖、配置、路径的逐项检查
hermes status               # 一屏总览
tail -f ~/.hermes/logs/*.log
```

## 八、备份与导出

```bash
bash export.sh              # 交互式问 vault 路径，产出 zip（记忆库 + 官方全量 + 恢复指引）
bash export.sh -o /srv/backup
```

官方全量备份：`hermes backup -o ~/hermes-backup.zip`。
恢复：`hermes import ~/hermes-backup.zip`（覆盖前先看 `docs/README_REBORN.md`）。

## 九、常用命令

微信里能发的斜杠命令、终端里的常用命令，都在 [COMMANDS.md](COMMANDS.md)。

## 十、出问题先看这三处

1. `hermes gateway status` —— 网关在不在跑。
2. `tail -n 100 ~/.hermes/logs/*.log` —— 最近报错。
3. `hermes doctor` —— 依赖和路径有没有坏。

**回复开头还是 `⚕ Hermes`？** 皮肤没加载。`hermes skin list` 里应该有一行 `hermemory`；
没有就说明 `~/.hermes/skins/hermemory.yaml` 缺顶层 `name: hermemory`（0.1.x 装的旧文件就是这样，
加载器会静默丢弃它）。用仓库里的 `skins/hermemory.yaml` 覆盖，再 `hermes skin use hermemory`，
回复标签就变成 `HerMemory`。安装器现在会自己核对这一步，未生效会直接告警。

装内核时的旧目录保留在 `~/.hermes/hermes-agent.pre-*`，确认新版可用后可删。
