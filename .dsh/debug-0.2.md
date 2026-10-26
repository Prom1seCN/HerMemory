## 2026-10-26 首装失败的两个真因

用户报「安装未成功」，日志尾部：

```
[M] bootstrap Python installation failed
Caused by: Failed to download https://registry.npmmirror.com/-/binary/python-build-standalone/20260807/
           cpython-3.14.7+20260807-x86_64-pc-windows-msvc-install_only_stripped.tar.gz
Caused by: tunnel error: failed to create underlying connection
Caused by: 由于目标计算机积极拒绝，无法连接。(os error 10061)
```

### 根因 1：引导 Python 必须联网，且 uv 信进程环境里的代理

`10061` = `WSAECONNREFUSED`，即代理软件的端口没在听（Clash 退出后变量还留在环境里）。
.NET 的联网预检读的是 WinHTTP 设置，**看不到这类死代理** → 预检通过，装到一半才炸。

- `install.ps1` 把随包 CPython 解压成 uv 的受管布局
  （`<HERMES_HOME>\python\cpython-3.14.7-windows-x86_64-none`），`UV_PYTHON_INSTALL_DIR` 指过去，
  并导出 `HERMEMORY_BOOTSTRAP_PYTHON` 给上游 → 引导阶段零下载。
  真机验证：纯解压目录（没有 uv 的 receipt）也能被 `uv python find --managed-python` 命中，exit 0。
- `install.ps1` §0.15 代理自愈：逐个探 `HTTP(S)_PROXY` / `ALL_PROXY` 的端口，连不上就摘掉并明说。
  国内镜像同时塞进 `NO_PROXY`；清华 PyPI 探不通时自动换阿里/官方。
- `install.sh` 同样处理（bash `/dev/tcp` + `timeout 1`）。
- `upstream-install.ps1` / `.sh` 优先用 `HERMEMORY_BOOTSTRAP_PYTHON`；镜像失败后再试官方 releases。

### 根因 2（干净环境跑出来的，比 1 更致命）：随包大件的缓存文件名丢了后缀

干净 `HERMES_HOME` 实测：

```
node:   install failed: unsupported archive: artifact.bin
python: install failed: unsupported archive: artifact.bin
ripgrep: install failed: unsupported archive: artifact.bin
[X] dependency install failed
```

PM 的 `extract()` 只看后缀（`.zip` / `.tar.gz`）决定解包方式；`install.ps1` 预置缓存时把文件统一写成
`artifact.bin`，于是 node / python / ripgrep **必然**解不开。之前记的「缓存命中 0.12 秒」只测了下载、
没测解包——**下载成功不等于装得上**。

修法：`build-offline.ps1` 产出 `runtime.json`（sha256 → 原始文件名），`install.ps1` 照着命名，
并清掉旧版本留下的 `artifact.bin`；没有清单时按文件头猜（`PK`→zip / `1F8B`→tar.gz / `MZ`→7z.exe）。

### 验证 ①：Windows 沙盒（用户的原始场景）

全新 Windows Sandbox（Win11 26100，8 GB，Networking Enable），把 `build\Setup.exe` 拷进去点「开始安装」，
**14:31:31 开始 → 14:51 页面显示「安装完成」，程序落到 `C:\Program Files\HerMemory`**，
桌面出现 HerMemory 图标。全程用 UI Automation 驱动向导（UIA 树逐页 dump 存证：
`.sandbox-out/tree-*.txt`、`run*.png`）。

自动化要点（复用 `.sandbox-out/` 的老套路）：
- 沙盒内 `schtasks /Create /RL HIGHEST /IT` 起提权任务，**绕开 UAC**（沙盒里没人点「是」）。
- 驱动脚本必须带 UTF-8 **BOM**：无 BOM 时 PS 5.1 按 GBK 读中文按钮名，整个脚本语法错误、
  任务静默失败（2026-10-26 踩了一轮）。
- 向导有两页都叫「开始安装」（预检页 / 位置页），要连点两次；安装页的标志是出现「中止安装」。

### 验证 ②：干净 HERMES_HOME（真机，非推理）

- 干净 `HERMES_HOME`（`D:\tmp\hmtest\home2`）跑完整 `install.ps1` 安装阶段：
  **EXIT=0，906 秒**；`hermes --version` → `Hermes Agent v0.22.2`，`Python: 3.14.7`。
- `hermes pm doctor`：node 26.7.0 / npm 12.0.2 / python 3.14.7+20260901 / ripgrep 15.2.0 / uv 0.12.3 全部 ✓。
- 死代理（`HTTPS_PROXY=http://127.0.0.1:9`）下重跑：告警一行后照常安装。

### 教训

安装器里任何「下载完成了」都不能当成「装好了」——必须跑到下一段真的用上它。
这次两个 bug 都在**上一轮改动新增的代码**里，且都没有被端到端跑过。

## 2026-10-25 全量 debug（0.2.0）

提交 `3110b3e`。范围：安装器（Win/Linux）、shell（C#）、构建脚本、编码约定。

### 已修（每条都有复现或验证）

**A. "命令跑过就算成功"（最贵的一类）**
1. `SetModelCfg` 丢弃全部 `config set` 结果 → 界面报"保存成功"而配置没写全。改：逐项校验退出码 + 读回值，失败回滚。
2. 真机实测发现：迁移时只检查 `model.api_key` 是否存在，**不解析 `${ENV}` 引用**；引用指向不存在的键时会删掉用户唯一可用的 `OPENAI_*` 凭据。改：用 `GetModelCfg().keyValue` 判断"真的有 Key"。
3. `GatewayCommand` 未复核状态 → 网关没起来也报成功。改：按真实状态复核（30 秒时限，单次探测用短超时）。
4. 微信解绑/重绑 `catch {}` 吞掉删除失败 → 界面显示"已解绑"而绑定仍在。改：失败向上抛 + 网关按原状态恢复。
5. `AiReset` 备份失败只记 Notes 继续清空记忆。改：备份失败或校验不一致即中止。

**B. 安装流程可用性**
6. 安装子进程先 `await Pump(stdout)` 再 `WaitForExitAsync(ct)`：子进程卡住时**取消/超时永远不生效**。改：`ct.Register` 先杀进程，管道回收加 5 秒兜底。
7. 下载统计硬编码 `%LOCALAPPDATA%\hermes` → 自定义数据目录时永远不显示进度。改：用 `HermesHome`。
8. "程序没能写入"与"快捷方式没写上"共用一句话。改：分开判定，文案分别给出对应处置。

**C. 编码（本轮反复踩中的根因）**
9. `install.ps1` / `build-offline.ps1` 在我的编辑中丢了 BOM；PS 5.1 下按 ANSI 解中文注释 → `Unexpected token`。已恢复 BOM 并用真 PS 5.1 解析器验证。
10. `scripts/upstream-install.ps1` 含 15 个非 ASCII 字节（em dash），按无 BOM 约定应为纯 ASCII。已清零。
11. 迁移/清理 `OPENAI_*` 只匹配行首，不认 `export ` 前缀 → 漏删，路由仍被劫持。Win/Linux 均已兼容。

**D. Linux 安装器**
12. 镜像补丁的 heredoc 写 CRLF 到 `artifact_mirror.py`（与 Windows 路径不一致），且失败静默。改：LF + 失败告警。
13. §10.5 "model.* 是否完整"用正则判 config.yaml：缩进结构判断失误会误删凭据。改：用 `hermes config get` 判定；迁移补写 `model.default`。

**E. 构建链缺口**
14. `install.ps1` 只在 `<src>\artifacts` 找预置大件，而 `build-offline.ps1` **根本不产出它们**——干净机器构建必然缺输入。改：install 认两种布局；build-offline 新增 §5 按 lock 哈希采集 git/python/node；csproj 缺件即构建失败。

### 验证
- 真 PowerShell 5.1 解析 5 个 .ps1：全部 OK
- bash -n / Python AST / XAML 解析：全部通过
- WPF（app）与 Setup 模式编译：0 错误 0 警告（除离线 NuGet 审计警告）
- 隔离 HOME 跑 Linux install.sh：首跑/重跑幂等，`MEMORY.md` 不被覆盖，`hermemory` 别名可用
- Linux 迁移三例实测：完整配置→只清理；缺件+有模型名→补齐；缺模型名→保留凭据不动
- **在真 Windows 上编译并运行 HermesCtl 测试台（29 项全过）**：含 env 解析、原子写无 BOM/无残留、状态解析、`GetModelCfg` 对缺失引用的处理、迁移拒绝、purge 边界、以及用真实 `hermes.exe` 桩验证**保存成功路径与 mid-save 失败回滚**

### 未验证（需真机）
- 完整全新安装（沙箱网络受限）、0.1.x 真机升级、GPU/WPF 渲染
- `build-offline.ps1` 新增 §5 的实网下载（需在 PC 上跑一次）

---

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
| 壳 | 卸载旅程（沙箱 + 伪造安装痕迹） | ✅ 默认保留记忆库；内核/历史/Run 键/桌面快捷方式/计划任务全部清除 |
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

## 第 4 轮记录（2026-10-23 傍晚）

- **卸载旅程（Windows Sandbox）**：在沙箱里伪造一套安装痕迹（`%LOCALAPPDATA%\hermes`、history、Run 键、
  桌面快捷方式、`Hermes_Gateway` 任务、vault 五文件），以 `--uninstall` 启动 app → 卸载页 → 点「执行卸载」。
  结果：`hermes` 目录、history、Run 键、桌面快捷方式、计划任务全部删除；**vault 默认保留**（符合设计）。
  开始菜单快捷方式那项是测试脚本 seed 错了路径（`StartMenu` vs `Programs`），不是产品问题。
- 沙箱仍无 TCP 出网，所以「全新安装」「接管已有 Hermes」两项继续挂起。

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
