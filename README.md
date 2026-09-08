<div align="center">

# HerMemory

**HerMemory. Your memory.**
*Memory that grows with you.*

把「记忆」从 AI 的功能，变成用户的资产。

针对日常对话与文档编辑深度定制的 [Hermes](https://github.com/NousResearch/hermes-agent) 发行版 · 开源 · 免费

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Hermes](https://img.shields.io/badge/Hermes-v0.21.0%20(v2026.8.31)-22D3EE)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey)

</div>

---

和 AI 处久了，总会有点不踏实：它好像挺了解你，但这些「了解」放在别人的服务器里，看不见也拿不走。换个模型、换个产品，说清零就清零。

HerMemory 把这份「了解你」放进你自己的文件夹。几个 Markdown 文件，记着它对你的了解、它经历过什么、它是什么性格、它守什么规矩。任何编辑器都能打开，你能看、能改、能带走。

## 装完之后，你的日子大概是这样

装它花 5-10 分钟：选一次记忆档位，贴一次 API 地址和 Key，扫一次微信码。装完，AI 就住在你的微信里。

你发第一句话过去，它会自我介绍，问你希望怎么称呼、主要拿它做什么、喜欢什么说话方式，把答案写进它自己的档案。剩下的部署你不用懂：它照着自己的部署手册，在对话里带你一步步来——起同步服务、连上你的手机和电脑、给你演示它能做什么。

再往后：

- 微信里说「写今天的日记」。它只写今天真实发生的事和你明确表达过的情绪，不编，不硬抒情。
- 地铁上用手机 Obsidian 翻到那篇日记，觉得结尾肉麻，改掉两句，点一下同步。到家后，它就照你改过的版本继续。
- 想让它每天凌晨备份一次？说一声就行，它自己建定时任务、自己登记在案。
- 哪天你换了模型服务商，或者这个项目停止维护了。文件在你手里，每台设备还各有一份同步副本。换一个读得懂 Markdown 的 AI，它照样认识你。

## 记忆放在哪里

一个文件夹（默认 `~/vault`），文档里叫同步库，里面装两类东西：你的全部文档，和 AI 的四个核心文件：

| 文件 | 内容 |
| --- | --- |
| USER.md | 它对你的了解 |
| MEMORY.md | 它经历过、记住的事 |
| SOUL.md | 它的性格 |
| AGENTS.md | 它的行为规矩 |

所以改它也很朴素：想调它的性格，改 SOUL.md；想立个规矩，往 AGENTS.md 加一行；想让它忘掉什么，删掉就好。生效三步：改文件，同步到 AI 端，开新对话。不用重启任何东西。

## 同步：一份库，几台设备

同步库可以经 Obsidian + Remotely Save 同步到你的每台设备（手机、PC、平板），每台一份完整的离线副本。这同时解决两件事：

文件跟人走。你在任何设备上改了东西，点一下同步，AI 就读到；AI 写了新东西，同步后你在哪台设备都能看、能改。

每台设备一份备份。服务器挂了、停机不续了、项目没了，都影响不到你设备上的文件。

同步刻意做成全手动。自动同步听着更贴心，但它也会把 AI 端的删除原样传到你的手机上。手动意味着每一次删除的传播都经过你的手；你设备的副本就是你的备份，而不是一个可能已经错了的另一端的回声。

这也是 HerMemory 相对上游补的最大一块：Hermes 自己不做同步，也不做机外备份。补的方式很朴素，AI 端用 rclone 起 WebDAV，设备端用 Obsidian，中间没有任何私有协议。

## 带得走

`bash export.sh` 产出一个 zip：文档库、数据库的一致性副本、skill、配置、定时任务定义，外加一封写给下一个 AI 的信（README_REBORN.md）。AI 本身瘫痪了它也能跑；服务器上会生成临时下载链接，PC 直接存本地。

搬不走的东西（定时任务、常驻脚本）生前都登记在 AUTOMATION.md 里，换机器照单重建。

导入也一样：任何 AI 的聊天记录，粘成 Markdown 放进同步库，它就认识了。

## 安装

**Windows**：双击 `HerMemory.exe`，跟向导走。C# + WPF 单文件自包含，约 70MB。装完常驻系统托盘：启停、改配置、看状态、卸载，都在窗口里，全程不碰命令行。

**Linux（服务器 / NAS）**：

```bash
git clone https://github.com/Prom1seCN/HerMemory.git
cd HerMemory
bash install.sh
```

两条路共用同一套安装逻辑（图形壳只是静默调用脚本），做的事：下载 pin 住版本的上游内核；把出厂文件铺进同步库（已存在的绝不覆盖，那可能是你的记忆）；软链到 AI 的读取位置，从此 AI 读写的就是你看见的那份文件；装皮肤；打开时间注入（之后你的每条消息头部自动带上真实时间，AI 不用猜今天几号，也不会把去年的新闻当今天的）；装网关服务。

配置 AI 在安装流程里完成：地址、Key、从实时拉取的模型列表里选默认型号；每步当场验证，错了用中文提示，重试不限次数。不指定服务商，任何 OpenAI 兼容接口都行。

中途断了重跑即可，完成的步骤自动跳过。细节见 [docs/INSTALL.md](docs/INSTALL.md)，日常使用见 [docs/GUIDE.md](docs/GUIDE.md)。

## 与 Hermes 的关系

发行版，不是 fork，类比 Ubuntu 之于 Linux：内核一行不改，价值全在壳这一层。版本 pin 在 v0.21.0（tag v2026.8.31），什么时候吸收上游更新是产品契约的一部分；壳层只调用上游公开的 CLI 和配置接口，仓库里每个文件都能活过上游升级。

Hermes 本体 MIT（Nous Research），HerMemory 也是 MIT。

## 先说清楚的两件事

AGENTS.md 可以自由编辑，但上游对它有威胁扫描：含触发词的内容会被整体拦截，规则静默失效。这是上游机制，绕不过；规则不生效时，先想想能不能换个说法。

自动化默认全关。日记、周小结、定时任务，你不开口就不存在；开口之后每一条都登记进 AUTOMATION.md，这本登记册跟着同步库走，换机器照单重建。

## 当前状态

- 双平台安装器与 HerMemory.exe 已落码，干净环境全流程实测进行中
- 云盘同步的读写安全规则待实测定案（sync_check.sh 目前是骨架）
- 升级机制（安装器检测旧版本、diff 可拒、永不碰记忆层）在下一版本；目前重装即重跑安装器

## 仓库结构

```
HerMemory/
├── install.sh / install.ps1 / install.bat   装机脚本（Linux / Windows / 双击入口）
├── gateway-run.bat                          前台运行网关（应急）
├── export.sh                                一键全量导出
├── memory-size.sh                           记忆容量换档
├── sync_check.sh                            同步健康自检
├── memory/                                  出厂记忆层（安装时铺进你的同步库）
│   └── MEMORY.md · USER.md · SOUL.md · AGENTS.md · AUTOMATION.md
├── skins/hermemory.yaml                     品牌皮肤：横幅 / 配色 / 动效 / 中文界面
├── docs/                                    INSTALL · GUIDE · ONBOARDING · README_REBORN
├── shell/                                   HerMemory.exe 源码（C# + WPF）
└── scripts/                                 设计工具链（只服务开发，不进运行时）
```

## License

[MIT](LICENSE)，含上游 Nous Research 第三方声明。
