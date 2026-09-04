# 手动安装（v0.1.0，install.sh 就绪前的路径）

> 目标环境：headless Linux。全程约 15-30 分钟。
> 铁律：系统凭据（API key）只在 `~/.hermes/`，永不进 vault。

## 1. 安装 Hermes Agent（pin 版本）

```bash
# TODO(实测后补充精确命令)——目标：安装 v0.21.0 (tag v2026.8.31)
```

## 2. 建库与落位

```bash
mkdir -p ~/HerMemory-vault
# 拷贝本仓库 memory/ 与 skills/ 到 vault（出厂默认）
# 权限：文件属主 = 当前用户（双端可读写）
```

## 3. 符号链接（关键步骤）

```bash
ln -sf ~/HerMemory-vault/memory/MEMORY.md ~/.hermes/memories/MEMORY.md
ln -sf ~/HerMemory-vault/memory/USER.md   ~/.hermes/memories/USER.md
ln -sfn ~/HerMemory-vault/skills        ~/.hermes/skills   # 目录必须 -n
```

## 4. 皮肤

```bash
mkdir -p ~/.hermes/skins && cp skins/hermemory.yaml ~/.hermes/skins/
```

## 5. 时区（Asia/Shanghai）

```bash
sudo timedatectl set-timezone Asia/Shanghai   # Docker 容器另见 docker/ 说明
```

## 6. 首启

启动 agent → 它会主动发起采档案对话 → 回答三个问题 → 检查 `memory/USER.md` 已被写入。

## 健康自检

```bash
ls -la ~/.hermes/memories/ ~/.hermes/skills   # 链接不应显示红色/悬空
```
