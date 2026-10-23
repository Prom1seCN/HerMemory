# HerMemory 0.2.x 完整 Debug · 问题清单

> 目标：程序本身（安装器 / shell / 脚本 / 构建产物）× 真实用户旅程（全新安装、0.1.0 升级、
> 接管已有 Hermes、修复安装、日常使用、异常恢复）。
> 每条都要能复现；修完在这里标记验证方式。

当前基线：`main` @ 19efb6f，版本 0.2.1，安装包 `build/Setup.exe`
（280,366,124 字节 / sha256 e185ddc3…）。

## 覆盖矩阵

| 区域 | 检查项 | 状态 |
|---|---|---|
| 脚本语法 | `bash -n` install.sh / export.sh / memory-size.sh / scripts/*.sh | ✅ 全过 |
| 脚本语法 | PowerShell Parser：install.ps1 / build-*.ps1 / check-privacy.ps1 / upstream-install.ps1 | ✅ 全过 |
| 构建产物 | 内核 bundle：clone 后 `git describe`=v0.22.2、HEAD=c9524f99、18605 个跟踪文件 | ✅ |
| 构建产物 | Setup.exe 启动 / 预检 / 向导首页（干净 Windows 11 Sandbox） | ✅（沙箱无外网，装不下去） |
| 壳 | 编译 + 13 页 × 浅/深离屏渲染 | ✅ |
| 壳 | 真机导航（记忆设置/设置/返回）、明暗开关（UIA） | ✅ |
| 壳 | 体检 9 项 | ✅ 全部正常 |
| 壳 | 编辑器：取消 / 常开预览 / 无预览开关（0.2.1 真机） | ✅ |
| 壳 | 一键导出（真机，含 hermes backup + 历史） | ✅ 完成，362 MB / 约 5 分钟 |
| 安装器 | 0.1.0 → 0.2.2 升级（真机，10-22） | ✅ |
| 安装器 | 0.2.0 → 0.2.1 升级（真机 GUI） | ✅ 完成，装后 0.2.1 / 网关运行 / Key 保留 |
| 安装器 | 全新安装（白机） | ⛔ 沙箱无 TCP 出网（只有 ICMP/DNS），阻塞 |
| 安装器 | 接管已有 Hermes（memories 合并） | 🔍 代码复核通过，真机测试待隔离环境 |
| 安装器 | 修复安装（删 exe 重装） | ✅ 修掉校验 bug 后跑通，exe 已恢复 |
| 异常 | 网关停止 → 启动恢复 | ✅ stop/start 一轮验证 |
| 异常 | 导出中途杀进程 → staging 残留 | ⚠️ 见 #4 |

## 问题

### #1 网关无法启动（已修，0.2.1）
- **复现**：0.2.0 内核升级后重启登录 → 托盘显示「已停止」；点「启动」仍停止；
  `schtasks /Run /TN Hermes_Gateway` 返回成功但 12s 内无 wscript/python；提权会话里 `hermes gateway start` 正常。
- **根因**：`%LOCALAPPDATA%\hermes\tools\python-3.14.7+…\python.exe` 的 ACL 只有
  SYSTEM / Administrators / OWNER RIGHTS（owner=Administrators，继承被切断）→ 非提权进程执行「拒绝访问」。
- **修复**：install.ps1 在内核装完后对 `tools`、`installs` 执行 `icacls /inheritance:e /T /C`；
  真机已手工修复。**验证**：LIMITED 任务 `hermes gateway start` 成功；`schtasks /Run` 成功拉起。

### #2 bundle clone 后工作区脏 14 个文件（上游 quirk，低风险）
- **复现**：`git clone build/minimal/hermes-agent.bundle` → `git status --porcelain` 14 条，
  全是 `tests/install/*.ps1`，diff 为逐行（2876/2876）。
- **根因**：这些文件在 `.gitattributes` 里是 `text eol=crlf`，但快照 commit 里存的是 CRLF blob；
  checkout 后 git 归一化比较 → 永远显示 modified。官方 v0.22.2 tarball 同样如此，不是我们引入的。
- **影响**：不影响运行；但任何依赖 `git status` 干净的升级/更新会误判（我们的安装器是整目录换新，不受影响）。
- **处置**：记录，不改 bundle（改了就不再与上游一致）。

### #3 一键导出体积/耗时偏大（UX 待决）
- **现象**：真机端到端跑通——导出完成（362.0 MB，约 5 分钟），zip 内含 `vault/`、`hermes-home.zip`、
  `history/`（36 个条目）、`README_REBORN.md`。耗时主要来自 `hermes backup`：它把整个
  `%LOCALAPPDATA%\hermes`（uv-python、tools/ffmpeg、sessions）都打进去。
- **影响**：对话框只有不确定进度条，用户容易以为卡死；桌面多一个 362 MB 的包。
- **待决**：A) 保持「完整备份」；B) 默认只导「记忆+文档+历史」（几 MB），完整备份另给一个入口；
  C) 两个都留：主按钮轻量导出，次级「完整备份」。→ 问用户。

### #4 导出被强杀后 staging 残留在 %TEMP%（已修，待构建）
- **复现**：导出进行中 `taskkill /IM HerMemory.exe /F` → `%TEMP%\hermemory-export-*-stage` 留下（内含 vault 副本）。
- **影响**：下次启动不清理，磁盘慢慢涨；本次测试留下 3 份。
- **修复**：`MainWindow.PurgeStaleExportStaging()`，App 启动时调用，删除 **超过 1 天** 的
  `hermemory-export-*-stage`（1 天是为了不误伤另一个仍在运行的导出）。

### #5 位置页底部按钮被挤出视口（已修，构建于 0.2.1）
- **复现**：0.2.0 → 0.2.1 升级向导走到「选择安装位置」，窗口 880×620@125% 时「开始安装/继续安装」被截在窗口下沿，
  UIA 也点不到（IsOffscreen）。
- **根因**：为小屏兜底加的 `PageScroll` 用 `MinHeight=ViewportHeight`，页面被以无限高度测量 → 页内 `*` 行塌陷、
  整页自然高度超过视口；原来「卡片内部滚动 + 底部按钮固定」的布局失效。
- **修复**：`PageHost` 改为 `Height={Binding ViewportHeight}`（页面始终有界），窗口高度下限抬到 520。
  验证：离屏 880×620 下位置页按钮完整可见；真机升级流程点得到。

### #6 升级向导 API Key 预填为空（已修，构建于 0.2.1）
- **复现**：0.2.0 → 0.2.1 升级，参数页 URL/模型都预填了，但 API Key 为空；点「完成配置」不放行，
  反复点也没用（只能手填）。
- **根因**：`GetModelCfg()` 用 `hermes config get model.api_key` 取值——该命令**把密钥打码**成 `sk-a...a84f`；
  旧逻辑只认 `${ENV}` 引用，明文/打码值都落到「没有 key」分支。用户的 config.yaml 恰是明文 key。
- **修复**：`GetModelCfg()` 改为直接读 `config.yaml` 的 `model.api_key`（新增 `ReadConfigValue`），CLI 只作兜底；
  明文值（不含 `...`）直接采用，`${ENV}` 引用仍从 `.env` 解析。
- **验证**：真机升级到参数页 Key 已预填；「完成配置」一次通过，装完 config 里 api_key 原样保留。

### #8 修复安装被“目录非空”挡住（已修，0.2.1）
- **复现**：把 `C:\Program Files\HerMemory\HerMemory.exe` 改名（模拟被杀毒/误删/升级中断丢掉 exe）后跑 Setup →
  位置页红字「程序位置：该目录非空。请选择空目录，或在其下新建一个目录。」，按钮点不动。
- **根因**：`ValidateAppDir` 只把「含 `HerMemory.exe` 的目录」认作既有安装；exe 丢了就判成"非空普通目录"。
  而位置页在"已有安装"时把三个框锁死、却不跳过校验，`BtnLocStart_Click` 又重跑一遍 → 修复永远进不去。
- **修复**：`PrepareLocationPage` 记录 `_locLocked`（已有安装=只读），预填期间用 `_prepLoc` 抑制 TextChanged
  避免红色残留；`BtnLocStart_Click` 在 `_locLocked` 时跳过三项校验。
- **验证**：删 exe 后重跑 Setup，位置页正常显示「继续安装」，一路装完，`C:\Program Files\HerMemory\HerMemory.exe`
  恢复（0.2.1.0），`.bak` 已清理。

### #9 网关停止/启动恢复（验证通过）
- `hermes gateway stop` → 12s 后 `status` = 无进程；`start` → direct spawn PID 22736，`status` 运行中。

## 第 2 轮记录（2026-10-23 下午）

- **自启只驻留托盘**（用户新需求）：Run 键 `"exe" --tray`；`--tray` 只建窗不 Show；二次启动唤醒已运行实例。
  真机验证：`--tray` 启 `MainWindowHandle=0`、二次启动唤出窗口、Run 键保持 `--tray`。见 #7。
- **白机安装**：再次尝试沙箱——给宿主加 `portproxy 7898→7897` + 防火墙规则后，沙箱内
  `curl -x http://<gw|tailscale|lan>:7898` 与直连 baidu 全部 `000`（ICMP/DNS 正常）。结论：该机
  Clash TUN 把沙箱 NAT 的 TCP 全挡了，沙箱不适合做联网安装测试。**换 VM 或第二台机器**。
- **修复安装**：把 `C:\Program Files\HerMemory\HerMemory.exe` 改名后跑 Setup。向导能正常走到「安装完成」，
  但自动化点击把隐藏页的「开始安装」也点了，触发二次安装后被强杀，exe 一度缺失（已用 `.bak` 恢复）。
  说明：`FinalizeShellIntegration()` 是 `File.Exists(appExe)` 后才报成功的（`_shellOk`），不是误报；
  但**测试脚本必须只点当前可见页的按钮**（IsOffscreen 对 WPF Collapsed 元素不可靠）。
- **接管已有 Hermes**：复核了 `AdoptExistingIdentity` 与 §5.5 junction 合并逻辑（整目录改名 → 缺则补 / 空则填 /
  冲突并存，不删任何字节），逻辑正确；真机验证仍需隔离环境。

## 第 1 轮结论

- 0.2.1 已装到真机（0.2.0 → 0.2.1 GUI 升级全程）：装后 `FileVersion=0.2.1.0`、网关运行、config 的
  base_url/api_key/model 原样保留、编辑器按钮为「历史/取消/保存」（无预览开关）。
- 修复 3 个真问题：#4 staging 残留、#5 位置页按钮被挤出视口、#6 升级向导 Key 预填为空。
- 仍待：白机全新安装、接管已有 Hermes、修复安装、卸载旅程、更多异常恢复。

### #7 登录自启会弹主窗口（已修，0.2.1）
- **需求**（用户裁决）：自启动只留在托盘，不主动开窗。
- **实现**：Run 键写成 `"exe" --tray`；`App.OnStartup` 识别 `--tray` 后只建窗口不 Show；
  托盘「打开主界面」照常 Show。二次启动不再弹「已在运行」，改为给已运行实例发信号把窗口叫出来。
- **踩坑**：`TrayService` 启动时会"修复过期自启项"，用整串 `Trim('"')` 比较 → 带 `--tray` 的值被判过期、
  被重写成裸路径，登录又弹窗；已改成只比对 exe 部分。另加 `AutoStart.Migrate`：旧裸路径自动补 `--tray`。
- **验证**：真机 `--tray` 启动 `MainWindowHandle=0`；第二次启动自己退出、已运行实例窗口被唤出；Run 键保持 `--tray`。

## 待验证（下一轮）
- 0.2.0 → 0.2.1 GUI 升级（真实旅程，含位置页只读、预填 Key、扫码跳过）。
- 接管已有 Hermes：伪造 `memories/` + `SOUL.md`，跑 install.ps1，验证「缺则补、空则填、冲突并存」。
- 修复安装：删 `bin\hermes.exe` 后重跑，验证自动重建。
- 白机安装：等沙箱网络（Clash TUN 挡了 NAT）或换 VM。
