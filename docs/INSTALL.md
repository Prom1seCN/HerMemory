# HerMemory 部署指南

HerMemory. Your memory.

安装包一次完成全部部署：Hermes 内核、记忆库、微信通道、网关服务。向导只负责**装**——选安装位置、装运行环境、落位程序；装完点「完成」启动程序，再在应用里完成「连接 AI → 绑定微信 → 发第一句话」三步配置。

## 准备条件

**Windows PC**

- Windows 10 / 11
- 只需要安装包 `Setup.exe` 一个文件，无需预装 git、Python、Node 等任何工具（内核源码与 uv 已内嵌）
- 首次运行 Windows 可能弹「Windows 已保护你的电脑」：点「更多信息」→「仍要运行」。安装包没有代码签名，这是 SmartScreen 的常规提示；个别杀软会把自解压的单文件 exe 误报，恢复并加入信任即可
- **默认走国内镜像**：PM 的下载顺序改成「国内镜像优先、hermes-assets 兜底」（sha256 校验不变）；git / CPython / Node 从 npmmirror 的二进制 CDN 取（实测 12.4 MB/s），PyPI 走清华、npm 走 npmmirror。**ffmpeg（161 MB）与 ripgrep 已内置在 `Setup.exe` 里**，安装时直接校验使用，不联网下载——ffmpeg 没有可用的国内镜像（npmmirror 只有版本不符的官方构建）。
- **安装过程中需要联网**：CPython 3.14 与 Node 从 npmmirror 的二进制 CDN 取，Python 依赖走清华 PyPI，Chromium（可选）走 npm/官方源；只有在国内源不可用时才回退 `hermes-assets.nousresearch.com`（约 100 KB/s）。连不上时会先做联网预检并直接报「无法联网」，不会装到一半才失败
- **Windows 沙盒里测试**：`.wsb` 必须写 `<Networking>Enable</Networking>`，否则沙盒无 TCP 出口。**宿主机开着 Clash / v2ray 等代理时沙盒会断网**：宿主把 `127.0.0.1:7897` 这类代理设置带进沙盒，但沙盒里没有代理进程，uv 会报 `tunnel error ... 10061`。测之前先关宿主代理（关掉后沙盒直连正常，实测可装完）
- 需要同意一次管理员授权（向导预检阶段弹出，用于创建符号链接与写入程序目录）。已开启开发者模式（设置 → 更新与安全 → 开发者选项）时不会因符号链接而请求提权
- 默认装到 `C:\Program Files\HerMemory`（几十 MB，程序本体），运行时与数据放在 `%LOCALAPPDATA%\hermes`，记忆库在 `%USERPROFILE%\vault`。三个位置都能在向导的「安装位置」页改，**仅首次安装可选**
- 磁盘占用随「浏览器与电脑操作」勾选变化：勾选约 3.5–4.5 GB，不勾约 2–2.5 GB。建议预留 6 GB。数据位置所在磁盘剩余不足 3 GB、或程序位置所在磁盘不足 1 GB 时，该位置会被拒绝并说明原因

**服务器 / NAS（Linux）**

- Ubuntu 22 / 24 或主流 NAS
- 普通用户账号（安装器拒绝以 root 运行）
- 已装 git 与 curl：`sudo apt install git curl`
- 需要能访问 GitHub（内核 clone，以及 uv / ffmpeg 两个制品；把 `hermes-agent.bundle` 放在仓库根可免 clone）。内核默认钉上游 v0.22.2（随仓库的 `hermes-agent.upstream-commit`）；PyPI、npm、Node、CPython 都走国内镜像，sha256 校验不变
- 图形库：默认会装「浏览器与电脑操作」里的 `cua-driver`，它依赖 X11/GL 一组库；headless 服务器要么先装依赖，要么跳过：
  `sudo apt install -y libxi6 libxtst6 libxkbcommon0 libxkbcommon-x11-0 libgl1 libegl1 libgbm1 libdrm2`
  或 `HERMEMORY_SKIP_COMPUTER_USE=1 bash install.sh`（之后可 `hermes pm install cua-driver` 补装）
- 安装过程中需要输入一次 sudo 密码

Base URL 与 Key 不必提前准备，安装流程会引导填写。HerMemory 不指定服务商：任何 OpenAI 兼容接口均可。

## 安装

**Windows PC**

双击 `Setup.exe`，向导共四页：环境预检 → 安装位置 → 安装 → 完成。安装过程不要求填 API Key，也不要求扫码——这些都在装完后的程序里做。

「安装位置」页可分别指定**程序安装位置**、**数据存储位置**与 **AI记忆位置**（默认 `%USERPROFILE%\vault`）。同一页还有两个勾选框：**开机自动启动**（默认勾）与**浏览器与电脑操作**（默认勾，约 500 MB：网页浏览能力与屏幕操作驱动）。取消后者可省下大部分体积，代价是这两类技能暂时不可用——之后随时能补装：`hermes pm install agent-browser cua-driver`。

**位置仅首次安装可选**——检测到已有安装时该页只读，需更换位置请先卸载再重装。安装页实时显示进度并支持中止；中断后重新运行，已完成步骤自动跳过。全程无命令行窗口。

安装完成后桌面与开始菜单会生成快捷方式，程序常驻系统托盘，日常操作在主界面完成。**你手上那个安装包就是唯一副本**——需要修复或重装时重新运行它即可。

**服务器 / NAS（Linux）**

```bash
git clone https://github.com/Prom1seCN/HerMemory.git
cd HerMemory
bash install.sh
```

同样支持中断续装。装完没有桌面程序：日常在微信里用，运维命令见 [LINUX.md](LINUX.md)。

不想走问答式的记忆档位 / AI / 扫码三段，可以无交互安装：
`HERMEMORY_HEADLESS=1 bash install.sh`（装完用 `hermes model`、`hermes gateway setup` 自己配）。

## 三种安装场景

| 你现在的状态 | 安装器会怎么做 | 你的数据 |
| --- | --- | --- |
| 从没装过 | 全新安装：落位内核 → 装运行环境 → 建记忆库 → 铺出厂文件 → 扫码 | 没有可丢的 |
| 已装旧版 HerMemory（0.1.0） | 识别版本不同 → 升级内核到 v0.22.2 → 重建网关任务 → 其余沿用 | 记忆库、记忆、API Key、微信绑定全部保留 |
| 已有自己的 Hermes（CLI/其他发行版） | **接管**：沿用同一个数据目录，升级内核，加上 HerMemory 的记忆库与皮肤 | 配置、会话、技能保留；改动前自动备份 `config.yaml` / `.env` |

两条硬规则：

- **不降级**。现有 Hermes 比本发行版锁定的内核还新时，安装会中止并说明（降级会动到正在用的内核与会话库结构，没有回滚保证）。
- **想并存而不是接管**：本发行版按单份安装设计。要并行两份，请先给新的一份设置独立的 `HERMES_HOME` 环境变量再启动安装包，否则向导会把已有安装当成本机唯一副本并锁定位置。注意同一个微信号同一时刻只能绑一台。

## 安装器做的事

| 步骤 | 动作 | 你需要做 |
| --- | --- | --- |
| 1 | 落位 Hermes 官方内核（锁定 v0.22.2，上游 d923a5e 的工作树）：从随包 git bundle 检出，零网络 | 等待 |
| 2 | 由上游 PM 装运行环境：Python 3.14、Node、工具二进制与 Python 依赖（全部按 `pm/lock.json` 的 sha256 校验） | 等待，需联网 |
| 3 | 建立记忆库 `~/vault`：普通文件夹，用户文档与 AI 记忆都在其中 | 无 |
| 4 | 铺出厂五文件：MEMORY / USER / SOUL / AGENTS / AUTOMATION。已存在的文件一律跳过，不覆盖 | 无 |
| 5 | 将使用文档（`docs/`）放入记忆库，供用户与 AI 共同读取 | 无 |
| 6 | 建立符号链接：AI 读写的就是记忆库中的那份文件 | 无 |
| 7 | 安装品牌皮肤、开启消息时间注入与中文界面（时区不改系统设置，只提示你确认） | 无 |
| 8 | 设置记忆档位 | Windows：装完在应用「记忆设置」改；Linux：安装脚本里选，之后 `bash memory-size.sh` |
| 9 | 配置 AI：验证地址 → 验证 Key → 从实时模型列表选定默认模型 | Windows：装完在应用「配置向导」完成；Linux：安装脚本里逐步询问 |
| 10 | 微信扫码接入（可跳过） | Windows：应用「配置向导 → 绑定微信」；Linux：安装脚本里的 `hermes gateway setup` |
| 11 | 注册网关服务：微信通道与定时任务依赖它；是否随登录自启由向导中的勾选项决定（默认开启） | 无 |
| 12 | 把程序本体释放到安装位置、生成桌面与开始菜单快捷方式、登记卸载入口 | 无 |

## 配置 AI

**Windows**：装完点「完成」启动 HerMemory，首次启动会进三步骤配置向导：连接 AI → 绑定微信 → 发第一句话。
也可以从「设置 → 配置向导」随时重进。

**Linux / NAS**：以上都在 `install.sh` 里逐步完成（终端问答：记忆档位 → Base URL → API Key → 扫码）。
装完想改，用 `hermes model` / `hermes config set`，详见 [LINUX.md](LINUX.md)。

填法与校验规则（两个平台一致）：

1. **Base URL**：服务商的 OpenAI 兼容地址，一般以 `/v1` 结尾。Base URL 右边的「常用预设」可以直接选 DeepSeek、阿里云百炼、硅基流动、Kimi、智谱、火山方舟、腾讯混元、百度千帆、讯飞星火、OpenRouter，地址自动填好
2. **API Key**：在同一控制台生成，明文粘贴便于核对
3. **默认模型**：应用实时拉取该地址的模型列表，从下拉里选择

三项均当场验证：地址不可达、Key 未通过、名下无可用模型，都会指明具体原因，可反复重试。粘贴带入的不可见字符会被自动清除。不知道 Key 是什么，点界面上的「什么是 API Key？」。

## 装完之后

**已接入微信**：打开微信向 AI 发送第一条消息。它会自我介绍，向你了解称呼、用途与表达偏好并写入 USER.md，随后按其部署手册（`docs/ONBOARDING.md`）带你认识记忆文件，并请你亲手改一次规则。

**未接入微信**：终端执行 `hermes`，开始同样的对话。

日常使用见 [GUIDE.md](GUIDE.md)。

## 从 0.1.0 升级

**Windows**：新版安装包会检测到已有安装，并把内核从 v0.21.0 升到 v0.22.2；vault、记忆、API Key、
微信绑定、深色/关闭行为等偏好都不动（配置在 `config.yaml` / `.env`，升级前会各留一份
`.pre-hermemory-<时间戳>` 备份）。判定依据是 `hermes --version` 的版本号，不是「文件在不在」——
否则旧内核跑得起来就会被误判成已装。

**Linux / NAS**：在同一个仓库目录 `git pull` 后重跑 `bash install.sh`，走同一条升级分支，
同样先备份 `config.yaml` / `.env`。

升级不需要重新填写：程序会直接沿用现有的 Base URL、Key、模型与记忆档位，装完照常使用。
升级期间旧网关会被停掉，装完自动拉起。

0.1.x 的旧配置把自定义端点写成 `OPENAI_BASE_URL` / `OPENAI_API_KEY`（v0.22 见到后者会把请求
劫持到 OpenRouter）。升级时会自动迁移：能读到模型名就改写成正规的 `model.*` 配置，读不到就
原样保留并提示你 `hermes model` 重新配置——不会在没有模型名的情况下删掉你的 Key。

**升级后第一次启动会自动重建网关任务**：内核换代后旧任务里的启动脚本指向已删除的旧 venv，
程序会检测到（或读到安装器留下的 `.hm-kernel-upgrade` 标记）→ 删旧任务 → 重新注册 → 拉起网关。
因此升级后即使不开程序，重启电脑也不会出现"AI 离线"；如果真遇到，主界面「体检 → 重装任务」一点即可。

升级时旧的内核目录会被整体改名为 `hermes-agent.pre-0.2.2-<时间戳>`（Windows 上无法在原地切分支：
仓库里有两个仅大小写不同的文件，git 会一直判定工作区是脏的）。新版从随包 bundle 干净克隆。
确认新版可用后，这个 `pre-` 目录连同旧版 `uv-python\`、`node\`、`git\` 都可以手动删掉（合计约 2 GB），不影响运行。

升级前建议先点一次「一键导出」做全量备份。**不要先卸载**——卸载会删掉 API Key 与微信凭据，
记忆库虽然保留，但需要重新配置。

## 卸载

**Windows**：从「设置 → 应用」或「控制面板 → 程序和功能」里卸载（列表项名为 `HerMemory`），也可从程序主界面「卸载」或托盘右键「卸载…」发起。移除内容：Hermes 内核与运行数据、微信接入凭据、网关计划任务与登录项、开机自启项、偏好设置、记忆历史快照（`%LOCALAPPDATA%\HerMemory\history`）、桌面与开始菜单快捷方式、程序目录。卸载会先停止网关，过程需要一次管理员授权。

**Linux / NAS**：

```bash
hermes gateway stop
hermes uninstall
```

记忆库默认保留，其中是用户文档与记忆，属资产而非软件痕迹；需一并删除时勾选对应选项并二次确认
（Linux 上即 `rm -rf ~/vault`）。

**Linux**：

```bash
hermes gateway stop 2>/dev/null
rm -rf ~/.config/systemd/user/*hermes* && systemctl --user daemon-reload
rm -rf ~/.hermes ~/hermes-agent ~/.hermes.md
```

记忆库（`~/vault`）按需自行删除。重新运行安装器即可重新部署。
