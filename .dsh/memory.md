# HerMemory 项目记忆

面向下一个在本仓库干活的 agent。只写**已验证的事实**与**必须知道的坑**；业务背景看 README / docs。

## 这是什么

Hermes Agent 的发行版：三层壳。
1. 上游内核 `NousResearch/hermes-agent`（MIT），**pin `v0.22.2` / commit `d923a5eb487a17c0a68801bba9ef0f56c81040a8`**
2. 发行层：`install.ps1` / `install.sh` 铺 vault、五文件、软链注入、皮肤、配置键
3. 外壳：`shell/` 的 WPF 单文件 exe（托盘 + 主界面 + 安装向导）

数据主权机制：vault 里的 md 经符号链接/junction 挂到 agent 的注入槽位
（`SOUL.md` → `$HERMES_HOME/SOUL.md`，`AGENTS.md` → `~/.hermes.md`，`memories/` → vault 的 memory 目录）。

## 上游 v0.22 架构（与 v0.21 的根本差异）

- 依赖由 **PM**（`pm/lock.json` + `python -m pm.cli install`）统一管理，逐件 sha256 钉死。
- 不再有 `hermes-agent/venv`：真正环境在
  **`$HERMES_HOME/installs/<sha256(安装目录)[:16]>/environments/<gen>/venv`**，
  记录在 `installs/<key>/facts.json` 的 `packages.venv.environment`（上游 `pm/environments.py:_recorded_venv`）。
- Python **3.14.7**（原 3.11）、Node 26、uv 0.12.3、git 2.53.0、ripgrep 15.2.0、ffmpeg 9.0.1。
- 上游安装器 `scripts/install.sh`（Windows 是 `scripts/install.ps1`）只做：clone → PM 装依赖 → 构建 hermes 命令与 TUI/web。
  **没有 `-Tag` 参数了**，只有 `-Branch` / `-Commit`（`-Commit` 必须属于 origin/main）。
- 平台 SDK 不进 `[all]`：缺了只提示。微信依赖要显式 `hermes pm install --extra messaging`。
- 浏览器与电脑操作是**可选默认包**（`agent-browser` pulls `chromium`、`cua-driver`），
  `-SkipBrowser` / `-SkipComputerUse`（Linux `--skip-browser` / `--skip-computer-use`）会记进
  `installs/<key>/declined-packages.json`，后续 update/install 不会加回来。

## 随包策略（发行版决策）

只随包两件 + 两个戳（`build-offline.ps1` 产出到 `build/minimal/`）：
- `hermes-agent.bundle` —— **快照仓库**的 git bundle：pin 的工作树重做成单提交仓库，
  `refs/heads/main` 指向该提交、带 `v0.22.2` tag；`* -text` 关掉行尾转换保证字节与 pin 一致
- `hermes-agent.commit` —— 上述快照提交的 sha（安装器用它做 `-Commit`）
- `uv.exe` + `uv.version` —— 版本与 sha256 直接从上游 `pm/lock.json` 抄

为什么是快照仓库而不是上游真仓库（实测结论）：
- 浅克隆打的 bundle **不可克隆**（bundle 不带 shallow 信息 → `Failed to traverse parents`）
- 完整历史 **1.1 GB / 54,454 提交**，随包不现实

安装时 `HERMES_REPO_URL=<bundle 路径>` + `-Commit <快照 sha>`，上游 `Stage-Repository`
克隆后钉住；零网络（实测 4.6 秒落位，`git describe --tags` = v0.22.2）。
代价：安装戳与 `hermes --version` 末尾显示快照 sha，与上游 sha 不同。

其余（CPython / Node / Chromium / PyPI 依赖）由 PM 从官方 sha256 镜像
`hermes-assets.nousresearch.com/upstream/sha256/<sha>` 与国内索引取。

国内镜像用的是上游官方口子（`pm/index_config.py` 会把它们转发给 uv）：
`UV_DEFAULT_INDEX` / `PIP_INDEX_URL` → 清华，`npm_config_registry` → npmmirror，
`UV_PYTHON_INSTALL_MIRROR` → npmmirror（只作用于引导阶段 uv 直连下载 CPython）。

## 接缝清单（上游契约，升级时必须逐条核对）

| 位置 | 契约 |
|---|---|
| `$HERMES_HOME/bin/hermes.exe` | Windows 由上游 `Publish-UserCommand` 发布到这里；`HermesCtl.HermsExe` 依赖它 |
| `scripts/upstream-install.{ps1,sh}` | vendored 上游安装器；升级 pin 时整份替换（SHA256 记在提交里） |
| `hermes-agent/gateway/platforms/weixin.py` | 微信补丁锚点；`_print_qr()` 里 `try: import qrcode ... print_ascii` 段 |
| `qr_login(hermes_home, *, bot_type, timeout_seconds)` | `scripts/weixin_qr_login.py` 直调 |
| `get_hermes_home()/"memories"` | `agent/learning_mutations.py` 硬编码，vault 注入靠它 |
| `hermes config set/get/unset` | 记忆档位、`display.*`、`gateway.message_timestamps.enabled` |
| `hermes backup --output/-o` | `export.sh` 与 GUI 一键导出 |
| `hermes gateway install/status/start/stop` + `HERMES_GATEWAY_INSTALL_*` | 网关服务与自启 |
| `hermes pm install --extra messaging` | 微信通道依赖 |
| 皮肤 YAML | **顶层必须有 `name:`**（见坑 1） |

## 已知坑

1. **皮肤必须有 `name` 字段**：v0.22 `_load_skin_from_yaml` 只认 `isinstance(data, dict) and "name" in data`。
   缺了整份皮肤被静默丢弃、退回 default，只留一行 debug 日志。0.1.0 的皮肤就是这么失效的。
2. **`hermes pm install --extra messaging` 会换一代 venv**：facts.json 指向新 generation，
   所有取解释器的地方都必须读 facts.json，不能缓存路径。
3. **上游安装器正常结束不 `exit 0`**：`& $up` 后读 `$LASTEXITCODE` 会拿到最后一条原生命令的残值。
   必须用独立子进程（`powershell.exe -File ...`）的退出码判成败。
4. **bundle 缺 `refs/heads/main` 就装不上**：上游 clone `--branch main` 直接失败。
   浅克隆是分离 HEAD，必须 `git branch -f main HEAD` 后再 `git bundle create ... main --tags`。
5. **`~/.hermes` 是另一个 agent 的领地**（NAS 上）。隔离测试必须同时改 `HERMES_HOME`、
   `UV_CACHE_DIR`、`UV_PYTHON_INSTALL_DIR`、`npm_config_cache`、`XDG_*`，否则会写进别人的 home。
6. Windows 侧无法在 NAS 上运行验证（没有 dotnet/pwsh）——C# 与 `.ps1` 改动只能靠静态检查 + 用户在 PC 上实测。

## 构建

```powershell
powershell -File build-offline.ps1 -Tag v0.22.2        # 出 build\minimal\{hermes-agent.bundle,uv.exe,uv.version}
powershell -File build-release.ps1 -Version 0.2.0      # 出 build\app\HerMemory.exe 与 build\Setup.exe
```
`build-release.ps1` 构建前跑 `scripts/check-privacy.ps1`（随包源码不得含构建机用户名）。

## 本机（NAS）验证方式

隔离 HOME 装一遍再验接缝，`build/spike/` 是现成的样板（`env.sh` 里有整套环境变量）：

```bash
export HERMES_HOME=<spike>/home
<venv>/bin/python -c "from hermes_cli.skin_engine import load_skin; print(load_skin('hermemory').name)"
```

## 0.2.0 新增的两块功能

### 应用内嵌 Markdown 编辑器
- `shell/MemoryEditorWindow.xaml(.cs)`：左侧五个记忆文件 + 编辑区 + 预览；保存走
  「同目录临时文件 + File.Replace」，UTF-8 无 BOM；保存前比对 `(长度, mtime)` 发现外部改动并询问。
- `shell/MarkdownPreview.cs`：手写 Markdown → FlowDocument（标题/列表/引用/表格/围栏代码 + 行内样式），
  零 NuGet 依赖——单文件 exe 不能为预览引入 WebView2 运行时。
- 入口：主界面「编辑记忆」按钮、托盘右键「编辑记忆…」。
- 预览开关默认开；关掉只是隐藏右栏，不重建文档。

### 每日新对话
- 上游 v0.22 **内核不再读 `session_reset.*`**（见 `hermes_cli/session_reset_retirement.py`），
  定时轮换移到社区插件 `hermes-session-reset-policy`。
- HerMemory 的做法：`scripts/hermemory_daily_new.py` 直接调内核的
  `SessionDB.promote_to_session_reset()`（与 `/new` 同一条路径，重置不会被恢复逻辑复活），
  由 `hermes cron create "<cron>" --script hermemory_daily_new.py --no-agent --name "HerMemory 每日新对话" --deliver local` 定时执行。
- 用户状态存 `HKCU\Software\HerMemory`（DailyNewSession / DailyNewSessionTime）；
  界面回显以 `$HERMES_HOME/cron/jobs.json` 里是否真有该任务为准。
- 默认**不开启**（自动化默认关闭的产品原则），由用户在「设置」页打开。
- 脚本随包安装到 `$HERMES_HOME/scripts/`（cron 的 `--script` 只认这个目录）。

## 安装的三种场景

| 场景 | 判定 | 行为 |
|---|---|---|
| 全新 | 无 `bin\hermes.exe` | 完整安装 |
| 旧版 HerMemory | `hermes --version` ≠ 0.22.2 | 升级内核；备份 `config.yaml`/`.env`；**重建网关任务**（旧任务指向旧 venv） |
| 已有 Hermes | 同上，且无 `.hermemory-install-state` | 接管同一数据目录，加记忆库与皮肤，保留配置/会话/技能 |

- 已有版本**比 pin 新则中止**（不降级）：Windows 走 `Compare-Version`，Linux 走 `sort -V`。
- 并存安装靠「安装位置」页改「数据存储位置」（不同 HERMES_HOME）；同一微信号只能绑一台。

### 体检 / 自愈
- `shell/HealthCheck.cs`：十项本地检查（内核/PM 环境/网关/计划任务/注入槽位/五文件/WebDAV/磁盘/记忆预算/日志错误）。
- 页面 `PageHealth` 动态生成行；每项带 `HealthFix` 枚举，界面据此给按钮（启动网关 / 重装任务 / 修复安装 / 看日志）。
- 判据与上游同口径：内核是否可运行看 `hermes --version` 退出码（`HermesCtl.WorkingCli`），不是看文件在不在。

### 记忆时光机
- `shell/MemoryHistory.cs` + `shell/HistoryWindow.xaml(.cs)`。
- 仓库在 `%LOCALAPPDATA%\HerMemory\history`（**不在 vault**，避免被 WebDAV 同步、避免和 Obsidian git 插件抢目录），
  用 `--git-dir/--work-tree` 指向 vault，只跟踪 `HerMemory/memory/`。
- 编辑器每次保存后自动提交一条；「历史」窗口可看某个快照与会话的 diff、回滚单个文件（回滚前先给当前状态留快照）。
- git 解析顺序：PATH → `$HERMES_HOME/tools/git-*/cmd/git.exe`（PM 槽位）→ 旧版 `$HERMES_HOME/git`。
- 无 git 时整体降级为不可用，不阻塞保存。

### 编译验证（重要）
- 本机（NAS）**无法**编译 WPF：dotnet 的 NuGet 命名互斥量被沙箱挡住。
- 真正的编译验证在 Windows 笔记本 `pc`（alias）的 `D:\Projects\HerMemory`：
  `C:\Users\HCN\.dotnet\dotnet.exe build shell\HerMemory.csproj -c Release`。
- 踩过的坑：项目同时开 `UseWPF` + `UseWindowsForms`，`Color` / `FontFamily` / `Brushes` / `KeyEventArgs` /
  `Button` / `Application` / `MessageBox` 都有两份，必须加别名或完全限定。
