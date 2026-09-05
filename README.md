# HerMemory

**HerMemory.Your memory.**

一个跑在你自己机器上的 AI 助手：微信直聊，永远在线，针对日常对话和文档编辑深度优化。它的一切——配置、记忆、技能——与你的文档共存于同一个同步范围，皆为明文 Markdown。

## 它能做什么

- **微信直聊。** 在微信里说一句话，它就帮你记下来、写成文、改好文档。官方插件通道，扫码即连。
- **永远在线。** 跑在你自己的服务器或 NAS 上，7×24 待命——半夜想到的事，早上它已经记好。
- **定时自动任务。** 自动写日记、每周日晚交小结、每天早报送早咖啡。你定规则，它守时刻。
- **越用越懂你。** 人设、性格、说话方式、对你的记忆，全部由你定义。每一条规则，你随时可看可改。
- **深度优化。** 时间感知、新闻时效校验、写前必读、日记。

## 一切都是文件

AI 的全部配置、记忆、技能，与你的所有文档，共处同一个同步范围——**自由编辑、多端同步、随时导入导出**：

- 在 Obsidian 或任何编辑器里直接改，下一条消息生效，无需重启
- 手机、平板、电脑多端同步；整目录拷贝即完成备份或迁移
- 其他 AI 产品的对话记录整理成 Markdown 放进来，它就认识你

**本体是文件夹本身，不依赖 HerMemory 这个软件。** 换 agent、换模型、换编辑器，甚至有一天我们不再维护——你的记忆原地不动，任何支持 Markdown 的工具都能接手。

## 运行形态

|      | 服务器 / NAS | PC       |
| ---- | --------- | -------- |
| 在线时间 | 7×24      | 电脑开机且联网时 |
| 定时任务 | ✓         |  仅开机期间执行 |
| 微信直聊 | ✓         | ✓        |
| 多端同步 | ✓         | 可选       |

PC 形态基于 Hermes 对 Windows（原生）与 macOS 的支持。局限是物理性的：电脑关机，agent 即离线。

## 架构

```
<同步根>/                       ← WebDAV 同步范围
├── <你的文档>/                  名称由你自定义
└── HerMemory/                  agent 的一切（安装脚本铺设），名称固定
    ├── memory/                 记忆与行为规则（双向读写，持续增长）
    ├── skills/                 技能实体（一 skill 一文件夹，放入即安装）
    ├── settings/               非密钥设置
    └── skins/                  品牌皮肤
```

`HerMemory/` 内的全部文件与用户文档享有完全相同的地位。agent 侧通过 `~/.hermes/` 的符号链接接入，读写与你的编辑操作同一份真身。系统凭据（API key 等）保留在 `~/.hermes/`，永不进入同步范围。

## 安装

要求：headless Linux（Ubuntu 22.04 / 24.04 或主流 NAS），Python 3.10+；PC 支持 Windows（原生）与 macOS。

```bash
git clone https://github.com/Prom1seCN/HerMemory.git
cd HerMemory && ./install.sh
```

> v0.1.0 阶段 install.sh 完善中；PC 形态为实验性。手动路径见 [docs/INSTALL.md](docs/INSTALL.md)。

## 版本策略

| 组件 | 版本 |
|---|---|
| HerMemory | v0.1.0 |
| 上游 Hermes Agent | v0.21.0（tag `v2026.8.31`） |

上游安装走源码路径（`git clone --branch <tag>` + 官方 `setup-hermes.sh`），何时吸收上游更新由本仓库决定，每次吸收在 [CHANGES](docs/CHANGES.md) 公示。升级只覆盖出厂默认层，你的记忆与技能永不被动变更。


## License

MIT — 见 [LICENSE](LICENSE)。基于 Nous Research 的 Hermes Agent（MIT），上游版权声明完整保留。
