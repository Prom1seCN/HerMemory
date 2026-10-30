<div align="center">

<img src="icons/logo.png" width="128" alt="HerMemory">

# HerMemory. **Your memory.**

# 你的AI。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Hermes](https://img.shields.io/badge/Hermes-v0.22.2-22D3EE)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey)

</div>

---

**HerMemory**是基于开源 Hermes 内核深度定制的**独立发行版Agent**，

在保留Hermes全部能力的基础上针对【日常对话&文档写作】做了深度优化。

HerMemory的**一切**都完全属于用户，HerMemory is **Your** memory。

<details>
<summary>📑 目录</summary>

- [✨ 01 · 核心特性](#-01--核心特性)
  - [📄 1. 文件即AI](#-1-文件即ai)
  - [💬 2. 微信对话，扫码即用](#-2-微信对话扫码即用)
  - [🗂 3. 记忆库：一个文件夹](#-3-记忆库一个文件夹)
  - [🤖 4. 全能的AI助手](#-4-全能的ai助手)
  - [⭐ 5. 独家特性](#-5-独家特性)
- [🆚 02 · 方案对比](#-02--方案对比)
- [🚀 03 · 快速部署](#-03--快速部署)
  - [💻 方式 A：Windows PC（推荐）](#-方式-awindows-pc推荐)
  - [🐧 方式 B：Linux 服务器 / NAS](#-方式-blinux-服务器--nas)
- [📦 04 · 导出与重生：README_REBORN](#-04--导出与重生readme_reborn)
- [📜 05 · 开源协议](#-05--开源协议)

</details>

<div align="center">

## ✨ 01 · 核心特性

</div>

### 📄 1. 文件即AI

所有决定 AI 行为与记忆的文件全部是**纯文本文档**，**完全属于用户**。

用户可以随意**编辑、导出、导入**任何文档。

- **`USER.md`（用户档案）**：AI 对用户的认识了解，**用户可随意编辑**。
- **`MEMORY.md`（长期记忆）**：AI 经历并沉淀的记忆，内置自动压缩，**用户可随意编辑**。
- **`SOUL.md`（人格设定）**： AI 的性格与人设，出厂中性，**用户可随意编辑**。
- **`AGENTS.md`（行为准则）**：AI必须遵守的硬性准则，**用户可随意编辑**。

> 主界面点「编辑记忆」就能在应用内直接改这些文件（自带 Markdown 预览，保存走原子替换）。
>
> 出现幻觉了？打开*MEMORY.md*，直接删除对应条目。
>
> AI不听话？将你自己的规则写入*AGENTS.md*。
>
> 觉得AI不够了解你？在*USER.md*里写下想留给它的印象。
>
> 不喜欢HerMemory这个名字？直接在*SOUL.md*里自定义你的AI。

改完保存，开新对话生效。

### 💬 2. 微信对话，扫码即用

扫一个码就能接入微信ClawBot，直接在微信里与HerMemory对话。

另有QQ、钉钉、飞书等软件可选。

- **永远在线（服务器/NAS）**：安装完成之后，网关长期运行。
- **开机即在线（PC）**：电脑开机+服务运行中=AI在线。可设置开机自启，占用极低。
- **发送和接收文件**：微信支持发送任何文件给AI。AI也可以发送任何文件给你。
- **自定义外观**：在微信中自定义HerMemory的名字与头像。

*tips：也可以在CLI与HerMemory对话。*

### 🗂 3. 记忆库：一个文件夹

记忆与文档在一个文件夹里，全部是明文。

- **明文存放**：文档与记忆都是普通 Markdown，记事本就能打开。
- **随时能改**：改一句话就改一条记忆，不用训练、不用重新喂。
- **随时能带走**：整个文件夹拷走即可，没有专有格式、没有隐藏数据库。
- **备份与迁移你说了算**：想放哪、怎么备份、要不要多设备，都由你决定；软件不替你选，也不往任何服务器上传。

不懂电脑？AI带你慢慢来，遇到不懂随时提问。

### 🤖 4. 全能的AI助手

Hermes 内核的全部能力，加上为日常对话与写作做的取舍。

- **系统级调用**：你能用电脑完成的任务，它都可以。
- **自成长的长期记忆**：在对话中逐渐理解用户，自动更新记忆。
- **自动化任务**：“每天早上9点给我微信发送今日热点新闻”一句话生效。

*注：以下为 Hermes 内核原有特性*

### ⭐ 5. 独家特性

为优化用户体验而设计

- **多档记忆**：USER、MEMORY容量设置，**内置多档可选**，另有自定义模式。
- **时间感知**：提示词自带时间戳，同时制定了时间规则，**对话自带时效性**。
- **读写规则**：AI在编辑任何文档前会先读取其最新版，防止覆盖你的改动。
- **进程清单**：进程与脚本是运行中的程序，无法迁移，但**独立记录**，包含在记忆库中。
- **装完即用**：图形向导装好内核与环境，装完由 AI 带你认识记忆文件，并请你亲手改一次规则。
- **每日新对话**：到点自动开新对话，避免上下文越堆越长（可在设置里开关与改时间）。

<div align="center">

## 🆚 02 · 方案对比

</div>

| 📊 **维度** | 🌐 对话AI（网页版/APP） | ⚙️ **原生框架 (Hermes / OpenClaw)** | 💎 **HerMemory** |
| --------- | ------------- | ---------------------------- | ------------- |
| **数据所有权** | 完全由厂商占有       | 内部文件，访问门槛高                   | **完全属于用户**    |
| **自定义AI** | 无法自定义AI       | 通过长期对话“养虾”                   | **直接增删改文件**   |
| **备份迁移**  | 只能留在厂商服务器   | 需手动打包容器与环境                  | **文件在你手里，拷走即迁移** |
| **日常对话**  | 专属 App / 网页   | 终端/命令行                       | **微信**        |
| **可迁移性**  | 无法迁移          | 需手动打包容器与环境                   | **一键导出，完整接管** |

<div align="center">

## 🚀 03 · 快速部署

</div>

### 💻 方式 A：Windows PC（推荐）

**要求**：Windows 10 2004+ / Windows 11（x64）；安装过程需要联网；磁盘约 2–4.5 GB（取决于是否勾选「浏览器与电脑操作」）。

1. 下载最新的 **`Setup.exe`**（约 403 MB，内核、uv、ffmpeg、ripgrep 已内嵌，不需要另装任何环境）。
2. 双击运行（安装包无代码签名，SmartScreen 弹「Windows 已保护你的电脑」时点「更多信息 → 仍要运行」）：
   - **环境预检** → **安装位置**：程序 / 运行数据 / 记忆库三处分开，仅首次安装可选；同页可勾「开机自动启动」与「浏览器与电脑操作」（约 500 MB，默认勾，日后可补装）。
   - **安装**：内核与 ffmpeg/ripgrep 从随包落位；git、CPython、Node 走 npmmirror，Python 依赖走清华，npm 走 npmmirror——**国内不用梯子**。
   - 装完启动程序，再在应用里完成「连接 AI → 绑定微信 → 发第一句话」。
3. 实测：国内网络（GitHub / PyPI 官方源都不通）下，Windows 沙盒全新安装 **5.5–14 分钟**装完。

> **沙盒里测试安装**：`.wsb` 必须写 `<Networking>Enable</Networking>`；并且**宿主机开着 Clash / v2ray 等代理时沙盒会断网**——代理设置会被带进沙盒，但沙盒里没有代理进程，表现是 `tunnel error ... 10061`。测之前先关掉宿主代理。

### 🐧 方式 B：Linux 服务器 / NAS

**要求**：Ubuntu 22.04 / 24.04、Debian 12+ 或主流 NAS；**普通用户**（安装器拒绝 root）；已装 `git` 与 `curl`（`sudo apt install git curl`）；约 3 GB 磁盘。

```bash
git clone https://github.com/Prom1seCN/HerMemory.git
cd HerMemory
bash install.sh                        # 交互式：记忆档位 → API Key → 微信扫码
HERMEMORY_HEADLESS=1 bash install.sh   # 无交互（装完自己跑 hermes model / hermes gateway setup）
```

- **内核来源**：仓库里不带 `hermes-agent.bundle`，默认从 GitHub clone，并用随仓库的 `hermes-agent.upstream-commit` 钉住上游 **v0.22.2**（不会装成 main 上的最新版）；把 bundle 放到仓库根目录即可免 clone。
- **国内镜像**：PyPI 走清华、npm 与 **Node / CPython 走 npmmirror**（已改写到 PM 的下载层，sha256 校验不变）；**uv 与 ffmpeg 仍从 GitHub 取**，这两个大件在国内无梯子时会慢（约 100 KB/s）。
- **实测**：Ubuntu 24.04 容器里跑完整流程通过，`hermes --version` 为 v0.22.2，`hermes pm doctor` 除可选项外全绿。
- 装完没有桌面程序，日常在微信里用；网关常驻、日志、备份与卸载见 [docs/LINUX.md](docs/LINUX.md)。

<div align="center">

## 📦 04 · 导出与重生：README_REBORN

</div>

无论软件版本如何更迭，甚至 HerMemory 项目本身停止维护，你的数据资产也不会受损：

- **一键导出**：点击HerMemory.exe的“一键导出”按钮，或在终端或脚本中执行 `bash export.sh`，系统将通过 SQLite Backup API 热导出一致性数据库副本，并与 `vault/` 记忆库完整打成单个 Zip 包。
- **跨智能体接管**：导出包内自带一份专为下一个 AI 准备的 **`README_REBORN.md`**。它清晰定义了状态恢复协议。让新的AI读取即可。

任何能读懂文字的智能体，接手这个包后，都能完整继承你与AI的全部记忆和文档。

<div align="center">

## 📜 05 · 开源协议

</div>

本项目采用 [MIT License](LICENSE) 开源，内核基于 [Nous Research](https://github.com/NousResearch/hermes-agent) 的开源 Agent 架构。完全免费，无商业行为。

上游组件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

<div align="center">
<sub><em>HerMemory. Your memory. </em></sub>
</div>
