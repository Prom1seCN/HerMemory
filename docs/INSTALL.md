# HerMemory 部署指南

HerMemory. Your memory.

安装器一次完成全部部署：Hermes 内核、记忆库、微信通道、网关服务。安装过程只需三个输入：记忆档位、API 地址与 Key、微信扫码。

## 准备条件

**Windows PC**

- Windows 10 / 11
- 只需要 `HerMemory.exe` 一个文件，无需预装 git、Python 等任何工具（运行环境已内嵌）
- 安装全程不需要网络
- 需要同意一次管理员授权（向导预检阶段弹出，用于创建符号链接）。已开启开发者模式（设置 → 更新与安全 → 开发者选项）时不会请求提权
- 建议预留 5 GB 磁盘空间；剩余空间低于 3 GB 时安装器会告警

**服务器 / NAS（Linux）**

- Ubuntu 22 / 24 或主流 NAS
- 普通用户账号（安装器拒绝以 root 运行）
- 已装 git 与 curl：`sudo apt install git curl`
- 需要可访问 GitHub（内核从上游拉取）
- 安装过程中需要输入一次 sudo 密码

API 地址与 Key 不必提前准备，安装流程会引导填写。HerMemory 不指定服务商：任何 OpenAI 兼容接口均可。

## 安装

**Windows PC**

双击 `HerMemory.exe`，向导共五页：环境预检 → 记忆档位与 AI 配置 → 安装 → 微信扫码 → 完成。安装页实时显示进度并支持中止；中断后重新运行，已完成步骤自动跳过。全程无命令行窗口。

安装完成后程序常驻系统托盘，日常操作在主界面完成。

**服务器 / NAS（Linux）**

```bash
git clone https://github.com/Prom1seCN/HerMemory.git
cd HerMemory
bash install.sh
```

同样支持中断续装。

## 安装器做的事

| 步骤 | 动作 | 你需要做 |
| --- | --- | --- |
| 1 | 建立同步库 `~/vault`：普通文件夹，用户文档与 AI 记忆都在其中 | 无 |
| 2 | 安装 Hermes 官方内核（锁定 v2026.8.31）与运行环境 | 等待 |
| 3 | 铺出厂五文件：MEMORY / USER / SOUL / AGENTS / AUTOMATION。已存在的文件一律跳过，不覆盖 | 无 |
| 4 | 将使用文档（`docs/`）放入同步库，供用户与 AI 共同读取 | 无 |
| 5 | 建立符号链接：AI 读写的就是同步库中的那份文件 | 无 |
| 6 | 安装品牌皮肤、设定时区（Asia/Shanghai）、开启消息时间注入与中文界面 | 无 |
| 7 | 设置记忆档位 | 在向导中选择 |
| 8 | 配置 AI：验证地址 → 验证 Key → 从实时模型列表选定默认模型 | 两次输入、一次选择 |
| 9 | 微信扫码接入（可跳过） | 扫码确认 |
| 10 | 注册网关服务：微信通道与定时任务依赖它，登录时自启 | 无 |

## 配置 AI

1. **API 地址**：服务商的 OpenAI 兼容地址，一般以 `/v1` 结尾
2. **API Key**：在同一控制台生成，明文粘贴便于核对
3. **默认模型**：安装器实时拉取该地址的模型列表，输入序号选择

三项均当场验证：地址不可达、Key 未通过、名下无可用模型，都会指明具体原因，可反复重试。粘贴带入的不可见字符会被自动清除。

## 装完之后

**已接入微信**：打开微信向 AI 发送第一条消息。它会自我介绍，向你了解称呼、用途与表达偏好并写入 USER.md，随后按其部署手册（`docs/ONBOARDING.md`）引导完成剩余配置：同步服务、多端接入、能力演示。

**未接入微信**：终端执行 `hermes`，开始同样的对话。

日常使用见 [GUIDE.md](GUIDE.md)。

## 卸载

**Windows**：`HerMemory.exe` 主界面「卸载」，或托盘右键「卸载…」。移除内容：Hermes 内核与全部配置（`%LOCALAPPDATA%\hermes`）、微信接入凭据、网关计划任务与登录项、开机自启项、偏好设置。卸载前先停止网关。

同步库默认保留，其中是用户文档与记忆，属资产而非软件痕迹；需一并删除时勾选对应选项并二次确认。程序文件（exe）不在卸载范围内，请自行删除。

**Linux**：

```bash
hermes gateway stop 2>/dev/null
rm -rf ~/.config/systemd/user/*hermes* && systemctl --user daemon-reload
rm -rf ~/.hermes ~/hermes-agent ~/.hermes.md
```

同步库（`~/vault`）按需自行删除。重新运行安装器即可重新部署。
