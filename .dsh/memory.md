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
powershell -File build-offline.ps1 -Tag v0.22.2        # 出 build\minimal\{bundle,uv.exe,uv.version,python.json,runtime.json,artifacts\}
powershell -File build-release.ps1 -Version 0.2.0      # 出 build\app\HerMemory.exe 与 build\Setup.exe
```
`build-release.ps1` 构建前跑 `scripts/check-privacy.ps1`（随包源码不得含构建机用户名）。

`build\minimal\python.json`（版本/sha256/uv 目录名）与 `runtime.json`（sha256 → 原始文件名）
由 build-offline 从上游 `pm/lock.json` 生成，缺任何一个 `build-release` 直接失败——它们不是可选件。

**PM 下载缓存契约**：`<HERMES_HOME>\tools\fetch-<sha256>\<原始文件名>`。
PM 的 `extract()` **只看后缀**决定解包方式（`.zip` / `.tar.gz`），把文件改名成 `artifact.bin`
会让 node / python / ripgrep 全部报 `unsupported archive`（2026-10-26 实测，装到依赖阶段才炸）。
预置随包大件必须按 `runtime.json` 的原名落位。

**引导 Python 不再联网**：`install.ps1` 把随包 CPython 解压成 uv 的受管布局
`<HERMES_HOME>\python\cpython-3.14.7-windows-x86_64-none`（纯解压目录即可，uv 不需要 receipt），
再设 `UV_PYTHON_INSTALL_DIR` + `HERMEMORY_BOOTSTRAP_PYTHON`，上游直接取用。

**代理自愈**：`install.ps1`/`install.sh` 开跑前探 `HTTP(S)_PROXY`/`ALL_PROXY` 的端口，连不上就摘掉
（uv 走进程环境，Clash 退出后残留的变量会让每次连接 10061）。国内镜像同时进 `NO_PROXY`。

**干净环境实测**（2026-10-26，临时 HERMES_HOME + 随包素材）：安装阶段 **906 秒 / 2.4 GB**，
`hermes --version` 与 `pm doctor` 全绿。

**构建机（PC）与 NAS 不自动同步**：两边独立仓库，代码只在 NAS 改，PC 需要显式同步
（`git push` 后在 PC `git fetch && git reset --hard origin/main`）。**出包前先确认
`git rev-parse HEAD` 两边一致**——否则会拿旧代码打出一个"看起来成功"的包（2026-10-25 踩过）。
PC 上 `shell/obj/project.assets.json` 已含 win-x64，构建跳过 NuGet 还原：**约 44 秒**
（Ryzen 7 8845H；程序本体 69.2 MB + Setup 409.6 MB）。别拿 NAS 跑 `.ps1` 的耗时当时钟——
NAS 连不上 api.nuget.org，每条重试要等一两分钟，会误判成"构建要 20 分钟"。

## 托盘状态轮询（2026-10-25 事故）

**症状**：托盘图标每隔几秒闪一下；`agent.log` 每 10 秒一条 "Plugin discovery complete"；
conhost 越堆越多（一度 10 个）。

**根因**：`TrayService.PollAsync` 每 10 秒调 `HermesCtl.RawStatus()` → 起一个完整
`hermes gateway status` 子进程。该 CLI 要加载 50+ 插件，**实测单个进程存活约 6 秒**，
即托盘有 60% 时间在跑 CLI，每次还创建一个 conhost。

**修法**（已落地）：高频轮询只走 `HermesCtl.ProbeState()` —— 纯本地读 `gateway.pid` +
`gateway_state.json` + PID 归属校验，**零子进程**。实测：运行中 1.0 ms/次、停止 6.3 ms/次。
只有「本地说停止、但进程表里确有归属本目录的网关进程」（无 pid 文件的歧义态）才用 CLI
复核，且最多 60 秒一次。用户点启停后允许一次精确复核。
**纪律**：任何 10 秒级轮询都不许调 `hermes` CLI；`State()`（会起 CLI）只用于用户主动动作。

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
- `shell/HealthCheck.cs`：九项本地检查（内核/PM 环境/网关/计划任务/注入槽位/五文件/磁盘/记忆预算/日志错误）。
- 页面 `PageHealth` 动态生成行；每项带 `HealthFix` 枚举，界面据此给按钮（启动网关 / 重装任务 / 修复安装 / 看日志）。
- 判据与上游同口径：内核是否可运行看 `hermes --version` 退出码（`HermesCtl.WorkingCli`），不是看文件在不在。

### 记忆时光机
- `shell/MemoryHistory.cs` + `shell/HistoryWindow.xaml(.cs)`。
- 仓库在 `%LOCALAPPDATA%\HerMemory\history`（**不在 vault**，避免被用户的同步/备份工具带走、避免和 Obsidian git 插件抢目录），
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

## 产品边界（2026-10-21 用户裁决）

- **不做同步引导。** 用户想同步/备份是自己的事，软件不替他选。vault 统一称「记忆库」（不再叫「同步库」）。
- WebDAV 相关内容已全部移除：`docs/ONBOARDING.md` 不再有同步章节，`docs/GUIDE.md` 的「多端同步」整章删除，
  体检里的「同步服务（WebDAV）」检查项与 `HermesCtl.WebDavRunning` / `TcpReachable` 一并删除（现为九项）。
- 核心卖点收敛为一条：**记忆是明文文件，可见、可改、可带走。**

## 界面层（v0.3「安静的工具」重做）

- 语义色令牌在 `shell/App.xaml`（默认浅色）与 `shell/Theme.cs`（按偏好整体替换同名键）。
  纯色之外还有三样随主题整体换：`AccentGradient`（主按钮渐变）、`HeroWash`（首页状态卡水洗底）、
  `CardShadow`（DropShadowEffect，深色下更黑更远）。新增键必须两处同时加。
- 控件模板全在 `App.xaml`：`AccentButton`（渐变+柔光+按压回弹）/ `GhostButton` / `TileButton`（六宫格）/
  `BackButton`（圆形底 + 矢量 chevron，悬停左移）/ `ThemeSwitch`（日/夜矢量开关）/ `IconButton` /
  `LinkButton` / `ChipToggle` / `Card` / `SoftCard`；隐式 `CheckBox`、`RadioButton`、`ProgressBar`、
  `ScrollBar`、`ToolTip`、`ComboBoxItem`，`FieldCombo` 是自绘模板（默认 Aero2 太丑）。
- **明暗开关**是 ToggleButton：58×30 轨道，白天奶油渐变 + 太阳，夜里深海渐变 + 三颗星 + 月亮，
  滑块 24px 沿 Canvas.Left 3→31 滑动（340ms QuarticEase）。
  坑：`ControlTemplate.Triggers` 的 `EnterActions` 在模板加载时**不会**补播——启动即深色时开关会停在白天态，
  所以静止态必须用 `Setter`（nightBg/sun/moon/星星/Canvas.Left），动画改挂 `ToggleButton.Checked/Unchecked`
  事件；另外模板没实例化就写 `IsChecked`，事件里的 Storyboard 找不到 `nightBg` 会直接抛
  “无法在 ControlTemplate 名称范围内找到…”。所以 `ChkDark.IsChecked` 在 `Loaded` 里设，
  `_themeUiReady` 吃掉这一次事件。
- 顶栏品牌标记是**双菱叠影**的矢量版（两个 Polygon + `LogoBack`/`LogoFront` 两个品牌渐变常量，
  与 `icons/logo-candidates/2-修正-分距200.png` / `app.ico` / 托盘图标同构图：后菱暗一档在左，
  前菱亮一档在右，中心距 200/1024）。不要再拿书签之类的替代图形。
- 页面宿主是 `PageScroll`（ScrollViewer）+ `PageHost`（Grid，`MinHeight` 绑 `ViewportHeight`）：
  窗口够高时页面照常铺满/居中，窗口被系统工作区压小时整页可滚，不会把底部按钮切掉。
  `ShowPage` 遍历的是 `PageHost.Children`，不是窗口 Content。
- `FitToWorkArea()` 在 Loaded 里按 `SystemParameters.WorkArea` 收缩窗口并重新居中（1366×768@125% 的兜底）。
- 顶栏还有一个隐藏的 `BtnUpdate`：启动时静默查 GitHub `releases/latest`（`shell/UpdateCheck.cs`），
  比当前版本新才显示「有新版本 vX →」，点开浏览器。断网/404/限流一律静默。
- 排版：窗口 880×620，内容区 800px。顶栏 = 品牌标记 + 版本胶囊 + 明暗开关（每页常驻）；
  首页 = 顶部 200px 区（左：状态点/文字/启停按钮，右：品牌头像水印）+ 3×2 图标磁贴（全宽）+ 动作行 + 底部路径；
  子页 = 返回键 + 标题 + 说明 + 发丝线 + 内容。
- **安装与配置分家（2026-10-24 用户定）**：`Setup.exe` 只装（预检 → 位置 → 安装 → 完成），
  不再有 API/扫码页；API、微信、第一句话全在程序本体的 `PageSetup` 三步骤向导里，
  「设置 → 配置向导」可重进。是否已走完记在 `%LOCALAPPDATA%\HerMemory\ui-state.json`
  （`UiState.SetupDone`，与内核配置分开）；老用户升级时若已有 Key + 微信绑定则自动视为完成，不打扰。
- `PageCommands`（首页底部「常用命令」）列出微信侧可用的斜杠命令 + 一句释义 + 复制按钮；
  命令取自内核 `hermes_cli/commands.py` 的 `COMMAND_REGISTRY`，只收 `cli_only=False` 的。
- `PageApiHelp` 渲染 `vault\HerMemory\docs\GET-API-KEY.md`（安装时随 docs 一起铺），
  支持 #/##/###/>/- 的极简 Markdown；文件缺失时显示落地路径而不是空白页。
  **行内强调只能用颜色不能用字重**：同一 TextBlock 里混字重的汉字会被 WPF 合成假粗体（重影），
  所以 `**…**` 走 `Res("Ink")` 加深；emoji 要在 FontFamily 里带 `Segoe UI Emoji` 回退，否则 💡 会画成别的小图标。
- **品牌头像（女孩线稿）只有一处位置**：内容区右上角，200×200，`Opacity=0.14`，不加列、不参与排版
  （主界面在顶部 200px 区右侧，安装向导在最外层 Grid 右上角），保证不被卡片压住、右下不再留空列。
  `ApplyGirlIcon()` 按主题换 `girl-light.png` / `girl-dark.png`，两张图都从内嵌资源取。
- **深色主题下强调色是亮青 `#22D3EE`，主按钮文字必须用 `OnAccent`（深色 `#06141A`）**，白字对比度不够。
- **自定义 TextBox 模板的坑**：`ScrollViewer x:Name="PART_ContentHost"` 不能设
  `VerticalContentAlignment=Center` —— TextBoxView 会按控件全高排版却被内容区裁掉下半截
  （真机截图里 "04:00" 只剩上半截）。用 `MinHeight` + `VerticalContentAlignment=Top`，Padding 压在 Border 上。
- **MaxWidth + 默认 Stretch 会居中**：TextBlock 设了 `MaxWidth` 又没写 `HorizontalAlignment="Left"`，
  在 StackPanel 里会被水平居中（设置页/卸载页的描述文字就是这么飘到中间的）。
- 界面验证两套：
  1) 离屏逐页渲染：`pc` 上 `D:\Projects\HerMemory\.uiprobe\UiProbe`（不进 git）引用 shell 工程，
     构造 App + MainWindow，逐个页面设 Visibility，`RenderTargetBitmap` 2× 出图，一次跑完 13 页 × 浅/深；
     framework-dependent exe 要设 `DOTNET_ROOT=C:\Users\HCN\.dotnet` 才能起。
  2) 真机：一次性计划任务（`/it`）跑 PowerShell，`SetProcessDPIAware()` 后再 `GetWindowRect`，
     否则 125% 缩放下拿到的是虚拟化尺寸、`PrintWindow` 会裁掉右下角；UIA 按
     `AutomationProperties.Name="切换深浅色"` 找 ToggleButton 可以验证换主题全链路。

## 事故：网关"已停止"、点启动无效（2026-10-23，已修）

- **现象**：早上开机后托盘显示 Gateway 已停止；点「启动」仍是停止；登录也不自启。`hermes gateway status` 说任务在、进程无。
- **根因**：`%LOCALAPPDATA%\hermes\tools\python-3.14.7+…\python.exe` 的 ACL 只有
  SYSTEM / Administrators / OWNER RIGHTS，**没有 HCN**，所有者是 Administrators，且继承被切断。
  0.22 内核升级时以管理员身份解包 uv / python-build-standalone，文件继承被写成了受保护 ACL。
  于是**所有非提权进程**（登录计划任务、托盘里的「启动」）执行 python 都是「拒绝访问」；
  只有提权进程（我 ssh / HIGHEST 计划任务）能跑，所以之前一直没暴露。
- **判定链**：`schtasks /Run` 返回成功但 12s 内 wscript/python 都不出现 → 用 VBS 探针跑
  `cmd /c python -c ...`，日志写「拒绝访问」→ `icacls python.exe` 看到缺用户 ACE。
- **修法**：`icacls %LOCALAPPDATA%\hermes\{tools,installs} /inheritance:e /T /C`
  （只扫 PM 落地的两棵树，约 60s；整棵 hermes 要 5 分钟以上，别那么干）。
  install.ps1 在内核装完后自动执行这两条；本次已在真机手工执行并验证：
  LIMITED 计划任务 `hermes gateway start` → `direct spawn` 成功，`schtasks /Run Hermes_Gateway` 也能拉起。
- **教训**：凡是"提权进程写、非提权进程读"的目录，装完必须恢复继承；验证安装不能只用提权会话跑。

## 发布与白机测试（2026-10-23）

- **Windows Sandbox 在这台 PC 上没有 TCP 出网**：ICMP 通、DNS 能解析（网关 172.31.64.1），
  但 443 一律 000；宿主代理只监听 127.0.0.1:7897。用 `netsh interface portproxy` 把 7898 桥到 7897 后，
  **NAS 走 `100.64.0.4:7898` 能通（200）**，但 sandbox 连 172.31.64.1/100.64.0.4 的 7898 都不通
  ——sandbox 的 NAT 只给了 DNS/ICMP。所以白机安装只能等网络修好再跑（或换 VM / zjpc）。
- sandbox 里能验到的：Setup.exe 在干净 Windows 11 上正常启动，预检显示「安装源已就位 / 管理员权限已具备」，
  一路走到上游内核安装；下载失败时给出明确错误并停下，不挂死——错误路径是好的。
- 测试脚手架在 `D:\Projects\HerMemory\.sandbox-out`（映射目录 + `.wsb` + boot/elevated 脚本，不进 git）。
- 发行：`main` 由 `feat/hermes-0.22` 快进，`v0.2.0` 注释 tag；GitHub Release 需要 token（机器上只有 SSH key），
  所以 release 页与资产上传留给有 token 的一侧。安装包 `build/Setup.exe`。

## 升级路径（0.1.0 → 0.2.0，2026-10-21 实测）

- **不能在旧 checkout 里切分支**：仓库 `contributors/emails/` 有两个仅大小写不同的文件，
  NTFS 上只能存在一个 → git 永远报 dirty，`git stash` 消不掉，上游 installer 的 `git checkout` 必然被拒
  （"Please commit your changes or stash them..."）。install.ps1 现在把 `hermes-agent` 整体改名为
  `hermes-agent.pre-0.2.2-<ts>`，让上游从随包 bundle 干净克隆；旧目录保留可回滚。
- 升级前必须 `hermes gateway stop`：`schtasks /Delete` 只删任务不杀进程，旧网关会继续跑旧 venv。
- 阶段 1/2 是两个进程：`KernelUpgraded` 用 `$HERMES_HOME\.hm-kernel-upgrade` 标记持久化，
  网关重建成功后才删标记；否则中止后重试会跳过网关重建。
- 向导「连接 AI」页会预填现有 URL/Key/模型/档位；不预填的话升级会被"请完整填写"卡死。
- 备份配置的代码曾经是一个裸 `{ ... }` ScriptBlock（从未执行），已改成顺序执行。
- 接管别人的 Hermes：`memories\` 先整目录改名备份，再按"缺则补、空则填、冲突并存"合并，
  绝不再 `Remove-Item -Recurse` 旧目录（旧逻辑会把真记忆换成出厂空模板）。

## 体验决策（2026-10-21 用户拍板）

- **API Key 默认遮挡**：`shell/SecretBox.cs`（PasswordBox + 可切换 TextBox），向导与 API 设置页都用它；右侧「显示/隐藏」。
- **没有 Key 不能跳过**：保持"必须填完才能继续"，不提供稍后配置入口。
- **接管已有 Hermes 时保留原人格**：`install.ps1` §4.6 先把对方 `SOUL.md` / `.hermes.md` 收进记忆库（仅当目标为空或仍是出厂内容），再建链。
- **记忆历史**：一键导出包含 `history/`；卸载会删除 `%LOCALAPPDATA%\HerMemory\history`；reset-backup 保留（未选删除）。

## 位置三件（2026-10-22 用户裁决）

- 向导「安装位置」页是**三个**位置：程序安装位置 / 数据存储位置 / **AI记忆位置**（标签就叫这四个字，不加括注）。
- 第三项 = vault：用户的文档 + AI 五个记忆文件，默认 `%USERPROFILE%\vault`，首次安装可选，装完固定。
- 唯一来源 `AppPaths.VaultDir`（注册表 `HKCU\Software\HerMemory\VaultDir`，缺省回落默认值）；
  编辑器/体检/导出/卸载/历史全部读它，不再各自拼 `UserProfile\vault`。
- 向导把选择传给 `install.ps1 -VaultDir`；Linux 用 `HERMEMORY_VAULT_DIR`。
- 非默认位置时，install.ps1 §4.7 把已复制文档与 `AGENTS.md` 里的 `~/vault` 替换成真实路径，
  否则 AI 会去读不存在的 `~/vault/HerMemory/docs/ONBOARDING.md`。
- 已装（升级）时三个框都锁死，提示"位置不可更改"。
- 校验：绝对路径、固定磁盘、≥512 MB、不与程序/数据目录互相嵌套；**允许非空目录**（可指向已有文档夹，
  我们只在其中建 `HerMemory\`）。
- 「开机自动启动」默认勾选（用户裁决）：升级用户不会因为 0.1.0 没写过 Run 项而丢掉自启。

## 事故：18:02 那次安装失败（2026-10-22，已修）

- **现象**：从 `D:\Projects\HerMemory\build\Setup.exe` 运行，升级在内核段报
  「缺 vendored 上游安装器 / 缺内核包」。
- **根因**：`FindRepoRoot()` 从 exe 目录向上找 `install.ps1`，在开发机上一眼命中**仓库根**，
  于是安装源 = 仓库树；而 install.ps1 里 `$KernelBundle = Join-Path $PSScriptRoot "hermes-agent.bundle"`
  假设的是**内嵌 payload 的扁平布局**，仓库里却在 `build\minimal\`。用户从「下载目录」运行时
  `_repoRoot` 为 null → 解压内嵌 payload → 布局正确，所以这个坑只有开发者会踩。
- **修法**：
  1. `install.ps1` 增加 `-SrcDir`，向导显式传 `_repoRoot`；`$SRC` 再带三级兜底
     （$SrcDir → $MyInvocation → $PSScriptRoot → payload 缓存）。
  2. 新增 `Get-ShippedAsset`：bundle/commit/uv.version/uv.exe 同时认 `<src>\x` 与 `<src>\build\minimal\x`。
  3. 向导新增 `SourceLooksComplete()` 预检（install.ps1 + scripts + memory + docs + 内核包），
     不齐就先尝试解内嵌 payload，仍不齐则**在启动安装前**给明确错误，不再跑到一半 Die。
  4. install.ps1 启动就打印 `安装源：$SRC`，以后同类问题一眼定位。
- **连带修复**：升级向导预填 API Key 时曾用 `hermes config get model.api_key`，该命令**返回打码值**
  （`sk-a...a84f`），填进表单再保存会把真 key 覆盖成打码串。改为直接读 `config.yaml` 的
  `model.api_key`（仅当它是明文而非 `${ENV}` 引用），并拒绝含 `...` 的值。
- **验证**：用 `/rl HIGHEST` 计划任务提权驱动向导（UIA 需要与被控窗口同级权限），
  0.1.0 → 0.22.2 升级全流程跑通：内核 c9524f99、`Hermes_Gateway` 任务重建、网关运行、
  Program Files 里 exe 版本 0.2.0、`.hm-kernel-upgrade` 标记已清。

## 编译与 Linux 侧（2026-10-24）

- **PC 关机时也能验编译**：NAS 上装了 .NET 8 SDK 到 `/home/hcn/.dotnet-linux`，
  `cd shell && /home/hcn/.dotnet-linux/dotnet build HerMemory.csproj -c Release -p:EnableWindowsTargeting=true`
  能把 WPF（含 XAML）完整编译过；只出警告即通过。Go 的 `UseWindowsForms` 会让 `Button`/`Clipboard`
  这类类型二义，新增控件要写全名。
- Linux 安装器新增 `HERMEMORY_HEADLESS=1`：跳过记忆档位 / AI / 扫码三段问答；模型列表为空时允许手填型号。
- Linux 侧文档：`docs/LINUX.md`（运维）、`docs/COMMANDS.md`（命令）。两份随 `docs/` 一起进记忆库。
