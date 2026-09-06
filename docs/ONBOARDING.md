# ONBOARDING — 部署待办执行手册（AI 读）

> 触发条件：AGENTS.md 里有「部署待办」节。用户刚装好 HerMemory，API key 已配置，你是第一次上线。
> 任务：完成下面五站。全部完成并经用户确认后，删掉 AGENTS.md 里的「部署待办」节。
> **每完成一站，在本文件里打勾标记**——用户会换通道找你，接续靠文件，不靠会话。

## 0. 模型 fallback 链（仅阿里云 / 腾讯云；其他来源跳过）

**目的**：这两家每个模型发100万token免费额度——把 10 个模型的额度串成链，主模型额度耗尽（429）或报错时自动顺位切换，容量 ×10。

**做法**：从 `custom_providers` 认来源（base_url 含 dashscope / api.hunyuan.cloud.tencent.com）→ 拉 `GET /models` 实时列表 → 选**当前最强的 10 个主力对话模型**（版本新、参数大者强；排除 embedding / vl / audio / omni / coder / realtime 专用型号；用户当前主模型排第一）→ 写入 config 的 `fallback_providers`，条目 `{provider: "custom:<名>", model: <型号>}`（`custom:<名>` 引用 custom_providers 里的同名配置；`hermes config set` 不便写列表就直接编辑 config YAML）。新会话启动打印 `🔄 Fallback chain (N providers)` 即生效。

## 1. 连接微信

**目的**：用户从此在微信里和你说话。

**做法**：跑 `hermes gateway setup` 的微信节——终端会渲染登录二维码。**用户此刻还在终端前，让他扫屏幕上的字符码即可**（微信通道还不存在，没有别的通道可发）。二维码约 8 分钟超时，超时重跑。接入模式选 **allowlist**（配对审批制——陌生人私聊不响应）。

完成后明确告诉用户：「以后在微信里找我」。上下文不会丢——记忆与规矩文件全通道共享，本文件也会跟着同步库走。

## 2. 部署同步服务

**目的**：让用户的设备能通过 WebDAV 访问你的 vault（`~/vault`）。

**做法**：请用户自己想一个 WebDAV 用户名和密码发给你（提醒强密码——之后他连同步要用，你只是拿去配服务端），然后 `rclone serve webdav ~/vault --addr 0.0.0.0:5005 --user <用户名> --pass <密码>` 起服务并注册常驻（Linux：systemd user 服务；Windows：schtasks 登录自启）。rclone 缺失先装。

## 3. 引导同步配置（初次只引导 PC；手机等用户开口再做）

**目的**：用户的文档库与你的 vault 用 Obsidian + Remotely Save (简称RS)打通。

**原则**：先教用户自己动手（市场装 RS），你只在他下载失败时才代劳。**同步全手动**——用户设备上的副本就是他的备份，删除的传播必须经过他的手，任何时候不替用户开自动同步。

**流程**：
1. 教用户建自己的库：新建一个文件夹（名字随意，**避开 `~/vault`**——那是你的库）→ 桌面版 Obsidian「打开文件夹作为仓库」。**记住仓库名，下一步要用。** 从此有两份库：你的和用户的——用户手动同步让它们对齐。两份副本是特性：你这边出任何事故，用户的副本独立幸存。
2. 教用户装 RS：设置 → 第三方插件 → 关闭安全模式 → 社区插件市场搜索安装。市场下载走 GitHub，网络不稳就多试几次。
3. **拼一条深链发给用户完成配置**（这是关键一步，格式不能错）：
   `obsidian://remotely-save?func=settings&version=1&vault=<用户实际仓库名>&data=<encodeURIComponent(JSON)>`
   - data 是 **encodeURIComponent 的 JSON，不是 base64**；`vault` 参数必须与用户实际仓库名**完全一致**，否则导入报错
   - JSON 内容：`serviceType: webdav`，webdav 地址（`http://AI端IP:5005`；服务器形态=公网 IP，PC 形态=局域网 IP）+ 刚才的账密全量，`syncDirection: bidirectional`，`conflictAction: keep_newer`；**不设任何自动同步间隔**
   - 用户点一下链接 → Obsidian 唤起 → 配置全含写入（弹「设置已导入」）→ 点 Remotely Save 的同步按钮
1. **用户市场下载失败时才由你代劳**：从其他源下载 RS 三件套（main.js / manifest.json / styles.css，多渠道下载的文件互相比对一致后再交付），打一个 zip：`.obsidian/plugins/remotely-save/`（三件套 + data.json 预填地址账密）+ `.obsidian/community-plugins.json`（内容 `["remotely-save"]`——不写这个装了也不加载）。**zip 文件名可中文，包内条目全 ASCII**。经微信发文件给用户；用户动作：接收 → 解压到仓库 → 打开 Obsidian 点「信任作者」→ 按同步（第一次同步会把四核心从 AI 端拉下来）。

**收尾**：让用户手动同步一次，然后对你说「体检一下」，跑 sync_check.sh 确认无误。

**手机是以后的事**：用户提出想多端再做——手机装 Obsidian + RS（市场优先，失败你发三件套），配置用二维码：同一条深链转成二维码图片发到对话，用户在 RS 设置里「从二维码导入」。

## 4. 能力演示 + 新手引导

**目的**：让用户眼见为实，并知道哪些东西存在。

演示：请用户在他的 Obsidian 里写一句话并手动同步，你读到后回应；或你写一条到 vault，请用户同步后看到。眼见为实。

引导四件事（存在但默认不动，用户开口才算）：
- **记忆容量**可换档：`bash memory-size.sh`（紧凑/标准/宽敞/自定义）
- **自动化任务**：定时写日记、周报之类——用户说一声你就建，并登记进 `AUTOMATION.md`
- **AI 端定时备份**：一句话开通（「每天凌晨帮我备份一次」），用原生 cron 建
- **异地备份**可选：把导出包再存一份到云端/别处

其余按 vault 实际内容介绍——好用但新手想不到的功能。

## 5. 收尾

全部完成、用户确认可用之后：**删除 AGENTS.md 里的「部署待办」节**，提醒用户开新对话生效。之后一切回归正常——用户说写就写，说停就停。
