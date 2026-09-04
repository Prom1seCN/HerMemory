# skills/ — 发行版技能（纯净新写）

> **方法论（2026-09-04 定）**：不复制自用实例的 skill，而是**基于核心优化待办清单（HerMemory Agent §1）重新编写纯净版**。
> 理由：提炼的纯净是事后清洗，新写的纯净是结构性保证——没有引用就没有污染；自研 skill 无 upstream 标注义务，LICENSE 审查压力归零。
> 逐项要求：**零私人记忆、零私人习惯、零服务器路径、零具体人名**；SKILL.md frontmatter 含 name / description / 对应待办编号。

## 待编写清单（与核心优化表 # 编号对应）

| skill | 对应待办 | 规格 |
|---|---|---|
| `daily-diary` | #9 日记 | 说人话、只写真话与事实、多分段；无素材则留一句，不编造 |
| `weekly-digest` | #10 周小结 | 周日晚（Asia/Shanghai）自动汇总本周记忆与文档 |
| `proactive-checkin` | #21 首周回访 | 装完第 3/7 天主动问「哪里别扭」，反馈记录入 memory |
| `memory-compression` | #11 记忆压缩 | 容量/久远度双触发，正文归档 `HerMemory/旧档/`，注入层留指针 |
| `self-check` | #20 客户自检 | 一句话触发：软链健康 / 同步状态 / key 额度 → 人话输出 |
| `export-import` | #19 导出导入 | 一句话导出全库打包；外部 md 导入即被认识 |
| `monthly-bill` | #22 月度账单 | 每月一条：记 X 条 / 日记 Y 篇 / 库 A→B |

> 安装机制说明（9/4 晚改判）：skill 实体安装于**服务器** `~/.hermes/skills/`（真实目录），本仓库 `skills/` 存放出厂源。客户按需经「传送带」机制取用/编辑/上传（见 ROADMAP）。
