# ROADMAP — v0.1.0 达成「可用」

> **验收线（可用 = 全链通）**：一个陌生人 clone 本仓库 → 运行 install.sh → 连上消息通道 → 首启采档案写入 USER.md → 第二天自动日记 → 手改 memory 文件下一条消息生效。这条链每一环都通，v0.1.0 即成立。

## WP1 · 上游三事实 —— ✅ 已查明（2026-09-04，读源码定案）

| 事项 | 结论 | 对 install.sh 的意义 |
|---|---|---|
| **安装方式** | 官方一键脚本 `curl …install.sh \| bash` 装最新版（**不可 pin**）；源码路径 = `git clone --branch <tag>` + `./setup-hermes.sh`（uv + Python 3.11 venv + .env 模板 + CLI 软链 + setup wizard） | **采用源码路径**：clone 上游 `--branch v2026.8.31` → 调 setup-hermes.sh，版本契约成立 |
| **cron 定时** | **原生支持，一等公民**：`cron/` 目录 13 个模块（scheduler/jobs/blueprint_catalog/monitor…）+ `hermes cron` CLI | #8 陪聊 / #10 周小结 / #21 回访零代码依赖；已知坑：全局换模型后未钉模型的 cron 会跳过 |
| **搜索通道** | web 后端 provider 可配置：`parallel / firecrawl / exa / searxng / brave-free / ddgs / xai / keenable` | 国内通道正解 = **searxng 自建**（自用实例已验证 127.0.0.1:8080），纯配置零代码；发行版默认 searxng 后端（install.sh 顺手 docker 起一个） |

## WP2 · skill 纯净新写 —— 内容工作，最大工作量

> **方法论（2026-09-04 定）**：**不复制自用实例的 skill**，基于核心优化待办清单（#9/#6/#10/#11/#19/#20/#21/#22）**从头编写纯净版**——没有引用就没有污染，自研 skill 无 upstream 标注义务，LICENSE 审查压力归零。

- [ ] `daily-diary`（#9 日记：说人话、只写真话与事实、无素材不编造）
- [ ] `weekly-digest`（#10 周小结：周日晚，Asia/Shanghai）
- [ ] `persona`（#6 人设：出厂中性，真实性 > 人设 > 文风）
- [ ] `proactive-checkin`（#21 首周回访：第 3/7 天主动问「哪里别扭」）
- [ ] `memory-compression`（#11 压缩协议：双触发，正文归档 `HerMemory/旧档/`，注入层留指针）
- [ ] `self-check`（#20 客户自检：软链/同步/key 额度 → 人话输出）
- [ ] `export-import`（#19 导出导入：一句话打包全库；外部 md 导入即被认识）
- [ ] `monthly-bill`（#22 月度账单：记 X 条 / 日记 Y 篇 / 库 A→B）

每项要求：**零私人记忆、零私人习惯、零服务器路径、零具体人名**；SKILL.md frontmatter 含 name / description / 对应待办编号。
**完成判据：8 个 skill 全部新写完毕、独立可用；grep 全仓无一条私人内容。**

> 品牌句（2026-09-04 定）：**HerMemory. Your memory.** — 已入 README 顶部与 skins/hermemory.yaml（welcome/goodbye/横幅）。与「双面叙事」咬合：Her = 她/我，Your = 主权，两句互为镜像。

## WP3 · install.sh 落码 + 干净机实测 —— 技术核心

- [ ] 步骤 2 定案落码：`git clone --branch v2026.8.31` 上游 → `./setup-hermes.sh`
- [ ] VAULT_DIR 语义改：**同步根**（安装时询问用户文档夹名，固定创建 `HerMemory/`）
- [ ] 铺设：memory 骨架 → `HerMemory/memory/`、skills/、settings/、skins/
- [ ] 软链四件套（`ln -sfn`）+ Asia/Shanghai 时区（进程与 Docker 两层）
- [ ] searxng 后端：docker compose 一键或安装时引导
- [ ] **干净机实测**（Ubuntu 22.04/24.04 VM 或新 VPS）：从零跑到验收线
- [ ] 卸载路径（v0.2 可延）：`install.sh --uninstall`

**PC 形态（9/4 下午定：纳入支持，功能分级）**：

- [ ] 上游原生支持 Windows（PowerShell 一键 `iex (irm …install.ps1)`，非 WSL）——安装地基已备
- [ ] 铺设脚本跨平台：bash（Linux）+ PowerShell（Windows）或改 Python 单脚本
- [ ] NTFS 符号链接权限问题：mklink 需管理员/开发者模式，或以 junction 替代——待验证
- [ ] 待验证：PC 关机期间错过的 cron 任务是否有补跑机制（决定定时功能在 PC 上的准确描述）
- [ ] 待验证：ClawBot 在 Windows 原生 gateway 的扫码配对
- [ ] 功能分级口径（对外）：服务器 = 完整（7×24）；PC = 本地 AI + 微信，定时功能仅开机期间执行

**完成判据：干净机上无人干预跑完，验收线全通；PC 形态在真实 Windows 机器走通安装 + 微信配对。**

## WP4 · 首启体验闭环 + 发布

- [ ] 采档案对话引导词定稿（三问：称呼/用途/说话方式 → 写 USER.md）
- [ ] 完整首周自查：首启 → 采档案 → 日记自动 → 改文件热更新 → 周日周小结
- [ ] LICENSE 审查——**纯净新写制下自研 skill 无 upstream 义务**，仅核对 8 个新 skill 引用的外部依赖
- [ ] push + tag `v0.1.0` + GitHub Release（附 CHANGES）

## 不在本版（候选池）

快照恢复对话化 / 装机预热+验收卡 / 断链感知 / 遗忘权对话化 / 搬迁机制 —— 等真实需求触发。

## 工作量判断

WP2 是大头（纯内容，可随时开工，不依赖服务器）；WP3 是技术核心（上游 setup-hermes.sh 已替掉大半，剩余是铺设与软链逻辑）；WP4 最轻。**WP1 无未知数残留——install.sh 从今天起可以写实码。**
