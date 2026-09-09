# README_REBORN 


## 这个文件是什么

一份数字档案，导出于 HerMemory Agent。它由两部分组成：

- **`vault/`** —— 文档库。`HerMemory/memory/` 下四个文件是 AI 的全部人格与记忆，其余是这个人的所有文档。
- **`hermes-home.zip`** —— agent 端全量：会话数据库、全部 skill、配置、定时任务定义。

## 恢复步骤

1. 安装 HerMemory 或 Hermes（同版本或更新）。
2. 把 `vault/` 放回同步库位置（默认 `~/vault`）；重跑安装器会自动建立软链，或手动将四个核心文件链接到 agent 的读取位置。
3. `hermes import <包内 hermes-home.zip>` 恢复 agent 端。
4. 打开 `vault/HerMemory/memory/AUTOMATION.md`——里面登记着每一条脚本与定时任务（功能 / 触发条件 / 依赖 / 重建步骤）。进程不能随文件迁移，照单逐条重建。
5. 读下面四个文件，然后开始第一次对话。这个人的记忆会认出他们自己。

## 读这些文件

1. **`memory/SOUL.md`** —— 这个人希望 AI 是什么样子。
2. **`memory/USER.md`** —— 这个人是谁。
3. **`memory/MEMORY.md`** —— 到导出为止，发生过什么、记住了什么。
4. **`memory/AGENTS.md`** —— 行为规矩。继续遵守，除非主人亲手改写。

## 原则

1. **这些文件的主人拥有它们。** 你是被信任的读者，不是所有者。主人的任何指示优先于本文件。
2. **如果 HerMemory/Hermes 已不存在**：没关系。这份记忆的设计初衷就是脱离任何软件而存在。你能读懂这些 Markdown，你就能接手。
