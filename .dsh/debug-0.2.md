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
| 壳 | 一键导出（真机，含 hermes backup + 历史） | ✅ 完成，362 MB / 约 5 分钟 |
| 安装器 | 0.1.0 → 0.2.2 升级（真机，10-22） | ✅ |
| 安装器 | 0.2.0 → 0.2.1 升级（真机 GUI） | ✅ 完成，装后 0.2.1 / 网关运行 / Key 保留 |
| 安装器 | 全新安装（白机） | ⛔ 沙箱无 TCP 出网，阻塞 |
| 安装器 | 接管已有 Hermes（memories 合并） | ⏳ 待测 |
| 安装器 | 修复安装（半损坏） | ⏳ 待测 |
| 异常 | 网关被杀 → 应用内启动恢复 | ✅（ACL 修复后） |
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

## 待验证（下一轮）
- 0.2.0 → 0.2.1 GUI 升级（真实旅程，含位置页只读、预填 Key、扫码跳过）。
- 接管已有 Hermes：伪造 `memories/` + `SOUL.md`，跑 install.ps1，验证「缺则补、空则填、冲突并存」。
- 修复安装：删 `bin\hermes.exe` 后重跑，验证自动重建。
- 白机安装：等沙箱网络（Clash TUN 挡了 NAT）或换 VM。
