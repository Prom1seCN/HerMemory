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
- 排版：窗口 880×620，内容区 800px。顶栏 = 品牌标记 + 版本胶囊 + 明暗开关（每页常驻）；
  首页 = 状态卡 + 3×2 图标磁贴 + 动作行 + 底部路径卡；子页 = 返回键 + 标题 + 说明 + 发丝线 + 内容。
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
